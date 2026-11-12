import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const _fallbackOperations = <Map<String, String>>[
  {'id': 'read', 'title': 'Read', 'description': 'Read, search and navigate PDFs'},
  {'id': 'merge', 'title': 'Merge PDFs', 'description': 'Combine multiple documents'},
  {'id': 'split', 'title': 'Split PDF', 'description': 'Extract selected pages'},
  {'id': 'organize', 'title': 'Organize', 'description': 'Reorder, rotate and delete pages'},
  {'id': 'compress', 'title': 'Compress', 'description': 'Reduce PDF file size'},
  {'id': 'secure', 'title': 'Secure PDF', 'description': 'Add password protection'},
  {'id': 'unlock', 'title': 'Unlock PDF', 'description': 'Remove a password when authorized'},
  {'id': 'share', 'title': 'Share', 'description': 'Export a PDF to another app'},
];

void main() => runApp(const PdfCraftApp());

class PdfCraftApp extends StatelessWidget {
  const PdfCraftApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PdfCraft',
        theme: ThemeData(colorSchemeSeed: const Color(0xffb70228), useMaterial3: true),
        darkTheme: ThemeData.dark(useMaterial3: true).copyWith(colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffb70228),
          brightness: Brightness.dark,
        )),
        themeMode: ThemeMode.system,
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  var _selected = 0;
  final _operations = <Map<String, String>>[..._fallbackOperations];
  final _documents = <_MobileDocument>[];

  @override
  void initState() {
    super.initState();
    _loadNativeCatalogue();
  }

  void _loadNativeCatalogue() {
    try {
      final library = Platform.isAndroid
          ? DynamicLibrary.open('libpdfcraft_mobile.so')
          : DynamicLibrary.process();
      final getJson = library.lookupFunction<
          Pointer<Uint8> Function(Pointer<Uint64>),
          Pointer<Uint8> Function(Pointer<Uint64>)>('pdfcraft_mobile_operations_json');
      final length = calloc<Uint64>();
      final bytes = getJson(length).asTypedList(length.value);
      calloc.free(length);
      final decoded = (jsonDecode(String.fromCharCodes(bytes)) as List)
          .cast<Map>()
          .map((item) => item.cast<String, String>())
          .toList();
      if (mounted) setState(() {
        _operations
          ..clear()
          ..addAll(decoded);
      });
    } on Object catch (error) {
      debugPrint('PdfCraft native catalogue unavailable: $error');
    }
  }

  Future<void> _openPdf([String? operation]) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: false,
    );
    if (!mounted || result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final bytes = await File(path).readAsBytes();
    final metadata = _openInEngine(bytes);
    if (!mounted) return;
    if (metadata == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PdfCraft could not open that PDF.')));
      return;
    }
    setState(() {
      _documents.removeWhere((document) => document.path == path);
      _documents.insert(0, _MobileDocument(
        path: path,
        pageCount: metadata.pageCount,
        id: metadata.id,
        thumbnail: _renderPage(metadata.id, 0, 256),
      ));
    });
    final action = operation == null ? 'Opening' : operation;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$action ${result.files.single.name} locally (${metadata.pageCount} pages).')),
    );
  }

  _OpenMetadata? _openInEngine(Uint8List bytes) {
    Pointer<Uint8>? nativeBytes;
    Pointer<Uint64>? pageCount;
    Pointer<Uint64>? docId;
    try {
      final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
      final open = library.lookupFunction<
          Int32 Function(Pointer<Uint8>, Uint64, Pointer<Uint64>, Pointer<Uint64>),
          int Function(Pointer<Uint8>, int, Pointer<Uint64>, Pointer<Uint64>)>('pdfcraft_mobile_open_pdf');
      nativeBytes = calloc<Uint8>(bytes.length);
      nativeBytes.asTypedList(bytes.length).setAll(0, bytes);
      pageCount = calloc<Uint64>();
      docId = calloc<Uint64>();
      final status = open(nativeBytes, bytes.length, pageCount, docId);
      return status == 0 ? _OpenMetadata(pageCount: pageCount.value, id: docId.value) : null;
    } on Object catch (error) {
      debugPrint('PdfCraft native open unavailable: $error');
      return null;
    } finally {
      if (nativeBytes != null) calloc.free(nativeBytes);
      if (pageCount != null) calloc.free(pageCount);
      if (docId != null) calloc.free(docId);
    }
  }

  Uint8List? _renderPage(int id, int page, int maxWidth) {
    Pointer<Pointer<Uint8>>? output;
    Pointer<Uint64>? outputLength;
    try {
      final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
      final render = library.lookupFunction<
          Int32 Function(Uint64, Uint64, Uint32, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
          int Function(int, int, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>('pdfcraft_mobile_render_page');
      final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
      output = calloc<Pointer<Uint8>>();
      outputLength = calloc<Uint64>();
      final status = render(id, page, maxWidth, output, outputLength);
      if (status != 0 || outputLength.value == 0) return null;
      final result = Uint8List.fromList(output.value.asTypedList(outputLength.value));
      free(output.value, outputLength.value);
      return result;
    } on Object catch (error) {
      debugPrint('PdfCraft thumbnail unavailable: $error');
      return null;
    } finally {
      if (output != null) calloc.free(output);
      if (outputLength != null) calloc.free(outputLength);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PdfCraft')),
        body: IndexedStack(index: _selected, children: [
          HomePage(operations: _operations, onOpen: _openPdf),
          DocumentsPage(paths: _documents, onOpen: (document) => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => ReaderPage(
                  document: document,
                  operations: _operations,
                  renderPage: _renderPage,
                  onAction: _runAction,
                )),
              )),
          const SettingsPage(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selected,
          onDestinationSelected: (index) => setState(() => _selected = index),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Documents'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      );

      Future<void> _runAction(String operation, _MobileDocument document, int page) async {
        if (operation == 'merge') {
          await _mergePdfs(document);
          return;
        }
        if (operation == 'compress') {
          await _saveGeneratedPdf('compress', document, _operationBytes(operation, document.id, page));
          return;
        }
        if (operation == 'secure' || operation == 'unlock') {
          final password = await _requestPassword(operation);
          if (password == null) return;
          await _saveGeneratedPdf(operation, document, _operationBytes(operation, document.id, page, password: password));
          return;
        }
        if (operation == 'organize') {
          final delete = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Organize page'),
              content: const Text('Rotate the current page or delete it from a new copy?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Rotate 90°')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete page')),
              ],
            ),
          );
          if (delete == true) {
            await _saveGeneratedPdf('delete-page', document, _operationBytes('delete-page', document.id, page));
          } else if (delete == false) {
            await _saveGeneratedPdf('rotate', document, _operationBytes('organize', document.id, page));
          }
          return;
        }
        final bytes = _operationBytes(operation, document.id, page);
        if (bytes == null || !mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$operation could not be completed locally.')));
          return;
        }
        final extension = operation == 'split' ? '-page-${page + 1}' : '';
        final name = document.path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
        await _saveGeneratedPdf(operation, document, bytes, extension: extension);
      }

      Future<void> _saveGeneratedPdf(String operation, _MobileDocument document, Uint8List? bytes, {String extension = ''}) async {
        if (bytes == null || !mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$operation could not be completed locally.')));
          return;
        }
        final name = document.path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
        final saved = await FilePicker.platform.saveFile(
          fileName: '$name-$operation$extension.pdf',
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (mounted && saved != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved locally to $saved.')));
        }
      }

      Future<void> _mergePdfs(_MobileDocument document) async {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
          allowMultiple: true,
          withData: false,
        );
        if (!mounted || result == null || result.files.isEmpty) return;
        final first = await File(document.path).readAsBytes();
        Uint8List? merged = first;
        for (final file in result.files) {
          final path = file.path;
          if (path == null) continue;
          final second = await File(path).readAsBytes();
          merged = _mergePair(merged!, second);
          if (merged == null) break;
        }
        if (!mounted) return;
        if (merged == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PdfCraft could not merge those PDFs.')));
          return;
        }
        final baseName = document.path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
        final saved = await FilePicker.platform.saveFile(
          fileName: '$baseName-merged.pdf',
          bytes: merged,
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (mounted && saved != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Merged PDF saved locally to $saved.')));
        }
      }

      Uint8List? _mergePair(Uint8List first, Uint8List second) {
        Pointer<Uint8>? firstPointer;
        Pointer<Uint8>? secondPointer;
        Pointer<Pointer<Uint8>>? output;
        Pointer<Uint64>? length;
        try {
          final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
          final merge = library.lookupFunction<
              Int32 Function(Pointer<Uint8>, Uint64, Pointer<Uint8>, Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
              int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>('pdfcraft_mobile_merge_pdfs');
          final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
          firstPointer = calloc<Uint8>(first.length);
          secondPointer = calloc<Uint8>(second.length);
          firstPointer.asTypedList(first.length).setAll(0, first);
          secondPointer.asTypedList(second.length).setAll(0, second);
          output = calloc<Pointer<Uint8>>();
          length = calloc<Uint64>();
          if (merge(firstPointer, first.length, secondPointer, second.length, output, length) != 0) return null;
          final bytes = Uint8List.fromList(output.value.asTypedList(length.value));
          free(output.value, length.value);
          return bytes;
        } on Object catch (error) {
          debugPrint('PdfCraft merge unavailable: $error');
          return null;
        } finally {
          if (firstPointer != null) calloc.free(firstPointer);
          if (secondPointer != null) calloc.free(secondPointer);
          if (output != null) calloc.free(output);
          if (length != null) calloc.free(length);
        }
      }

      Future<String?> _requestPassword(String operation) async {
        final controller = TextEditingController();
        final password = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(operation == 'secure' ? 'Protect PDF' : 'Unlock PDF'),
            content: TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: operation == 'secure' ? 'New password' : 'Owner password'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Continue')),
            ],
          ),
        );
        controller.dispose();
        return password?.isEmpty == true ? null : password;
      }

      Uint8List? _operationBytes(String operation, int id, int page, {String? password}) {
        final symbol = switch (operation) {
          'share' => 'pdfcraft_mobile_export_pdf',
          'split' => 'pdfcraft_mobile_extract_page',
          'compress' => 'pdfcraft_mobile_compress_pdf',
          'organize' => 'pdfcraft_mobile_rotate_page',
          'delete-page' => 'pdfcraft_mobile_delete_page',
          'secure' => 'pdfcraft_mobile_protect_pdf',
          'unlock' => 'pdfcraft_mobile_unlock_pdf',
          _ => null,
        };
        if (symbol == null) return null;
        Pointer<Pointer<Uint8>>? output;
        Pointer<Uint64>? length;
        try {
          final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
          if (symbol == 'pdfcraft_mobile_protect_pdf' || symbol == 'pdfcraft_mobile_unlock_pdf') {
            final call = library.lookupFunction<
                Int32 Function(Uint64, Pointer<Uint8>, Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
                int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>(symbol);
            final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
            final encoded = Uint8List.fromList(utf8.encode(password ?? ''));
            final nativePassword = calloc<Uint8>(encoded.length);
            output = calloc<Pointer<Uint8>>();
            length = calloc<Uint64>();
            nativePassword.asTypedList(encoded.length).setAll(0, encoded);
            if (call(id, nativePassword, encoded.length, output, length) != 0) {
              calloc.free(nativePassword);
              return null;
            }
            final bytes = Uint8List.fromList(output.value.asTypedList(length.value));
            free(output.value, length.value);
            calloc.free(nativePassword);
            return bytes;
          }
          if (symbol == 'pdfcraft_mobile_delete_page') {
            final delete = library.lookupFunction<
                Int32 Function(Uint64, Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
                int Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>('pdfcraft_mobile_delete_page');
            final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
            output = calloc<Pointer<Uint8>>();
            length = calloc<Uint64>();
            if (delete(id, page, output, length) != 0) return null;
            final bytes = Uint8List.fromList(output.value.asTypedList(length.value));
            free(output.value, length.value);
            return bytes;
          }
          if (symbol == 'pdfcraft_mobile_rotate_page') {
            final rotate = library.lookupFunction<
                Int32 Function(Uint64, Uint64, Int64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
                int Function(int, int, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>(
                    symbol == 'pdfcraft_mobile_rotate_page' ? 'pdfcraft_mobile_rotate_page' : 'pdfcraft_mobile_delete_page');
            final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
            output = calloc<Pointer<Uint8>>();
            length = calloc<Uint64>();
            if (rotate(id, page, symbol == 'pdfcraft_mobile_rotate_page' ? 90 : 0, output, length) != 0) return null;
            final bytes = Uint8List.fromList(output.value.asTypedList(length.value));
            free(output.value, length.value);
            return bytes;
          }
          final call = symbol == 'pdfcraft_mobile_export_pdf' || symbol == 'pdfcraft_mobile_compress_pdf'
              ? library.lookupFunction<
                  Int32 Function(Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
                  int Function(int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>(symbol)
              : library.lookupFunction<
                  Int32 Function(Uint64, Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
                  int Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>(symbol);
          final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
          output = calloc<Pointer<Uint8>>();
          length = calloc<Uint64>();
          final status = symbol == 'pdfcraft_mobile_export_pdf' || symbol == 'pdfcraft_mobile_compress_pdf'
              ? (call as int Function(int, Pointer<Pointer<Uint8>>, Pointer<Uint64>))(id, output, length)
              : (call as int Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>))(id, page, output, length);
          if (status != 0) return null;
          final result = Uint8List.fromList(output.value.asTypedList(length.value));
          free(output.value, length.value);
          return result;
        } on Object catch (error) {
          debugPrint('PdfCraft operation unavailable: $error');
          return null;
        } finally {
          if (output != null) calloc.free(output);
          if (length != null) calloc.free(length);
        }
      }
}

class HomePage extends StatelessWidget {
  const HomePage({required this.operations, required this.onOpen, super.key});
  final List<Map<String, String>> operations;
  final Future<void> Function([String? operation]) onOpen;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Your documents stay yours.', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('Fast, private PDF tools that work offline.', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: () => onOpen(), icon: const Icon(Icons.file_open), label: const Text('Open PDF')),
          const SizedBox(height: 24),
          Text('Tools', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          ...operations.map((operation) => Card(
                child: ListTile(
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: Text(operation['title']!),
                  subtitle: Text(operation['description']!),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onOpen(operation['title']),
                ),
              )),
        ],
      );
}

class DocumentsPage extends StatelessWidget {
  const DocumentsPage({required this.paths, required this.onOpen, super.key});
  final List<_MobileDocument> paths;
  final void Function(_MobileDocument document) onOpen;

  @override
  Widget build(BuildContext context) => paths.isEmpty
      ? const Center(child: EmptyState(icon: Icons.folder_open, title: 'No documents yet', message: 'Open a PDF to see it here.'))
      : ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: paths.length,
          itemBuilder: (context, index) => ListTile(
            onTap: () => onOpen(paths[index]),
            leading: const Icon(Icons.picture_as_pdf),
            title: Text(paths[index].path.split(Platform.pathSeparator).last),
            subtitle: Text('${paths[index].pageCount} pages · Engine document ${paths[index].id}'),
            trailing: paths[index].thumbnail == null
                ? null
                : Image.memory(paths[index].thumbnail!, width: 48, height: 64, fit: BoxFit.contain),
          ),
        );
}

class _OpenMetadata {
  const _OpenMetadata({required this.pageCount, required this.id});
  final int pageCount;
  final int id;
}

class _MobileDocument {
  const _MobileDocument({required this.path, required this.pageCount, required this.id, this.thumbnail});
  final String path;
  final int pageCount;
  final int id;
  final Uint8List? thumbnail;
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({required this.document, required this.operations, required this.renderPage, required this.onAction, super.key});
  final _MobileDocument document;
  final List<Map<String, String>> operations;
  final Uint8List? Function(int id, int page, int maxWidth) renderPage;
  final Future<void> Function(String operation, _MobileDocument document, int page) onAction;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  var _page = 0;
  Uint8List? _image;
  String _text = '';
  String _query = '';
  List<_SearchResult> _results = [];
  double _width = 0;
  double _height = 0;
  int _rotation = 0;

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  void _loadPage() {
    setState(() => _image = widget.renderPage(widget.document.id, _page, 1400));
    _loadTextAndInfo();
  }

  void _loadTextAndInfo() {
    final metadata = _pageInfo(widget.document.id, _page);
    final text = _pageText(widget.document.id, _page);
    if (!mounted) return;
    setState(() {
      _text = text ?? '';
      _width = metadata?.$1 ?? 0;
      _height = metadata?.$2 ?? 0;
      _rotation = metadata?.$3 ?? 0;
    });
  }

  void _search(String query) {
    setState(() {
      _query = query;
      _results = _searchDocument(widget.document.id, query);
    });
  }

  void _move(int delta) {
    final next = _page + delta;
    if (next < 0 || next >= widget.document.pageCount) return;
    setState(() => _page = next);
    _loadPage();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.document.path.split(Platform.pathSeparator).last),
          actions: [
            IconButton(
              tooltip: 'Actions',
              onPressed: () => _showActions(context),
              icon: const Icon(Icons.more_vert),
            ),
            Center(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('${_page + 1} / ${widget.document.pageCount}'),
            )),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search this page',
                  prefixIcon: const Icon(Icons.search),
                  suffixText: _query.isEmpty ? null : '${_matches()} matches',
                  border: const OutlineInputBorder(),
                ),
                onChanged: _search,
              ),
            ),
            if (_query.isNotEmpty && _results.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: _results.map((result) => ActionChip(
                    label: Text('Page ${result.page + 1}: ${result.snippet}'),
                    onPressed: () {
                      setState(() => _page = result.page);
                      _loadPage();
                    },
                  )).toList(),
                ),
              ),
            if (_width > 0)
              Text('${_width.toStringAsFixed(0)} × ${_height.toStringAsFixed(0)} pt · ${_rotation}°'),
            Expanded(child: _image == null
                ? const Center(child: Text('This page could not be rendered.'))
                : InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4,
                    boundaryMargin: const EdgeInsets.all(48),
                    child: Center(child: Image.memory(_image!, fit: BoxFit.contain)),
                  )),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(onPressed: _page == 0 ? null : () => _move(-1), icon: const Icon(Icons.chevron_left)),
              Text('Page ${_page + 1}'),
              IconButton(onPressed: _page + 1 >= widget.document.pageCount ? null : () => _move(1), icon: const Icon(Icons.chevron_right)),
            ],
          ),
        ),
      );

  int _matches() {
    if (_query.trim().isEmpty) return 0;
    return RegExp(RegExp.escape(_query.trim()), caseSensitive: false).allMatches(_text).length;
  }

  (double, double, int)? _pageInfo(int id, int page) {
    Pointer<Float>? width;
    Pointer<Float>? height;
    Pointer<Uint16>? rotation;
    try {
      final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
      final info = library.lookupFunction<
          Int32 Function(Uint64, Uint64, Pointer<Float>, Pointer<Float>, Pointer<Uint16>),
          int Function(int, int, Pointer<Float>, Pointer<Float>, Pointer<Uint16>)>('pdfcraft_mobile_page_info');
      width = calloc<Float>();
      height = calloc<Float>();
      rotation = calloc<Uint16>();
      return info(id, page, width, height, rotation) == 0 ? (width.value, height.value, rotation.value) : null;
    } on Object catch (error) {
      debugPrint('PdfCraft page info unavailable: $error');
      return null;
    } finally {
      if (width != null) calloc.free(width);
      if (height != null) calloc.free(height);
      if (rotation != null) calloc.free(rotation);
    }
  }

  String? _pageText(int id, int page) {
    Pointer<Pointer<Uint8>>? output;
    Pointer<Uint64>? length;
    try {
      final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
      final extract = library.lookupFunction<
          Int32 Function(Uint64, Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
          int Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>('pdfcraft_mobile_page_text');
      final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
      output = calloc<Pointer<Uint8>>();
      length = calloc<Uint64>();
      if (extract(id, page, output, length) != 0) return null;
      final text = String.fromCharCodes(output.value.asTypedList(length.value));
      free(output.value, length.value);
      return text;
    } on Object catch (error) {
      debugPrint('PdfCraft page text unavailable: $error');
      return null;
    } finally {
      if (output != null) calloc.free(output);
      if (length != null) calloc.free(length);
    }

    List<_SearchResult> _searchDocument(int id, String query) {
      if (query.trim().isEmpty) return [];
      Pointer<Uint8>? nativeQuery;
      Pointer<Pointer<Uint8>>? output;
      Pointer<Uint64>? length;
      try {
        final library = Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_mobile.so') : DynamicLibrary.process();
        final search = library.lookupFunction<
            Int32 Function(Uint64, Pointer<Uint8>, Uint64, Pointer<Pointer<Uint8>>, Pointer<Uint64>),
            int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Uint64>)>('pdfcraft_mobile_search');
        final free = library.lookupFunction<Void Function(Pointer<Uint8>, Uint64), void Function(Pointer<Uint8>, int)>('pdfcraft_mobile_free_buffer');
        final queryBytes = Uint8List.fromList(utf8.encode(query));
        nativeQuery = calloc<Uint8>(queryBytes.length);
        nativeQuery.asTypedList(queryBytes.length).setAll(0, queryBytes);
        output = calloc<Pointer<Uint8>>();
        length = calloc<Uint64>();
        if (search(id, nativeQuery, queryBytes.length, output, length) != 0) return [];
        final decoded = (jsonDecode(String.fromCharCodes(output.value.asTypedList(length.value))) as List).cast<Map>();
        free(output.value, length.value);
        return decoded.map((item) => _SearchResult(page: item['page'] as int, snippet: item['snippet'] as String)).toList();
      } on Object catch (error) {
        debugPrint('PdfCraft document search unavailable: $error');
        return [];
      } finally {
        if (nativeQuery != null) calloc.free(nativeQuery);
        if (output != null) calloc.free(output);
        if (length != null) calloc.free(length);
      }
    }

    void _showActions(BuildContext context) {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: widget.operations.map((operation) => ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: Text(operation['title']!),
              subtitle: Text(operation['description']!),
              onTap: () {
                Navigator.pop(context);
                if (operation['id'] == 'merge' || operation['id'] == 'share' || operation['id'] == 'split' || operation['id'] == 'compress' || operation['id'] == 'organize' || operation['id'] == 'secure' || operation['id'] == 'unlock') {
                  widget.onAction(operation['id']!, widget.document, _page);
                } else {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(content: Text('${operation['title']} is next in the local Rust workflow.')),
                  );
                }
              },
            )).toList(),
          ),
        ),
      );
    }
  }

  class _SearchResult {
    const _SearchResult({required this.page, required this.snippet});
    final int page;
    final String snippet;
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          ListTile(leading: Icon(Icons.cloud_off), title: Text('Offline by design'), subtitle: Text('No uploads, accounts, or tracking.')),
          ListTile(leading: Icon(Icons.lock_outline), title: Text('Privacy'), subtitle: Text('PdfCraft processes documents on this device.')),
          ListTile(leading: Icon(Icons.info_outline), title: Text('About PdfCraft'), subtitle: Text('Open-source PDF workbench')),
        ],
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.icon, required this.title, required this.message, super.key});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Icon(icon, size: 56), const SizedBox(height: 12), Text(title), Text(message)],
      );
}
