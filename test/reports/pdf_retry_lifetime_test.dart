import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';

class _Process extends Mock implements Process {}

void main() {
  test(
    'browser retry keeps the staged input until the PDF is complete',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pdf_retry_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final browser = File('${directory.path}/browser.exe');
      await browser.writeAsBytes([]);
      final retryStarted = Completer<void>();
      final exited = Completer<int>();
      final process = _Process();
      when(() => process.exitCode).thenAnswer((_) => exited.future);
      when(
        () => process.stdout,
      ).thenAnswer((_) => const Stream<List<int>>.empty());
      when(
        () => process.stderr,
      ).thenAnswer((_) => const Stream<List<int>>.empty());
      var attempts = 0;
      late File stagedHtml;
      late File output;
      final exporter = HtmlPdfExporter(
        browserCandidates: [browser.path],
        fontLoader: () async => {'fonts.css': Uint8List(0)},
        processStarter: (_, args) async {
          if (++attempts == 1) {
            throw HtmlToPdfException('External browser PDF export timed out.');
          }
          stagedHtml = File(args.last);
          output = File(
            args
                .firstWhere((arg) => arg.startsWith('--print-to-pdf='))
                .substring('--print-to-pdf='.length),
          );
          retryStarted.complete();
          return process;
        },
      );
      final result = exporter.exportPdf(
        '<html><head></head><body>Report</body></html>',
      );
      await retryStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await stagedHtml.exists(),
        isTrue,
        reason: 'The first attempt timing out must not delete the retry input.',
      );
      final bytes = Uint8List.fromList('%PDF-1.4 test'.codeUnits);
      await output.writeAsBytes(bytes);
      exited.complete(0);
      expect(await result, bytes);
      expect(attempts, 2);
    },
  );
}
