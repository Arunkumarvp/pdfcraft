//! The narrow native boundary used by the Flutter application.
//!
//! The mobile UI owns no PDF implementation. It calls this ABI for engine capabilities and
//! document work, which keeps Android and iOS on the same Rust processing path.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

use std::{
    ffi::c_char,
    sync::{Mutex, OnceLock},
};

const VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();
const OPERATIONS: &[u8] = br#"[{"id":"read","title":"Read","description":"Read, search and navigate PDFs"},{"id":"merge","title":"Merge PDFs","description":"Combine multiple documents"},{"id":"split","title":"Split PDF","description":"Extract selected pages"},{"id":"organize","title":"Organize","description":"Reorder, rotate and delete pages"},{"id":"compress","title":"Compress","description":"Reduce PDF file size"},{"id":"secure","title":"Secure PDF","description":"Add password protection"},{"id":"unlock","title":"Unlock PDF","description":"Remove a password when authorized"},{"id":"share","title":"Share","description":"Export a PDF to another app"}]"#;
static SESSION: OnceLock<Mutex<pdfcraft_engine::Session>> = OnceLock::new();

const OPEN_OK: i32 = 0;
const OPEN_INVALID_ARGUMENT: i32 = 1;
const OPEN_FAILED: i32 = 2;
const RENDER_OK: i32 = 0;
const RENDER_INVALID_ARGUMENT: i32 = 1;
const RENDER_FAILED: i32 = 2;
const TEXT_MAX_BYTES: usize = 256 * 1024;
const SEARCH_MAX_QUERY_BYTES: usize = 1024;
const SEARCH_MAX_RESULTS: usize = 100;

/// Returns the native engine version as a nul-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

/// Returns the mobile operation catalogue as UTF-8 JSON.
///
/// The returned pointer is static and remains valid for the lifetime of the process. The UI
/// should not attempt to free it.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_operations_json(len: *mut u64) -> *const u8 {
    if !len.is_null() {
        // SAFETY: callers provide a writable u64 for the result length.
        unsafe { *len = OPERATIONS.len() as u64 };
    }
    OPERATIONS.as_ptr()
}

/// Returns non-zero when the ABI is linked against the shared PdfCraft engine.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_engine_available() -> u8 {
    let _ = std::any::type_name::<pdfcraft_engine::Document>();
    1
}

/// Opens a PDF in the process-local engine session and returns its page count and document ID.
///
/// The input bytes are copied before returning, so the caller may release its buffer after this
/// function returns. The return value is zero on success, one for invalid pointers or lengths,
/// and two when the engine rejects the document.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_open_pdf(bytes: *const u8, len: u64, page_count: *mut u64, doc_id: *mut u64) -> i32 {
    if bytes.is_null() || page_count.is_null() || doc_id.is_null() || len > usize::MAX as u64 {
        return OPEN_INVALID_ARGUMENT;
    }
    // SAFETY: the caller provides a readable buffer of `len` bytes for this call.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, len as usize) };
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let mut session = match session.lock() {
        Ok(session) => session,
        Err(_) => return OPEN_FAILED,
    };
    let id = match session.open("mobile.pdf", None, std::sync::Arc::new(bytes.to_vec()), None) {
        Ok(id) => id,
        Err(_) => return OPEN_FAILED,
    };
    let Some(document) = session.get(id) else {
        return OPEN_FAILED;
    };
    // SAFETY: null output pointers were rejected above and the caller owns these outputs.
    unsafe {
        *page_count = document.info.pages.len() as u64;
        *doc_id = id.0;
    }
    OPEN_OK
}

