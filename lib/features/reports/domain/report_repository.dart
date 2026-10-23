import 'dart:io';
import 'dart:typed_data';

/// Report generation and PDF export.
///
/// ## Why a contract
///
/// `ReportService` is the widest-reaching concrete class in the app: the reports
/// screen, the inspections screen, the inspection-detail cubit, the inspections
/// cubit and the lab-reports cubit all hold one, and five of those imports are
/// frozen ratchet entries. It is also ~500 lines that reach into
/// `HtmlPdfExporter` (which shells out to a headless browser), `settingsRepo`,
/// `inspectionRepo` and `labRepo`.
///
/// [ReportDoc] lives here rather than beside the implementation because the
/// cubits name it in their own signatures (`Future<ReportDoc> Function()` job
/// builders) - it is part of what presentation talks about, not an artifact of
/// how the PDF happens to be produced.
///
/// [ReportRepository] keeps only the report API. How the bytes get produced
/// (headless Edge/Chrome with a dart-pdf fallback) stays behind the interface.
abstract interface class ReportRepository {
  // ── Inspection documents ───────────────────────────────────────

  /// Full inspection report for one sample.
  Future<ReportDoc> inspectionReport(int inspectionId);

  /// The small label/PDF sticker for one sample.
  Future<ReportDoc> sampleLabelPdf(int inspectionId);

  /// The device sticker for one lab equipment: name, manufacturer, serial,
  /// calibrations + the QR that opens the device file on a scan.
  Future<ReportDoc> equipmentLabelPdf(int equipmentId);

  /// Labels for a selected set of lab equipment, packed N-up on A4 pages
  /// (same sheet the sample batch labels use).
  Future<ReportDoc> equipmentLabelsPdf(List<int> equipmentIds);

  /// Labels for a filtered set of inspections, in one document.
  Future<ReportDoc> batchLabelsPdf(List<int> inspectionIds);

  /// Follow-up report over a user-selected set of inspection ids.
  Future<ReportDoc> followUpReport(
    List<int> inspectionIds, {
    String? dateStr,
    String shiftLabel,
  });

  // ── Periodic documents ─────────────────────────────────────────

  Future<ReportDoc> dailyReport(String dateStr);

  Future<ReportDoc> monthlyReport({required int month, required int year});

  Future<ReportDoc> yearlyReport({required int year});

  /// Daily/monthly/yearly lab-test report. The extra filters are optional
  /// narrowing; the type alone decides the period.
  Future<ReportDoc> labReport({
    required String type,
    String? dateStr,
    int? month,
    int? year,
    int? analysisId,
    String? sourceType,
    int? sourceRefId,
  });

  /// Generic register table (e.g. the test log) as a PDF: [headers] + [rows]
  /// of already-formatted strings. Rendered through the shared HTML→PDF
  /// pipeline when a headless browser exists, else the native dart-pdf table.
  Future<ReportDoc> tableReport({
    required String filename,
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
  });

  // ── Disk output ────────────────────────────────────────────────

  /// Writes [doc] into the export directory tree and returns the written file.
  Future<File> saveReport(
    ReportDoc doc, {
    DateTime? date,
    bool asLabel,
  });
}

/// A rendered report, ready to be written to disk.
///
/// Deliberately inert: the filename and the bytes, nothing about the template
/// engine or the PDF library that produced them.
class ReportDoc {
  const ReportDoc({
    required this.filename,
    required this.bytes,
    this.title,
  });

  /// Suggested file name (sanitized, already ends with `.pdf`).
  final String filename;

  /// Ready-to-write PDF bytes.
  final Uint8List bytes;

  /// Human-readable title for UI dialogs/headers.
  final String? title;
}
