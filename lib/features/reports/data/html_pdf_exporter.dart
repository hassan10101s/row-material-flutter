import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// Raised when the headless browser finished but did not produce a PDF.
class HtmlToPdfException implements Exception {
  HtmlToPdfException(this.message);
  final String message;
  @override
  String toString() => 'HtmlToPdfException: $message';
}

/// Raised when no Edge/Chrome binary is available for headless conversion.
class HtmlToPdfUnavailableException implements Exception {
  HtmlToPdfUnavailableException(
      [this.message = 'No headless browser (Edge/Chrome) available for HTML->PDF export.']);
  final String message;
  @override
  String toString() => message;
}

/// Port of `core/infrastructure/pdf_headless.py` `PdfExporter`.
///
/// Converts rendered report HTML into PDF the exact same way the reference
/// Vue project does: find Edge or Chrome on PATH / standard install dirs, stage
/// the HTML next to the `fonts/` assets so the relative `fonts/fonts.css`
/// stylesheet resolves, inject the `@page { margin: 9mm 8mm; }` header/footer
/// suppression override (unless [noPageOverride], which label templates need
/// because they carry their own `@page` rules), then run
/// `--headless --print-to-pdf`.
class HtmlPdfExporter {
  HtmlPdfExporter({
    List<String>? browserCandidates,
    Duration? browserTimeout,
    Future<Map<String, Uint8List>> Function()? fontLoader,
  })  : _browserCandidates = browserCandidates ?? defaultCandidates,
        _browserTimeout = browserTimeout ?? const Duration(seconds: 45),
        _fontLoader = fontLoader ?? _loadFontsFromAssets;

  final List<String> _browserCandidates;
  final Duration _browserTimeout;
  final Future<Map<String, Uint8List>> Function() _fontLoader;

  /// Same candidate list as `pdf_headless.py:_find_headless_browser`.
  static const List<String> defaultCandidates = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  static const List<String> _fontNames = [
    'fonts.css',
    'IBMPlexSansArabic-400.woff2',
    'IBMPlexSansArabic-500.woff2',
    'IBMPlexSansArabic-600.woff2',
    'IBMPlexSansArabic-700.woff2',
    'Inter.woff2',
  ];

  static Future<Map<String, Uint8List>> _loadFontsFromAssets() async {
    final out = <String, Uint8List>{};
    for (final name in _fontNames) {
      final path = 'assets/templates/fonts/$name';
      final bytes = await _loadAssetBytes(path);
      out[name] = bytes;
    }
    return out;
  }

  /// rootBundle first (production); direct file read fallback for tests where
  /// the flutter-test asset bundle can be stale.
  static Future<Uint8List> _loadAssetBytes(String path) async {
    try {
      final data = await rootBundle.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return File(path).readAsBytes();
    }
  }

  String? _browserCache;

  /// Port of `pdf_headless.py:_find_headless_browser`.
  Future<String?> findBrowser() async {
    if (_browserCache != null) return _browserCache;
    for (final candidate in _browserCandidates) {
      try {
        if (await File(candidate).exists()) {
          return _browserCache = candidate;
        }
      } catch (_) {
        // Malformed path on non-Windows; skip.
      }
    }
    for (final name in const ['msedge.exe', 'chrome.exe']) {
      final resolved = await _which(name);
      if (resolved != null) return _browserCache = resolved;
    }
    return null;
  }

  static Future<String?> _which(String name) async {
    try {
      final bin = Platform.isWindows ? 'where.exe' : 'which';
      final result = await Process.run(bin, [name]);
      if (result.exitCode == 0) {
        final line = '${result.stdout}'.trim().split(RegExp(r'\r?\n')).first;
        if (line.isNotEmpty && File(line).existsSync()) return line;
      }
    } catch (_) {}
    return null;
  }

  /// Port of `export_html` — render [html] to a PDF and return its bytes.
  ///
  /// Throws [HtmlToPdfUnavailableException] when no browser exists so callers
  /// can fall back to the dart-pdf renderer.
  Future<Uint8List> exportPdf(
    String html, {
    String? baseHref,
    bool noPageOverride = false,
  }) async {
    final browser = await findBrowser();
    if (browser == null) {
      throw HtmlToPdfUnavailableException();
    }
    final tmp = await Directory.systemTemp.createTemp('material_lab_pdf_');
    try {
      final htmlWithCss = _injectBaseHref(
          noPageOverride ? html : _applyPageOverride(html), baseHref);
      final htmlFile = File(p.join(tmp.path, 'report.html'));
      await htmlFile.writeAsString(htmlWithCss, flush: true);

      final fontsDir = Directory(p.join(tmp.path, 'fonts'));
      await fontsDir.create(recursive: true);
      final fonts = await _fontLoader();
      for (final entry in fonts.entries) {
        await File(p.join(fontsDir.path, entry.key))
            .writeAsBytes(entry.value, flush: true);
      }

      final outFile = File(p.join(tmp.path, 'out.pdf'));
      final profileDir = Directory(p.join(tmp.path, 'profile'));
      await profileDir.create(recursive: true);

      final args = [
        '--headless',
        '--disable-gpu',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-networking',
        '--disable-sync',
        '--allow-file-access-from-files',
        '--print-to-pdf-no-header',
        '--no-pdf-header-footer',
        '--user-data-dir=${profileDir.path}',
        '--print-to-pdf=${outFile.path}',
        htmlFile.path,
      ];

      final process = await Process.start(browser, args);
      final exitCode = await process.exitCode.timeout(
        _browserTimeout,
        onTimeout: () {
          process.kill();
          throw HtmlToPdfException('External browser PDF export timed out.');
        },
      );
      final stderr = await process.stderr.transform(utf8.decoder).join();
      if (exitCode != 0) {
        final details = stderr.trim();
        throw HtmlToPdfException(
            details.isEmpty ? 'External browser PDF export failed.' : details);
      }
      if (!await outFile.exists()) {
        throw HtmlToPdfException(
            'External browser PDF export did not create the file.');
      }
      final bytes = await outFile.readAsBytes();
      if (bytes.isEmpty) {
        throw HtmlToPdfException(
            'External browser PDF export created an empty file.');
      }
      return bytes;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Port of `_apply_page_override` CSS: `@page` margins + hide header/footer.
  static String _applyPageOverride(String html) {
    const cssHide = '<style>'
        '@page { margin: 9mm 8mm; }'
        '@page { '
        '@top-left { content: none; }'
        '@top-center { content: none; }'
        '@top-right { content: none; }'
        '@bottom-left { content: none; }'
        '@bottom-center { content: none; }'
        '@bottom-right { content: none; }'
        '}'
        '</style>';
    return html.contains('</head>')
        ? html.replaceFirst('</head>', '$cssHide</head>')
        : html;
  }

  static String _injectBaseHref(String html, String? baseHref) {
    if (baseHref == null || baseHref.isEmpty || html.toLowerCase().contains('<base ')) {
      return html;
    }
    final href = baseHref.replaceAll('\\', '/');
    return html.contains('<head>')
        ? html.replaceFirst('<head>', '<head><base href="$href">')
        : '<base href="$href">$html';
  }
}