/// Renders one document page as a PNG thumbnail.
///
/// The returned buffer is owned by the caller and must be released with
/// [`pdfcraft_mobile_free_buffer`]. `max_width` is capped internally to keep previews bounded.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_render_page(doc_id: u64, page: u64, max_width: u32, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() || max_width == 0 || page > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Some(document) = session.get(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    let Some(page_info) = document.info.pages.get(page as usize) else {
        return RENDER_FAILED;
    };
    let width = page_info.width.max(1.0);
    let scale = (max_width.min(512) as f32 / width).min(1.0);
    let mut renderer = pdfcraft_render::PageRenderer::new(document.bytes.clone(), pdfcraft_render::RenderConfig::default());
    let rendered = renderer.render(pdfcraft_render::RenderRequest { page: page as usize, scale, preview: true, ..Default::default() });
    if rendered.error.is_some() || rendered.rgba.is_empty() {
        return RENDER_FAILED;
    }
    let png = match pdfcraft_engine::export::encode_png(rendered.width, rendered.height, &rendered.rgba) {
        Ok(png) => png,
        Err(_) => return RENDER_FAILED,
    };
    let mut png = png;
    let ptr = png.as_mut_ptr();
    let len = png.len() as u64;
    std::mem::forget(png);
    // SAFETY: output pointers are validated above; ownership of the allocation is transferred.
    unsafe {
        *output = ptr;
        *output_len = len;
    }
    RENDER_OK
}

/// Releases a buffer returned by [`pdfcraft_mobile_render_page`].
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_free_buffer(buffer: *mut u8, len: u64) {
    if !buffer.is_null() && len <= usize::MAX as u64 {
        // SAFETY: the pointer and length came from `pdfcraft_mobile_render_page`.
        unsafe { drop(Vec::from_raw_parts(buffer, len as usize, len as usize)) };
    }
}

fn return_bytes(bytes: Vec<u8>, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    let mut bytes = bytes;
    let ptr = bytes.as_mut_ptr();
    let len = bytes.len() as u64;
    std::mem::forget(bytes);
    // SAFETY: callers validate these output pointers before calling this helper.
    unsafe {
        *output = ptr;
        *output_len = len;
    }
    RENDER_OK
}

