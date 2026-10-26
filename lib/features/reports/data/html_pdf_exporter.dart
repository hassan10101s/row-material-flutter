import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show rootBundle, MethodChannel, PlatformException;
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  HtmlToPdfUnavailableException([
    this.message =
        'No headless browser (Edge/Chrome) available for HTML->PDF export.',
  ]);
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
    Future<Process> Function(String, List<String>)? processStarter,
  }) : _browserCandidates = browserCandidates ?? defaultCandidates,
       _browserTimeout = browserTimeout ?? const Duration(seconds: 45),
       _fontLoader = fontLoader ?? _loadFontsFromAssets,
       _processStarter =
           processStarter ??
           ((executable, args) => Process.start(executable, args));

  final List<String> _browserCandidates;
  final Duration _browserTimeout;
  final Future<Map<String, Uint8List>> Function() _fontLoader;
  final Future<Process> Function(String, List<String>) _processStarter;

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

  /// Process-wide browser cache: the exporter is cheap to construct, so an
  /// instance field would re-scan the filesystem on every report.
  static String? _browserCache;

  /// Font bytes, loaded once per process: six files re-read from the asset
  /// bundle on every export used to add hundreds of milliseconds before the
  /// browser even started.
  static Map<String, Uint8List>? _fontCache;

  /// One warm browser profile reused by every export in this process.
  ///
  /// Each export used to create a brand-new `--user-data-dir`, forcing Edge to
  /// run its first-run profile initialization (~seconds on Windows) on top of
  /// the normal cold start. A stable profile pays that cost once; later
  /// exports only pay the browser launch itself.
  static Future<Directory>? _profileDirFuture;

  /// Serializes browser runs: two headless instances sharing one profile
  /// directory trip over the profile lock, so concurrent exports queue here
  /// instead of failing. The UI already guards with one busy flag, this is
  /// the backstop for programmatic overlap.
  static Future<void> _browserGate = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() task) {
    final run = _browserGate.then((_) => task());
    _browserGate = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Port of `pdf_headless.py:_find_headless_browser`.
  ///
  /// Order: explicit candidates → PATH (`where.exe`/`which`) → Windows
  /// registry `App Paths` (covers non-default install dirs, MSIX-safe
  /// read-only `reg query`). Result cached per process. Never throws.
  Future<String?> findBrowser() async {
    if (_browserCache != null) return _browserCache;
    // Existence checks in parallel: four sequential filesystem round trips
    // on every cold start otherwise.
    final checks = await Future.wait([
      for (final candidate in _browserCandidates) _exists(candidate),
    ]);
    for (var i = 0; i < checks.length; i++) {
      if (checks[i]) return _browserCache = _browserCandidates[i];
    }
    for (final name in const ['msedge.exe', 'chrome.exe']) {
      final resolved = await _which(name);
      if (resolved != null) return _browserCache = resolved;
    }
    if (Platform.isWindows) {
      for (final key in const [
        r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
      ]) {
        final resolved = await _registryAppPath(key);
        if (resolved != null) return _browserCache = resolved;
      }
    }
    return null;
  }

  static Future<bool> _exists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      // Malformed path on non-Windows; skip.
      return false;
    }
  }

  static Future<String?> _which(String name) async {
    try {
      final bin = Platform.isWindows ? 'where.exe' : 'which';
      final result = await Process.run(bin, [name]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
      );
      if (result.exitCode == 0) {
        final line = '${result.stdout}'.trim().split(RegExp(r'\r?\n')).first;
        if (line.isNotEmpty && File(line).existsSync()) return line;
      }
    } catch (_) {}
    return null;
  }

  /// Reads the default value of an `App Paths` registry key (e.g. the Edge
  /// install dir when it is not on PATH and not in Program Files). Read-only,
  /// works inside MSIX containers. Returns null on any failure.
  static Future<String?> _registryAppPath(String key) async {
    try {
      final result = await Process.run('reg', ['query', key, '/ve']).timeout(
        const Duration(seconds: 5),
        onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
      );
      if (result.exitCode != 0) return null;
      final out = '${result.stdout}';
      // Output line looks like: `(Default)    REG_SZ    C:\...\msedge.exe`
      for (final line in out.split(RegExp(r'\r?\n'))) {
        final idx = line.indexOf('REG_SZ');
        if (idx < 0) continue;
        final candidate = line.substring(idx + 'REG_SZ'.length).trim();
        if (candidate.toLowerCase().endsWith('.exe') &&
            await _exists(candidate)) {
          return candidate;
        }
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
  }) => _serialized(
    () => Platform.isAndroid
        ? _exportAndroid(html, noPageOverride: noPageOverride)
        : _exportPdf(html, baseHref: baseHref, noPageOverride: noPageOverride),
  );

  Future<Uint8List> _exportAndroid(
    String html, {
    required bool noPageOverride,
  }) async {
    final request = await androidRequest(html, noPageOverride: noPageOverride);
    try {
      final bytes = await const MethodChannel(
        'material_lab/html_pdf',
      ).invokeMethod<Uint8List>('render', request);
      if (bytes == null ||
          bytes.length < 5 ||
          ascii.decode(bytes.sublist(0, 5)) != '%PDF-') {
        throw HtmlToPdfException('Android did not return a valid PDF document');
      }
      return bytes;
    } on PlatformException catch (e) {
      throw HtmlToPdfException(e.message ?? e.code);
    }
  }

  @visibleForTesting
  Future<Map<String, Object>> androidRequest(
    String html, {
    bool noPageOverride = false,
  }) async {
    final fonts = await _cachedFonts();
    var css = utf8.decode(fonts['fonts.css']!);
    for (final entry in fonts.entries) {
      if (entry.key == 'fonts.css') continue;
      css = css.replaceAll(
        entry.key,
        'data:font/woff2;base64,${base64Encode(entry.value)}',
      );
    }
    var document = noPageOverride ? html : _applyPageOverride(html);
    document = document.replaceAll(
      RegExp(
        r'<link\b[^>]*href=["\x27]fonts/fonts\.css["\x27][^>]*>',
        caseSensitive: false,
      ),
      '<style>$css</style>',
    );
    if (!document.contains('data:font/woff2')) {
      document = document.replaceFirst('</head>', '<style>$css</style></head>');
    }
    final size =
        RegExp(
          r'@page\s*\{[^}]*\bsize\s*:\s*([^;}]*)',
          caseSensitive: false,
        ).firstMatch(document)?.group(1)?.trim().toLowerCase() ??
        'a4';
    double width = 210, height = 297;
    final mm = RegExp(r'([\d.]+)(mm|cm)\s+([\d.]+)(mm|cm)').firstMatch(size);
    if (mm != null) {
      width = double.parse(mm.group(1)!) * (mm.group(2) == 'cm' ? 10 : 1);
      height = double.parse(mm.group(3)!) * (mm.group(4) == 'cm' ? 10 : 1);
    } else if (size.contains('landscape')) {
      width = 297;
      height = 210;
    }
    final marginMatches = RegExp(
      r'@page\s*\{[^}]*\bmargin\s*:\s*([^;}]+)',
      caseSensitive: false,
    ).allMatches(document);
    final margins = (marginMatches.isEmpty ? '0' : marginMatches.last.group(1)!)
        .trim()
        .split(RegExp(r'\s+'))
        .map((token) {
          final value =
              double.tryParse(token.replaceAll(RegExp(r'[^\d.]'), '')) ?? 0;
          return (value * (token.endsWith('cm') ? 10 : 1) / 25.4 * 1000)
              .round();
        })
        .toList();
    return {
      'html': document,
      'widthMils': (width / 25.4 * 1000).round(),
      'heightMils': (height / 25.4 * 1000).round(),
      'topMils': margins.first,
      'rightMils': margins.length > 1 ? margins[1] : margins.first,
      'bottomMils': margins.length > 2 ? margins[2] : margins.first,
      'leftMils': margins.length > 3
          ? margins[3]
          : margins.length > 1
          ? margins[1]
          : margins.first,
    };
  }

  Future<Uint8List> _exportPdf(
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
        noPageOverride ? html : _applyPageOverride(html),
        baseHref,
      );
      final htmlFile = File(p.join(tmp.path, 'report.html'));

      // Staging in parallel: HTML + font bytes + font dir resolve together
      // instead of one await after another.
      final fontsDir = Directory(p.join(tmp.path, 'fonts'));
      final results = await Future.wait([
        htmlFile.writeAsString(htmlWithCss, flush: true),
        _cachedFonts(),
        fontsDir.create(recursive: true),
      ]);
      final fonts = results[1] as Map<String, Uint8List>;
      await Future.wait([
        for (final entry in fonts.entries)
          File(
            p.join(fontsDir.path, entry.key),
          ).writeAsBytes(entry.value, flush: true),
      ]);

      final outFile = File(p.join(tmp.path, 'out.pdf'));
      final profileDir = await _warmProfileDir();

      try {
        return await _runBrowser(
          browser,
          profileDir: profileDir.path,
          outFile: outFile,
          htmlFile: htmlFile,
        );
      } on HtmlToPdfException catch (e) {
        // A stale Singleton lock from a killed run can wedge the shared
        // profile; retry once with a throwaway profile instead of failing
        // the whole report.
        if (!_looksLikeProfileLock(e.message) &&
            !e.message.contains('timed out') &&
            !e.message.contains('did not create the file')) {
          rethrow;
        }
        final fallbackProfile = await Directory(
          p.join(tmp.path, 'profile_fresh'),
        ).create(recursive: true);
        // Keep the staged HTML/fonts alive until the retry has finished.
        // Returning the future directly would run `finally` immediately and
        // remove the input files while the fallback browser still uses them.
        return await _runBrowser(
          browser,
          profileDir: fallbackProfile.path,
          outFile: outFile,
          htmlFile: htmlFile,
        );
      }
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<Uint8List> _runBrowser(
    String browser, {
    required String profileDir,
    required File outFile,
    required File htmlFile,
  }) async {
    final args = [
      '--headless',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-sync',
      '--disable-extensions',
      '--allow-file-access-from-files',
      '--print-to-pdf-no-header',
      '--no-pdf-header-footer',
      '--user-data-dir=$profileDir',
      '--print-to-pdf=${outFile.path}',
      htmlFile.path,
    ];

    final process = await _processStarter(browser, args);
    // Drain while the browser runs; a full stderr pipe can otherwise stop the
    // child before it exits, leaving a completed report waiting on a timeout.
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode.timeout(
      _browserTimeout,
      onTimeout: () {
        process.kill();
        throw HtmlToPdfException('External browser PDF export timed out.');
      },
    );
    await stdoutDone;
    final stderr = await stderrDone;
    if (exitCode != 0) {
      final details = stderr.trim();
      throw HtmlToPdfException(
        details.isEmpty ? 'External browser PDF export failed.' : details,
      );
    }
    if (!await outFile.exists()) {
      throw HtmlToPdfException(
        'External browser PDF export did not create the file.',
      );
    }
    final bytes = await outFile.readAsBytes();
    if (bytes.isEmpty) {
      throw HtmlToPdfException(
        'External browser PDF export created an empty file.',
      );
    }
    return bytes;
  }

  /// Font bytes, fetched once per process instead of six asset reads + disk
  /// writes per report.
  Future<Map<String, Uint8List>> _cachedFonts() async {
    var cached = _fontCache;
    if (cached == null) {
      cached = await _fontLoader();
      _fontCache = cached;
    }
    return cached;
  }

  /// The shared warm profile, created once per process.
  static Future<Directory> _warmProfileDir() {
    return _profileDirFuture ??= Directory(
      p.join(Directory.systemTemp.path, 'material_lab_pdf_profile_$pid'),
    ).create(recursive: true);
  }

  static bool _looksLikeProfileLock(String message) {
    final lower = message.toLowerCase();
    return lower.contains('singleton') ||
        (lower.contains('profile') && lower.contains('lock')) ||
        lower.contains('already running') ||
        lower.contains('user-data-dir');
  }

  /// Port of `_apply_page_override` CSS: `@page` margins + hide header/footer.
  static String _applyPageOverride(String html) {
    const cssHide =
        '<style>'
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
    if (baseHref == null ||
        baseHref.isEmpty ||
        html.toLowerCase().contains('<base ')) {
      return html;
    }
    final href = baseHref.replaceAll('\\', '/');
    return html.contains('<head>')
        ? html.replaceFirst('<head>', '<head><base href="$href">')
        : '<base href="$href">$html';
  }
}
