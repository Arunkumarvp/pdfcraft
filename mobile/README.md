# PdfCraft Mobile

The mobile client is a Flutter shell over the shared Rust `pdfcraft-engine`. It is intentionally
offline-first: file bytes stay on the device and the UI has no account, analytics, or network
dependencies.

## Status

This first slice establishes:

- Android and iOS Flutter application structure.
- A Material 3 light/dark shell with Home, Documents, and Settings tabs.
- A local operation catalogue for Read, Merge, Split, Organize, Compress, Secure, Unlock, and
  Share.
- Native PDF file selection through the Android/iOS document picker, with a local recent-document
  list.
- Selected PDF bytes are opened by the shared Rust engine session; the UI displays the validated
  page count and native document ID.
- The first page is rendered as a bounded PNG thumbnail by the Rust renderer and displayed in the
  local document list.
- Tapping a document opens a full-screen reader with page navigation and pinch/scroll zoom.
- The reader exposes page dimensions, rotation, and bounded local text search.
- Search results now span the whole document and jump directly to matching pages.
- The reader action menu exposes the shared operation catalogue for document-specific workflows.
- Share exports the active PDF locally, and Split exports the current page as a new PDF through
  the platform save picker.
- Merge selects additional local PDFs, combines them through the Rust engine, and saves the merged
  result locally.
- Compress uses the optimizer's mobile preset and saves the optimized PDF locally.
- Organize rotates the current page clockwise and saves a new organized PDF locally; the source
  document remains unchanged.
- Organize can also delete the current page from a new copy, while the engine rejects attempts to
  remove the document's final page.
- Secure PDF protects a local copy with an open password and AES-256. Unlock PDF requires an
  authorized owner password before removing protection from a local copy.
- A stable C ABI in [`crates/mobile`](../crates/mobile) that is linked to `pdfcraft-engine`.

The native library is built per platform and copied to the Flutter runner by the platform build.
The UI shows the Rust catalogue when the library is present and uses the same labelled catalogue
as a development fallback before native artifacts are generated.

The picker, engine open, document list, and first-page thumbnail are now wired end to end. The
The next slice will add richer page reorder controls and persistent recent-document state.
operations and local export flows.

## Run

```sh
cd mobile
flutter pub get
flutter run
```

Build the Rust library for the selected target before packaging a release. The exact target and
output directory depend on the Flutter platform toolchain; keep generated native artifacts out of
source control.