/// Returns the current document bytes for a local export.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_export_pdf(doc_id: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Ok(bytes) = session.save_bytes(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Extracts one page into a new local PDF.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_extract_page(doc_id: u64, page: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() || page > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Ok(bytes) = session.extract(pdfcraft_engine::DocId(doc_id), &[page as usize]) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Combines two PDF byte buffers into one local PDF.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_merge_pdfs(
    first: *const u8,
    first_len: u64,
    second: *const u8,
    second_len: u64,
    output: *mut *mut u8,
    output_len: *mut u64,
) -> i32 {
    if first.is_null()
        || second.is_null()
        || output.is_null()
        || output_len.is_null()
        || first_len > usize::MAX as u64
        || second_len > usize::MAX as u64
    {
        return RENDER_INVALID_ARGUMENT;
    }
    // SAFETY: callers provide readable buffers of the declared lengths for this call.
    let first = unsafe { std::slice::from_raw_parts(first, first_len as usize) };
    let second = unsafe { std::slice::from_raw_parts(second, second_len as usize) };
    let sources = [("first.pdf".to_owned(), std::sync::Arc::new(first.to_vec())), ("second.pdf".to_owned(), std::sync::Arc::new(second.to_vec()))];
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Ok(bytes) = session.combine(&sources) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Compresses a PDF with the optimizer's mobile preset.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_compress_pdf(doc_id: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let mut settings = pdfcraft_engine::optimize::Settings::default();
    settings.color = pdfcraft_engine::optimize::ImageSettings::MOBILE;
    settings.gray = pdfcraft_engine::optimize::ImageSettings::MOBILE;
    let Ok((bytes, _report)) = session.optimized_bytes(pdfcraft_engine::DocId(doc_id), &settings, &[]) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Rotates one page clockwise and returns the resulting PDF bytes.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_rotate_page(doc_id: u64, page: u64, degrees: i64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() || page > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let mut session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    if session.apply(pdfcraft_engine::DocId(doc_id), pdfcraft_engine::Edit::RotatePages { pages: vec![page as usize], degrees }).is_err() {
        return RENDER_FAILED;
    }
    let Ok(bytes) = session.save_bytes(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Deletes one page and returns the resulting PDF bytes.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_delete_page(doc_id: u64, page: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() || page > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let mut session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    if session.apply(pdfcraft_engine::DocId(doc_id), pdfcraft_engine::Edit::DeletePages { pages: vec![page as usize] }).is_err() {
        return RENDER_FAILED;
    }
    let Ok(bytes) = session.save_bytes(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Reorders all pages using a zero-based permutation encoded as u64 values.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_reorder_pages(doc_id: u64, order: *const u64, order_len: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if order.is_null() || output.is_null() || output_len.is_null() || order_len == 0 || order_len > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    // SAFETY: caller provides a readable array of the declared length for this call.
    let order = unsafe { std::slice::from_raw_parts(order, order_len as usize) };
    let Ok(pages) = order.iter().map(|page| usize::try_from(*page)).collect::<Result<Vec<_>, _>>() else {
        return RENDER_INVALID_ARGUMENT;
    };
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Some(document) = session.get(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    if pages.len() != document.info.pages.len() || {
        let mut sorted = pages.clone();
        sorted.sort_unstable();
        sorted != (0..pages.len()).collect::<Vec<_>>()
    } {
        return RENDER_INVALID_ARGUMENT;
    }
    let Ok(bytes) = session.extract(pdfcraft_engine::DocId(doc_id), &pages) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Protects a document with an open password and AES-256 encryption.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_protect_pdf(
    doc_id: u64,
    password: *const u8,
    password_len: u64,
    output: *mut *mut u8,
    output_len: *mut u64,
) -> i32 {
    if password.is_null() || output.is_null() || output_len.is_null() || password_len == 0 || password_len > 4096 {
        return RENDER_INVALID_ARGUMENT;
    }
    // SAFETY: caller provides a readable password buffer of the declared length.
    let password = unsafe { std::slice::from_raw_parts(password, password_len as usize) };
    let Ok(password) = std::str::from_utf8(password) else {
        return RENDER_INVALID_ARGUMENT;
    };
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let mut session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let protection = pdfcraft_engine::Protection { open_password: Some(password.to_owned()), ..Default::default() };
    if session.apply(pdfcraft_engine::DocId(doc_id), pdfcraft_engine::Edit::Protect(protection)).is_err() {
        return RENDER_FAILED;
    }
    let Ok(bytes) = session.save_bytes(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Removes document protection using an owner password supplied by the user.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_unlock_pdf(doc_id: u64, password: *const u8, password_len: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if password.is_null() || output.is_null() || output_len.is_null() || password_len == 0 || password_len > 4096 {
        return RENDER_INVALID_ARGUMENT;
    }
    // SAFETY: caller provides a readable password buffer of the declared length.
    let password = unsafe { std::slice::from_raw_parts(password, password_len as usize) };
    let Ok(password) = std::str::from_utf8(password) else {
        return RENDER_INVALID_ARGUMENT;
    };
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let mut session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    if session.unlock(pdfcraft_engine::DocId(doc_id), password).is_err() {
        return RENDER_FAILED;
    }
    if session.apply(pdfcraft_engine::DocId(doc_id), pdfcraft_engine::Edit::RemoveProtection).is_err() {
        return RENDER_FAILED;
    }
    let Ok(bytes) = session.save_bytes(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    return_bytes(bytes.as_ref().clone(), output, output_len)
}

/// Extracts UTF-8 page text into a caller-owned buffer, bounded for mobile search.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_page_text(doc_id: u64, page: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if output.is_null() || output_len.is_null() || page > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Some(document) = session.get(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    let mut renderer = pdfcraft_render::PageRenderer::new(document.bytes.clone(), pdfcraft_render::RenderConfig::default());
    let text = match renderer.filtered_text(page as usize, pdfcraft_render::TextFilter::default()) {
        Ok(text) => text.plain_text(),
        Err(_) => return RENDER_FAILED,
    };
    let mut bytes = text.into_bytes();
    if bytes.len() > TEXT_MAX_BYTES {
        bytes.truncate(TEXT_MAX_BYTES);
        while std::str::from_utf8(&bytes).is_err() {
            bytes.pop();
        }
    }
    let ptr = bytes.as_mut_ptr();
    let len = bytes.len() as u64;
    std::mem::forget(bytes);
    // SAFETY: output pointers are validated above; ownership is transferred to the caller.
    unsafe {
        *output = ptr;
        *output_len = len;
    }
    RENDER_OK
}

/// Returns page dimensions in points and clockwise rotation.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_page_info(doc_id: u64, page: u64, width: *mut f32, height: *mut f32, rotation: *mut u16) -> i32 {
    if width.is_null() || height.is_null() || rotation.is_null() || page > usize::MAX as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Some(document) = session.get(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    let Some(info) = document.info.pages.get(page as usize) else {
        return RENDER_FAILED;
    };
    // SAFETY: output pointers are validated above.
    unsafe {
        *width = info.width;
        *height = info.height;
        *rotation = info.rotation;
    }
    RENDER_OK
}

/// Searches all pages and returns bounded JSON results: `{"page":0,"snippet":"..."}`.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_mobile_search(doc_id: u64, query: *const u8, query_len: u64, output: *mut *mut u8, output_len: *mut u64) -> i32 {
    if query.is_null() || output.is_null() || output_len.is_null() || query_len == 0 || query_len > SEARCH_MAX_QUERY_BYTES as u64 {
        return RENDER_INVALID_ARGUMENT;
    }
    // SAFETY: the caller provides a readable UTF-8 query buffer of `query_len` bytes.
    let query = unsafe { std::slice::from_raw_parts(query, query_len as usize) };
    let Ok(query) = std::str::from_utf8(query) else {
        return RENDER_INVALID_ARGUMENT;
    };
    let session = SESSION.get_or_init(|| Mutex::new(pdfcraft_engine::Session::default()));
    let session = match session.lock() {
        Ok(session) => session,
        Err(_) => return RENDER_FAILED,
    };
    let Some(document) = session.get(pdfcraft_engine::DocId(doc_id)) else {
        return RENDER_FAILED;
    };
    let mut results = Vec::new();
    for page in 0..document.info.pages.len() {
        if results.len() >= SEARCH_MAX_RESULTS {
            break;
        }
        let mut renderer = pdfcraft_render::PageRenderer::new(document.bytes.clone(), pdfcraft_render::RenderConfig::default());
        let Ok(text) = renderer.filtered_text(page, pdfcraft_render::TextFilter::default()) else { continue };
        for range in text.find_opts_limited(query, false, false, SEARCH_MAX_RESULTS - results.len()) {
            let snippet = text.text_of(range).chars().take(160).collect::<String>();
            results.push(format!(r#"{{"page":{page},"snippet":"{}"}}"#, escape_json(&snippet)));
        }
    }
    let mut bytes = format!("[{}]", results.join(",")).into_bytes();
    let ptr = bytes.as_mut_ptr();
    let len = bytes.len() as u64;
    std::mem::forget(bytes);
    // SAFETY: output pointers are validated above; ownership is transferred to the caller.
    unsafe {
        *output = ptr;
        *output_len = len;
    }
    RENDER_OK
}

fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => escaped.push_str(&format!("\\u{:04x}", character as u32)),
            character => escaped.push(character),
        }
    }
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn operation_catalog_is_stable_json() {
        assert!(std::str::from_utf8(OPERATIONS).is_ok());
        assert!(OPERATIONS.starts_with(b"["));
        assert!(OPERATIONS.windows(b"\"id\":\"merge\"".len()).any(|window| window == b"\"id\":\"merge\""));
    }

    #[test]
    fn opening_rejects_invalid_arguments() {
        let mut pages = 0;
        let mut id = 0;
        assert_eq!(pdfcraft_mobile_open_pdf(std::ptr::null(), 0, &mut pages, &mut id), OPEN_INVALID_ARGUMENT);
    }

    #[test]
    fn rendering_rejects_invalid_arguments() {
        let mut output = std::ptr::null_mut();
        let mut len = 0;
        assert_eq!(pdfcraft_mobile_render_page(1, 0, 0, &mut output, &mut len), RENDER_INVALID_ARGUMENT);
    }
}
