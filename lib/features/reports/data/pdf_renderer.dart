import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/constants/app_strings.dart';
import 'qr_render.dart';

/// Renders the report contexts (built in report_builder.dart) to PDF bytes
/// using the `pdf` package. The package performs Arabic shaping + bidi so the
/// bilingual content renders correctly.

enum _Kind { daily, monthly, yearly, followUp }

class PdfRenderer {
  static pw.Font? _baseFont;
  static pw.Font? _boldFont;
  static ByteData? _fontBytes;

  /// Active language for the current render. Statics are per-isolate, so this
  /// is set from [AppText.arabic] on the calling isolate (or from the value
  /// captured before [renderInspectionInIsolate] spawns its worker).
  static bool _ar = true;

  /// Pick [ar] in Arabic mode, [en] in English mode.
  static String _t(String ar, String en) => _ar ? ar : en;

  static Future<pw.Font> _font() async {
    if (_baseFont == null) {
      final data = await _fontBytesCached();
      _baseFont = pw.Font.ttf(data);
      _boldFont = pw.Font.ttf(data);
    }
    return _baseFont!;
  }

  /// Perf: cache the raw TTF bytes once so exports don't re-hit rootBundle.
  static Future<ByteData> _fontBytesCached() async {
    final cached = _fontBytes;
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/fonts/Cairo-Variable.ttf');
    _fontBytes = data;
    return data;
  }

  /// Perf: warm the font cache off the critical path (call post-bootstrap /
  /// post-first-frame). Subsequent exports skip the first-hit jank.
  static Future<void> precache() async {
    try {
      await _font();
    } on Object catch (_) {
      // Cosmetic only — exports lazily load on demand.
    }
  }

  /// Perf opt-in: build the inspection PDF off the UI thread.
  /// Existing [renderInspection] stays synchronous-compatible; callers with
  /// large Arabic content should prefer this to avoid dropped frames.
  /// Font bytes are loaded on the main isolate (rootBundle) then passed in
  /// because statics + asset bundle don't cross [Isolate.run] boundaries.
  static Future<Uint8List> renderInspectionInIsolate(
    Map<String, dynamic> ctx,
  ) async {
    final fontBytes = await _fontBytesCached();
    final fontCopy = Uint8List.fromList(
      fontBytes.buffer.asUint8List(
        fontBytes.offsetInBytes,
        fontBytes.lengthInBytes,
      ),
    );
    final arabic = AppText.arabic;
    return Isolate.run(() {
      _ar = arabic;
      final data = ByteData.sublistView(fontCopy);
      _baseFont = pw.Font.ttf(data);
      _boldFont = pw.Font.ttf(data);
      final doc = pw.Document(
        theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
      );
      doc.addPage(
        pw.Page(
          pageFormat: _a4(),
          build: (c) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _inspectionHeader(ctx),
              ..._inspectionInfoBlocks(ctx),
              ..._inspectionResultTables(ctx),
              ..._inspectionNotes(ctx),
              ..._inspectionTimeline(ctx),
              pw.Spacer(),
              _qrFooter(ctx, marginTop: 8),
            ],
          ),
        ),
      );
      return doc.save();
    });
  }

  static pw.Font _bold() => _boldFont ?? _baseFont!;

  /// Worker-isolate scaffolding shared by all label renders.
  ///
  /// Label generation (up to 100 × QR encode → per-module paint → PNG encode
  /// → base64, plus Arabic shaping + layout) is seconds of main-thread work,
  /// so it runs in the same pattern as [renderInspectionInIsolate]: font bytes
  /// are loaded on the main isolate (rootBundle is not portable into the
  /// worker), the language static is captured before spawn, and the pre-built
  /// `_baseFont`/`_boldFont` warm-set inside the worker keeps `_font()` from
  /// ever touching the asset bundle there.
  static Future<Uint8List> _labelRenderInIsolate(
    Map<String, dynamic> ctx,
    Future<Uint8List> Function(Map<String, dynamic> ctx) render,
  ) async {
    final fontBytes = await _fontBytesCached();
    final fontCopy = Uint8List.fromList(
      fontBytes.buffer.asUint8List(
        fontBytes.offsetInBytes,
        fontBytes.lengthInBytes,
      ),
    );
    final arabic = AppText.arabic;
    return Isolate.run(() async {
      _ar = arabic;
      final data = ByteData.sublistView(fontCopy);
      _baseFont = pw.Font.ttf(data);
      _boldFont = pw.Font.ttf(data);
      return render(ctx);
    });
  }

  /// Off-thread variant of [renderLabel] (10×5cm sample label).
  static Future<Uint8List> renderLabelInIsolate(Map<String, dynamic> ctx) =>
      _labelRenderInIsolate(ctx, renderLabel);

  /// Off-thread variant of [renderEquipmentLabel] (device sticker).
  static Future<Uint8List> renderEquipmentLabelInIsolate(
    Map<String, dynamic> ctx,
  ) => _labelRenderInIsolate(ctx, renderEquipmentLabel);

  /// Off-thread variant of [renderBatchEquipmentLabels] (device sheet).
  static Future<Uint8List> renderBatchEquipmentLabelsInIsolate(
    Map<String, dynamic> ctx,
  ) => _labelRenderInIsolate(ctx, renderBatchEquipmentLabels);

  /// Off-thread variant of [renderBatchLabels] (up to 100 labels per A4 set).
  ///
  /// This is the hottest export in the app: every label re-encodes its QR as
  /// PNG, and a 100-label batch once froze the UI for the whole run.
  static Future<Uint8List> renderBatchLabelsInIsolate(
    Map<String, dynamic> ctx,
  ) => _labelRenderInIsolate(ctx, renderBatchLabels);


  static const _ink = PdfColor.fromInt(0xFF1F1F1F);
  static const _muted = PdfColor.fromInt(0xFF555555);
  static const _accent = PdfColor.fromInt(0xFF1B5E20);
  static const _light = PdfColor.fromInt(0xFFF0F7F0);
  static const _red = PdfColor.fromInt(0xFFB71C1C);
  static const _redBg = PdfColor.fromInt(0xFFFDECEA);
  static const _amber = PdfColor.fromInt(0xFF8A5A00);
  static const _amberBg = PdfColor.fromInt(0xFFFFF3CD);

  /// Global QA form number for the `form_no` context key, or '' when unset.
  static String _formNo(Map<String, dynamic> ctx) =>
      '${ctx['form_no'] ?? ''}'.trim();

  /// `نموذج رقم / Form No:` line, or null when no form number is configured.
  static pw.Widget? _formNoLine(Map<String, dynamic> ctx, {double size = 7}) {
    final formNo = _formNo(ctx);
    if (formNo.isEmpty) return null;
    return _txt(
      _t('نموذج رقم / Form No: $formNo', 'Form No: $formNo'),
      size: size,
      color: _muted,
    );
  }

  static bool _hasArabic(String? s) {    if (s == null) return false;
    for (final codeUnit in s.codeUnits) {
      if (codeUnit >= 0x0600 && codeUnit <= 0x06FF) return true;
    }
    return false;
  }

  static pw.TextDirection _dir(String? s) =>
      _hasArabic(s) ? pw.TextDirection.rtl : pw.TextDirection.ltr;

  static pw.TextAlign _align(String? s) =>
      _hasArabic(s) ? pw.TextAlign.right : pw.TextAlign.left;

  static pw.Text _txt(
    String? text, {
    double size = 9,
    bool bold = false,
    PdfColor? color,
    pw.TextAlign? align,
  }) {
    return pw.Text(
      text ?? '',
      textDirection: _dir(text),
      textAlign: align ?? _align(text),
      style: pw.TextStyle(
        font: bold ? _bold() : _baseFont,
        fontSize: size,
        color: color ?? _ink,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    );
  }

  static pw.SizedBox _spacer([double h = 6]) => pw.SizedBox(height: h);

  static pw.Container _sectionTitle(String text) => pw.Container(
    padding: const pw.EdgeInsets.only(left: 4, right: 4, top: 3, bottom: 3),
    color: _light,
    child: pw.Align(
      alignment: pw.Alignment.centerLeft,
      child: _txt(text, size: 10.5, bold: true, color: _accent),
    ),
  );

  static pw.MemoryImage? _logo(Map<String, dynamic> ctx) {
    final raw = '${ctx['report_logo_data_uri'] ?? ''}'.trim();
    if (raw.isEmpty) return null;
    try {
      final comma = raw.contains(',') ? raw.indexOf(',') + 1 : 0;
      final b64 = raw.substring(comma);
      final bytes = base64Decode(b64);
      if (bytes.isEmpty) return null;
      return pw.MemoryImage(bytes);
    } catch (_) {
      return null;
    }
  }

  static PdfPageFormat _a4() => PdfPageFormat.a4.copyWith(
    marginTop: 9 * PdfPageFormat.mm,
    marginBottom: 9 * PdfPageFormat.mm,
    marginLeft: 8 * PdfPageFormat.mm,
    marginRight: 8 * PdfPageFormat.mm,
  );

  // ── Inspection report ────────────────────────────────────────────────

  static Future<Uint8List> renderInspection(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    doc.addPage(
      pw.Page(
        pageFormat: _a4(),
        build: (c) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _inspectionHeader(ctx),
            ..._inspectionInfoBlocks(ctx),
            ..._inspectionResultTables(ctx),
            ..._inspectionNotes(ctx),
            ..._inspectionTimeline(ctx),
            pw.Spacer(),
            _qrFooter(ctx, marginTop: 8),
          ],
        ),
      ),
    );
    return doc.save();
  }

  static pw.Widget _inspectionHeader(Map<String, dynamic> ctx) {
    final logo = _logo(ctx);
    final dept = ctx['department_label'] ?? 'Quality Assurance Department';
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Expanded(
          flex: 3,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _txt(dept, size: 14, bold: true, color: _ink),
              _spacer(2),
              _txt(_t('تقرير فحص / Inspection Report', 'Inspection Report'), size: 11, color: _muted),
              _spacer(2),
              _txt('${ctx['sample_number'] ?? ''}', size: 9, color: _muted),
              if (_formNo(ctx).isNotEmpty) ...[
                _spacer(2),
                _formNoLine(ctx, size: 8)!,
              ],
            ],
          ),
        ),
        if (logo != null)
          pw.SizedBox(width: 64, height: 48, child: pw.Image(logo)),
      ],
    );
  }

  static List<pw.Widget> _inspectionInfoBlocks(Map<String, dynamic> ctx) {
    final isProduct = ctx['is_product'] == true;
    final info = _simpleTable(
      [_t('الخاصية / Field', 'Field'), _t('القيمة / Value', 'Value')],
      [
        [
          _txt(_t('رقم العينة / Sample No.', 'Sample No.'), size: 9, bold: true),
          _txt('${ctx['sample_number'] ?? '-'}', size: 9),
        ],
        [
          _txt(_t('التاريخ / Date', 'Date'), size: 9, bold: true),
          _txt('${ctx['date'] ?? '-'}', size: 9),
        ],
        [
          _txt(_t('تاريخ الانتهاء / Expiry', 'Expiry'), size: 9, bold: true),
          _txt('${ctx['expiry_date'] ?? '-'}', size: 9),
        ],
        [
          _txt(
            isProduct ? _t('اسم المنتج / Product', 'Product') : _t('اسم الخامة / Material', 'Material'),
            size: 9,
            bold: true,
          ),
          _txt('${ctx['material_name'] ?? '-'}', size: 9),
        ],
        [
          _txt(_t('الكمية / Quantity', 'Quantity'), size: 9, bold: true),
          _txt('${ctx['quantity'] ?? '-'}', size: 9),
        ],
        if (isProduct) ...[
          [
            _txt(_t('رقم الفورمولا / Formula No.', 'Formula No.'), size: 9, bold: true),
            _txt('${ctx['formula_number'] ?? '-'}', size: 9),
          ],
          [
            _txt(_t('رقم التشغيلة / Batch No.', 'Batch No.'), size: 9, bold: true),
            _txt('${ctx['batch_number'] ?? '-'}', size: 9),
          ],
        ] else ...[
          [
            _txt(_t('المورد / Supplier', 'Supplier'), size: 9, bold: true),
            _txt('${ctx['supplier'] ?? '-'}', size: 9),
          ],
          [
            _txt(_t('رقم الشاحنة / Truck No.', 'Truck No.'), size: 9, bold: true),
            _txt('${ctx['truck_number'] ?? '-'}', size: 9),
          ],
        ],
        [
          _txt(_t('أخذ العينة / Sample taken by', 'Sample taken by'), size: 9, bold: true),
          _txt('${ctx['sample_taken_by'] ?? '-'}', size: 9),
        ],
        [
          _txt(_t('الأخصائي / Specialist', 'Specialist'), size: 9, bold: true),
          _txt('${ctx['specialist_name'] ?? '-'}', size: 9),
        ],
        [
          _txt(_t('أنشئ بواسطة / Created by', 'Created by'), size: 9, bold: true),
          _txt('${ctx['created_by_name'] ?? '-'}', size: 9),
        ],
      ],
      const {0: pw.FlexColumnWidth(2.0), 1: pw.FlexColumnWidth(3.0)},
    );
    final decision = '${ctx['decision_label'] ?? '-'}';
    final status = '${ctx['decision_status'] ?? ''}';
    final isRejected =
        status == 'FULL_REJECTION' || status == 'PARTIAL_REJECTION';
    final isConditional =
        status == 'CONDITIONAL_APPROVAL' || status == 'CONDITIONAL';
    final verdictBg = isRejected
        ? _redBg
        : isConditional
        ? _amberBg
        : _light;
    final verdictColor = isRejected
        ? _red
        : isConditional
        ? _amber
        : _accent;
    final verdict = pw.Container(
      margin: const pw.EdgeInsets.symmetric(vertical: 8),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: verdictBg,
        border: pw.Border.all(color: verdictColor, width: 1),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            children: [
              _txt(_t('النتيجة / Decision: ', 'Decision: '), size: 10, bold: true),
              _txt(decision, size: 10.5, bold: true, color: verdictColor),
              _spacer(1),
              _txt(
                _t('الإصدار ${ctx['decision_version'] ?? 1}', 'Version ${ctx['decision_version'] ?? 1}'),
                size: 9,
                color: _muted,
              ),
            ],
          ),
          if (ctx['decision_reason'] is String &&
              '${ctx['decision_reason']}' != '-' &&
              '${ctx['decision_reason']}'.isNotEmpty &&
              ctx['decision_status'] != 'APPROVED') ...[
            _spacer(4),
            _txt(_t('السبب / Reason: ${ctx['decision_reason']}', 'Reason: ${ctx['decision_reason']}'), size: 9.5),
          ],
        ],
      ),
    );
    // Products carry no header quality decision: the report is the batch
    // identity + its per-sample tables (+ linked lab tests). Raw keeps the
    // verdict box.
    if (isProduct) return [info];
    return [info, verdict];
  }

  static List<pw.Widget> _inspectionResultTables(Map<String, dynamic> ctx) {
    final widgets = <pw.Widget>[];
    final isProduct = ctx['is_product'] == true;
    final sampleNames = (ctx['sample_names'] as List?) ?? const [];
    final physical = (ctx['physical_data'] as List?) ?? const [];
    final chemical = (ctx['chemical_data'] as List?) ?? const [];

    // Product reports carry their results inside the operational-samples
    // (عينات التشغيلية) merged table below; the header-level references would
    // only render empty result columns, so they are skipped entirely.
    if (physical.isNotEmpty && !isProduct) {
      widgets.add(_spacer(10));
      widgets.add(_sectionTitle(_t('الفحوصات الفيزيائية / Physical Properties', 'Physical Properties')));
      widgets.add(_spacer(4));
      final cols = <int, pw.FlexColumnWidth>{
        0: const pw.FlexColumnWidth(2.2),
        1: const pw.FlexColumnWidth(1.6),
      };
      final header = <String>[_t('الخاصية / Property', 'Property'), _t('المتطلب / Requirement', 'Requirement')];
      for (final name in sampleNames) {
        cols[header.length] = const pw.FlexColumnWidth(1.6);
        header.add('${name ?? ''}');
      }
      final rows = <List<pw.Widget>>[];
      for (final row in physical) {
        final isOuts = (row['is_outs'] as List?) ?? [];
        final cells = <pw.Widget>[
          _txt('${row['name']}', size: 8.5),
          _txt('${row['req']}', size: 8.5),
        ];
        final actuals = (row['actuals'] as List?) ?? [];
        for (var i = 0; i < actuals.length; i++) {
          final out = i < isOuts.length && isOuts[i] == true;
          cells.add(
            pw.Container(
              color: out ? _redBg : null,
              child: _txt(
                '${actuals[i]}',
                size: 8.5,
                color: out ? _red : _ink,
                bold: out,
              ),
            ),
          );
        }
        rows.add(cells);
      }
      widgets.add(
        _simpleTable(header, rows, cols, colorHeader: true, zebra: true),
      );
    }

    if (chemical.isNotEmpty && !isProduct) {
      widgets.add(_spacer(10));
      widgets.add(_sectionTitle(_t('النتائج الكيميائية / Chemical Results', 'Chemical Results')));
      widgets.add(_spacer(4));
      final cols = <int, pw.FlexColumnWidth>{
        0: const pw.FlexColumnWidth(2.0),
        1: const pw.FlexColumnWidth(1.1),
        2: const pw.FlexColumnWidth(1.1),
        3: const pw.FlexColumnWidth(0.7),
      };
      final header = <String>[
        _t('الخاصية / Property', 'Property'),
        _t('الحد الأدنى / Min', 'Min'),
        _t('الحد الأقصى / Max', 'Max'),
        _t('الوحدة / Unit', 'Unit'),
      ];
      for (final name in sampleNames) {
        cols[header.length] = const pw.FlexColumnWidth(1.4);
        header.add('${name ?? ''}');
      }
      final rows = <List<pw.Widget>>[];
      for (final row in chemical) {
        final isOuts = (row['is_outs'] as List?) ?? [];
        final cells = <pw.Widget>[
          _txt('${row['name']}', size: 8.5),
          _txt('${row['min_display']}', size: 8.5),
          _txt('${row['max_display']}', size: 8.5),
          _txt('${row['unit']}', size: 8.5),
        ];
        final actuals = (row['actuals'] as List?) ?? [];
        for (var i = 0; i < actuals.length; i++) {
          final out = i < isOuts.length && isOuts[i] == true;
          cells.add(
            pw.Container(
              color: out ? _redBg : null,
              child: _txt(
                '${actuals[i]}',
                size: 8.5,
                color: out ? _red : _ink,
                bold: out,
              ),
            ),
          );
        }
        rows.add(cells);
      }
      widgets.add(
        _simpleTable(header, rows, cols, colorHeader: true, zebra: true),
      );
    }

    // Product batch samples (محضر التشغيلية): ONE merged table for all
    // operational samples — every physical (فحص ظاهري) row first, each
    // sample showing its physical cell right beside its chemical cell.
    if (ctx['show_batch_samples'] == true) {
      final mergedSamples = (ctx['batch_merged_samples'] as List?) ?? const [];
      final mergedRows = (ctx['batch_merged_rows'] as List?) ?? const [];
      if (mergedSamples.isNotEmpty && mergedRows.isNotEmpty) {
        widgets.add(_spacer(10));
        widgets.add(
          _sectionTitle(
            _t('عينات التشغيلية / Operational Samples', 'Operational Samples'),
          ),
        );
        widgets.add(_spacer(4));
        final sampleCount = mergedSamples.length;
        final cols = <int, pw.FlexColumnWidth>{
          0: const pw.FlexColumnWidth(2.0),
        };
        final header = <String>[
          _t('البيان / Parameter', 'Parameter'),
        ];
        // Two header rows are not supported by `_simpleTable`'s single-row
        // header, so the sample label/meta takes the first result column and
        // the visual/chemical split is signalled via the sub-header row below.
        for (var i = 0; i < sampleCount; i++) {
          final h = Map<String, dynamic>.from(mergedSamples[i] as Map);
          cols[1 + i * 2] = const pw.FlexColumnWidth(1.1);
          cols[2 + i * 2] = const pw.FlexColumnWidth(1.1);
          header.addAll([
            '${h['label'] ?? ''}\n${h['meta'] ?? ''}',
            '',
          ]);
        }
        final rows = <List<pw.Widget>>[];
        final subHeader = <pw.Widget>[_txt('', size: 8.2)];
        for (var i = 0; i < sampleCount; i++) {
          subHeader.addAll([
            _txt(_t('فحص ظاهري', 'Visual'), size: 8, bold: true),
            _txt(_t('فحص كيميائي', 'Chemical'), size: 8, bold: true),
          ]);
        }
        rows.add(subHeader);
        for (final rraw in mergedRows) {
          final row = Map<String, dynamic>.from(rraw as Map);
          final cells = <pw.Widget>[
            _txt('${row['name'] ?? ''}', size: 8.5, bold: true),
          ];
          for (final craw in (row['cells'] as List?) ?? const []) {
            final c = Map<String, dynamic>.from(craw as Map);
            final lines = <pw.Widget>[];
            if ('${c['p'] ?? ''}'.trim().isNotEmpty) {
              lines.add(_txt('${c['p']}', size: 8.5));
            }
            if ('${c['c'] ?? ''}'.trim().isNotEmpty) {
              lines.add(_txt('${c['c']}', size: 8.5));
            }
            cells.add(
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: lines.isEmpty ? [_txt('')] : lines,
              ),
            );
          }
          rows.add(cells);
        }
        widgets.add(
          _simpleTable(header, rows, cols, colorHeader: true, zebra: true),
        );
      }
    }
    return widgets;
  }

  static final _zebraA = PdfColor.fromInt(0xFFF7FAF7);
  static final _zebraB = PdfColor.fromInt(0xFFFFFFFF);

  static pw.Widget _simpleTable(
    List<String> header,
    List<List<pw.Widget>> rows,
    Map<int, pw.FlexColumnWidth> cols, {
    bool colorHeader = true,
    bool zebra = false,
  }) {
    final tr = <pw.TableRow>[];
    tr.add(
      pw.TableRow(
        decoration: pw.BoxDecoration(color: colorHeader ? _light : null),
        children: [
          for (final h in header)
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 3,
              ),
              child: _txt(h, size: 8.2, bold: true),
            ),
        ],
      ),
    );
    for (var ri = 0; ri < rows.length; ri++) {
      final row = rows[ri];
      tr.add(
        pw.TableRow(
          decoration: zebra
              ? pw.BoxDecoration(color: ri.isEven ? _zebraA : _zebraB)
              : null,
          children: [
            for (var ci = 0; ci < header.length; ci++)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 3,
                ),
                child: ci < row.length ? row[ci] : _txt(''),
              ),
          ],
        ),
      );
    }
    return pw.Table(
      columnWidths: cols,
      defaultColumnWidth: const pw.IntrinsicColumnWidth(),
      border: pw.TableBorder.all(
        color: PdfColor.fromInt(0xFFCCCCCC),
        width: 0.4,
      ),
      children: tr,
    );
  }

  static List<pw.Widget> _inspectionNotes(Map<String, dynamic> ctx) {
    final widgets = <pw.Widget>[];
    if (ctx['show_follow_up_note'] == true) {
      final note = '${ctx['follow_up_note'] ?? '-'}';
      if (note.isNotEmpty && note != '-') {
        widgets.add(_spacer(8));
        widgets.add(
          pw.Container(
            padding: const pw.EdgeInsets.all(6),
            decoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFE8F5E9),
              border: pw.Border(left: pw.BorderSide(color: _accent, width: 3)),
            ),
            child: _txt(
              _t('ملاحظة المتابعة / Follow-up note: $note', 'Follow-up note: $note'),
              size: 9,
              color: _accent,
            ),
          ),
        );
      }
    }
    if (ctx['show_rejected_quantity'] == true) {
      widgets.add(_spacer(6));
      widgets.add(
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: const pw.BoxDecoration(
            color: _redBg,
            border: pw.Border(left: pw.BorderSide(color: _red, width: 3)),
          ),
          child: _txt(
            _t('الكمية المرفوضة / Rejected quantity: ${ctx['rejected_quantity']}', 'Rejected quantity: ${ctx['rejected_quantity']}'),
            size: 9,
            color: _red,
          ),
        ),
      );
    }
    return widgets;
  }

  static List<pw.Widget> _inspectionTimeline(Map<String, dynamic> ctx) {
    if (ctx['show_status_timeline'] != true) return const [];
    final timeline = (ctx['status_timeline'] as List?) ?? const [];
    if (timeline.length <= 1) return const [];
    final rows = <List<pw.Widget>>[];
    for (final row in timeline) {
      rows.add([
        _txt('${row['version'] ?? ''}', size: 8.5),
        _txt(
          '${row['label_ar'] ?? ''} / ${row['label_en'] ?? ''}',
          size: 8.5,
          bold: true,
        ),
        _txt('${row['reason'] ?? ''}', size: 8.5),
        _txt('${row['changed_at'] ?? ''}', size: 8.5),
      ]);
    }
    return [
      _spacer(10),
      _sectionTitle(_t('تاريخ القرارات / Decision History', 'Decision History')),
      _spacer(4),
      _simpleTable(
        [
          _t('الإصدار / Ver', 'Ver'),
          _t('الحالة / Status', 'Status'),
          _t('السبب / Reason', 'Reason'),
          _t('التاريخ / Date', 'Date'),
        ],
        rows,
        const {
          0: pw.FlexColumnWidth(0.7),
          1: pw.FlexColumnWidth(1.6),
          2: pw.FlexColumnWidth(2.4),
          3: pw.FlexColumnWidth(1.4),
        },
        zebra: true,
      ),
    ];
  }

  static pw.Widget _qrFooter(Map<String, dynamic> ctx, {double marginTop = 0}) {
    final payload = '${ctx['qr_payload_text'] ?? ''}';
    final qrBytes = payload.isEmpty ? null : qrPngBytes(payload);
    final pwImage = qrBytes == null
        ? null
        : pw.Image(pw.MemoryImage(qrBytes), width: 92, height: 92);
    return pw.Container(
      margin: pw.EdgeInsets.only(top: marginTop),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: PdfColor.fromInt(0xFFCCCCCC)),
        ),
      ),
      padding: const pw.EdgeInsets.only(top: 6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          if (pwImage != null)
            pw.Center(child: pwImage),
          if (pwImage != null) _spacer(4),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _txt(
                      _t('تاريخ الإنشاء / Generated: ${ctx['generated_at']}', 'Generated: ${ctx['generated_at']}'),
                      size: 8,
                      color: _muted,
                    ),
                    _spacer(3),
                    _txt(
                      _t('توقيع الأخصائي / Specialist signature: ______________', 'Specialist signature: ______________'),
                      size: 8.5,
                    ),
                    _spacer(3),
                    _txt(
                      _t('توقيع مدير الجودة / QA manager signature: ____________', 'QA manager signature: ____________'),
                      size: 8.5,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Label (10x5cm) ────────────────────────────────────────────────────

  static Future<Uint8List> renderLabel(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    final insp = (ctx['inspection'] as Map?) ?? const {};
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          10 * PdfPageFormat.cm,
          5 * PdfPageFormat.cm,
          marginAll: 2 * PdfPageFormat.mm,
        ),
        build: (c) {
          final payload = '${ctx['qr_payload_text'] ?? ''}';
          final img = payload.isEmpty
              ? null
              : pw.Image(
                  pw.MemoryImage(qrPngBytes(payload)),
                  width: 30,
                  height: 30,
                );
          return pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _txt(
                      '${insp['material_name'] ?? ''}',
                      size: 8.5,
                      bold: true,
                    ),
                    _spacer(1),
                    _txt(
                      '${ctx['department_label']}',
                      size: 6.5,
                      color: _muted,
                    ),
                    if (_formNo(ctx).isNotEmpty) ...[
                      _spacer(1),
                      _formNoLine(ctx, size: 6.5)!,
                    ],
                    _spacer(2),
                    pw.Wrap(
                      spacing: 6,
                      runSpacing: 1,
                      children: [
                        _txt(_t('رقم: ${insp['entry_code'] ?? ''}', 'No: ${insp['entry_code'] ?? ''}'), size: 7),
                        _txt('${insp['inspection_date'] ?? ''}', size: 7),
                      ],
                    ),
                    _spacer(1),
                    pw.Wrap(
                      spacing: 6,
                      runSpacing: 1,
                      children: [
                        _txt(_t('كمية: ${ctx['quantity_display']}', 'Qty: ${ctx['quantity_display']}'), size: 7),
                        if ('${insp['inspection_kind'] ?? 'raw'}' ==
                            'product') ...[
                          _txt(
                            _t('فورمولا: ${insp['formula_number'] ?? ''}', 'Formula: ${insp['formula_number'] ?? ''}'),
                            size: 7,
                          ),
                          _txt(
                            _t('تشغيلة: ${insp['batch_number'] ?? ''}', 'Batch: ${insp['batch_number'] ?? ''}'),
                            size: 7,
                          ),
                        ] else ...[
                          _txt(_t('مورد: ${insp['supplier'] ?? ''}', 'Supplier: ${insp['supplier'] ?? ''}'), size: 7),
                          _txt(_t('شاحنة: ${insp['truck_number'] ?? ''}', 'Truck: ${insp['truck_number'] ?? ''}'), size: 7),
                        ],
                      ],
                    ),
                    _spacer(1),
                    pw.Wrap(
                      spacing: 6,
                      runSpacing: 1,
                      children: [
                        _txt(_t('أخذ: ${insp['sample_taken_by'] ?? ''}', 'Taken: ${insp['sample_taken_by'] ?? ''}'), size: 7),
                        _txt(
                          _t('أخصائي: ${insp['specialist_name'] ?? ''}', 'Specialist: ${insp['specialist_name'] ?? ''}'),
                          size: 7,
                        ),
                      ],
                    ),
                    _spacer(1),
                    _txt('${ctx['generated_at']}', size: 6, color: _muted),
                  ],
                ),
              ),
              ?img,
            ],
          );
        },
      ),
    );
    return doc.save();
  }

  // ── Equipment label (10x5cm) ─────────────────────────────────────────

  /// Device sticker twin of [renderLabel]: name, manufacturer, serial,
  /// last/next calibration + the device-code QR that opens the device file.
  static Future<Uint8List> renderEquipmentLabel(
    Map<String, dynamic> ctx,
  ) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          10 * PdfPageFormat.cm,
          5 * PdfPageFormat.cm,
          marginAll: 2 * PdfPageFormat.mm,
        ),
        build: (c) => _equipmentStickerContent(ctx),
      ),
    );
    return doc.save();
  }

  /// The inline content of one device sticker — shared by the single label
  /// page and the batch sheet cells.
  static pw.Widget _equipmentStickerContent(Map<String, dynamic> ctx) {
    final eq = (ctx['equipment'] as Map?) ?? const {};
    final next = '${eq['next_calibration_date'] ?? ''}'.trim();
    final overdue =
        next.isNotEmpty &&
        next.substring(0, 10).compareTo(
              DateTime.now().toString().substring(0, 10),
            ) <
            0;
    final payload = '${ctx['qr_payload_text'] ?? ''}';
    final img = payload.isEmpty
        ? null
        : pw.Image(
            pw.MemoryImage(qrPngBytes(payload)),
            width: 30,
            height: 30,
          );
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _txt(
                '${eq['name'] ?? ''}',
                size: 8.5,
                bold: true,
              ),
              _spacer(1),
              _txt(
                '${ctx['department_label']}',
                size: 6.5,
                color: _muted,
              ),
              _spacer(2),
              pw.Wrap(
                spacing: 6,
                runSpacing: 1,
                children: [
                  _txt(_t('كود: ${eq['code'] ?? ''}', 'Code: ${eq['code'] ?? ''}'), size: 7),
                  if ('${eq['manufacturer'] ?? ''}'.trim().isNotEmpty)
                    _txt(_t('الشركة: ${eq['manufacturer']}', 'Manufacturer: ${eq['manufacturer']}'), size: 7),
                ],
              ),
              _spacer(1),
              pw.Wrap(
                spacing: 6,
                runSpacing: 1,
                children: [
                  if ('${eq['serial_number'] ?? ''}'.trim().isNotEmpty)
                    _txt(_t('سيريال: ${eq['serial_number']}', 'Serial: ${eq['serial_number']}'), size: 7),
                  if ('${eq['last_calibration_date'] ?? ''}'
                      .trim()
                      .isNotEmpty)
                    _txt(
                      _t('آخر معايرة: ${eq['last_calibration_date']}', 'Last cal.: ${eq['last_calibration_date']}'),
                      size: 7,
                    ),
                ],
              ),
              _spacer(1),
              pw.Wrap(
                spacing: 6,
                runSpacing: 1,
                children: [
                  if (next.isNotEmpty)
                    _txt(
                      overdue
                          ? _t('المعايرة القادمة: $next (متأخرة!)', 'Next cal.: $next (overdue!)')
                          : _t('المعايرة القادمة: $next', 'Next cal.: $next'),
                      size: 7,
                      color: overdue
                          ? const PdfColor.fromInt(0xFFB00020)
                          : _muted,
                    ),
                ],
              ),
              _spacer(1),
              pw.Wrap(
                spacing: 6,
                runSpacing: 1,
                children: [
                  if ('${ctx['form_no'] ?? ''}'.trim().isNotEmpty)
                    _txt(
                      _t('نموذج رقم / Form No: ${ctx['form_no']}', 'Form No: ${ctx['form_no']}'),
                      size: 7,
                    ),
                ],
              ),
              _spacer(1),
              _txt('${ctx['generated_at']}', size: 6, color: _muted),
            ],
          ),
        ),
        ?img,
      ],
    );
  }

  /// Selected equipment packed like [renderBatchLabels]: the same A4 sheet
  /// with 10×5cm stickers in a 2×3 grid per page (native fallback for
  /// machines without the headless HTML→PDF converter).
  static Future<Uint8List> renderBatchEquipmentLabels(
    Map<String, dynamic> ctx,
  ) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    final labels = (ctx['labels'] as List?) ?? const [];
    final pages = <pw.Page>[];
    for (var i = 0; i < labels.length; i += 6) {
      final slice = labels.sublist(
        i,
        i + 6 > labels.length ? labels.length : i + 6,
      );
      final cells = <pw.Widget>[];
      for (final raw in slice) {
        final label = Map<String, dynamic>.from(raw as Map);
        label['qr_image_data_uri'] = '';
        final eq = Map<String, dynamic>.from(label);
        cells.add(
          pw.Container(
            decoration: pw.BoxDecoration(
              border: pw.Border.all(
                color: PdfColor.fromInt(0xFFCCCCCC),
                width: 0.6,
              ),
            ),
            padding: const pw.EdgeInsets.all(6),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: _equipmentStickerContent({
                    'equipment': eq,
                    'qr_payload_text': label['qr_payload_text'],
                    'department_label': ctx['department_label'],
                    'form_no': ctx['form_no'],
                    'generated_at': ctx['generated_at'],
                  }),
                ),
              ],
            ),
          ),
        );
      }
      pages.add(
        pw.Page(
          pageFormat: _a4(),
          margin: const pw.EdgeInsets.all(5),
          build: (c) => pw.GridView(
            crossAxisCount: 2,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 2.0,
            children: cells,
          ),
        ),
      );
    }
    if (pages.isEmpty) {
      pages.add(
        pw.Page(pageFormat: _a4(), build: (_) => _txt(_t('لا توجد QR', 'No QR'), size: 10)),
      );
    }
    for (final p in pages) {
      doc.addPage(p);
    }
    return doc.save();
  }

  // ── Batch labels ──────────────────────────────────────────────────────

  static Future<Uint8List> renderBatchLabels(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    final labels = (ctx['labels'] as List?) ?? const [];
    final pages = <pw.Page>[];
    for (var i = 0; i < labels.length; i += 6) {
      final slice = labels.sublist(
        i,
        i + 6 > labels.length ? labels.length : i + 6,
      );
      final cells = <pw.Widget>[];
      for (final label in slice) {
        cells.add(
          pw.Container(
            decoration: pw.BoxDecoration(
              border: pw.Border.all(
                color: PdfColor.fromInt(0xFFCCCCCC),
                width: 0.6,
              ),
            ),
            padding: const pw.EdgeInsets.all(6),
            child: _batchLabelInner(label, _formNo(ctx)),
          ),
        );
      }
      pages.add(
        pw.Page(
          pageFormat: _a4(),
          margin: const pw.EdgeInsets.all(5),
          build: (c) => pw.GridView(
            crossAxisCount: 2,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1.9,
            children: cells,
          ),
        ),
      );
    }
    if (pages.isEmpty) {
      pages.add(
        pw.Page(pageFormat: _a4(), build: (_) => _txt(_t('لا توجد QR', 'No QR'), size: 10)),
      );
    }
    for (final p in pages) {
      doc.addPage(p);
    }
    return doc.save();
  }

  static pw.Widget _batchLabelInner(
    Map<String, dynamic> label, [
    String formNo = '',
  ]) {
    final payload = '${label['qr_payload_text'] ?? ''}';
    final img = payload.isEmpty
        ? null
        : pw.Image(pw.MemoryImage(qrPngBytes(payload)), width: 30, height: 30);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _txt('${label['material_name'] ?? ''}', size: 8.5, bold: true),
              if (formNo.trim().isNotEmpty) ...[
                _spacer(1),
                _txt(
                  _t('نموذج رقم / Form No: ${formNo.trim()}', 'Form No: ${formNo.trim()}'),
                  size: 6,
                  color: _muted,
                ),
              ],
              _spacer(1),
              _txt(
                _t('رقم: ${label['entry_code'] ?? ''} | ${label['inspection_date'] ?? ''}', 'No: ${label['entry_code'] ?? ''} | ${label['inspection_date'] ?? ''}'),
                size: 7,
              ),
              _spacer(1),
              _txt(
                label['is_product'] == true
                    ? _t('فورمولا: ${label['formula_number'] ?? ''} | تشغيلة: ${label['batch_number'] ?? ''} | كمية: ${label['quantity_display'] ?? ''}', 'Formula: ${label['formula_number'] ?? ''} | Batch: ${label['batch_number'] ?? ''} | Qty: ${label['quantity_display'] ?? ''}')
                    : _t('مورد: ${label['supplier'] ?? ''} | شاحنة: ${label['truck_number'] ?? ''} | كمية: ${label['quantity_display'] ?? ''}', 'Supplier: ${label['supplier'] ?? ''} | Truck: ${label['truck_number'] ?? ''} | Qty: ${label['quantity_display'] ?? ''}'),
                size: 7,
              ),
              _spacer(1),
              _txt(
                _t('أخذ: ${label['sample_taken_by'] ?? ''} | أخصائي: ${label['specialist_name'] ?? ''}', 'Taken: ${label['sample_taken_by'] ?? ''} | Specialist: ${label['specialist_name'] ?? ''}'),
                size: 7,
              ),
              _spacer(1),
              _txt(
                _t('الحالة: ${label['decision_status'] ?? ''} (v${label['decision_version'] ?? 1})', 'Status: ${label['decision_status'] ?? ''} (v${label['decision_version'] ?? 1})'),
                size: 7,
                bold: true,
              ),
            ],
          ),
        ),
        ?img,
      ],
    );
  }

  // ── Daily / Monthly / Yearly / Follow-up ──────────────────────────────

  static pw.Widget _statCard(
    String label,
    String value, {
    bool highlighted = false,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(
        color: highlighted ? _light : null,
        border: pw.Border.all(color: PdfColor.fromInt(0xFFDDDDDD), width: 0.5),
      ),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          _txt(label, size: 7, color: _muted),
          _spacer(2),
          _txt(
            value,
            size: 11,
            bold: true,
            color: highlighted ? _accent : _ink,
          ),
        ],
      ),
    );
  }

  static pw.Widget _periodHeader(
    String title,
    String subtitle,
    Map<String, dynamic> ctx,
  ) {
    final logo = _logo(ctx);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _txt(title, size: 14, bold: true, color: _accent),
              _spacer(2),
              _txt('${ctx['department_label']}', size: 9, color: _muted),
              _spacer(2),
              _txt(subtitle, size: 8.5, color: _muted),
              if (_formNo(ctx).isNotEmpty) ...[
                _spacer(2),
                _formNoLine(ctx, size: 8)!,
              ],
            ],
          ),
        ),
        if (logo != null)
          pw.SizedBox(height: 42, width: 56, child: pw.Image(logo)),
      ],
    );
  }

  static List<pw.Widget> _summaryStats(
    Map<String, dynamic> ctx, {
    bool monthly = false,
    bool yearly = false,
  }) {
    return [
      pw.Row(
        children: [
          pw.Expanded(
            child: _statCard(_t('إجمالي / Total', 'Total'), '${ctx['total'] ?? 0}'),
          ),
          pw.Expanded(
            child: _statCard(
              _t('قبول نهائي / Approved', 'Approved'),
              '${ctx['approved'] ?? 0}',
              highlighted: true,
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('قبول مع متابعة / Conditional', 'Conditional'),
              '${ctx['conditional'] ?? 0}',
            ),
          ),
          pw.Expanded(
            child: _statCard(_t('رفض جزئي / Partial', 'Partial'), '${ctx['partial'] ?? 0}'),
          ),
          pw.Expanded(
            child: _statCard(_t('رفض كلي / Rejected', 'Rejected'), '${ctx['rejected'] ?? 0}'),
          ),
        ],
      ),
      _spacer(4),
      pw.Row(
        children: [
          pw.Expanded(
            child: _statCard(
              _t('معدل القبول / Acceptance %', 'Acceptance %'),
              '${ctx['approval_rate'] ?? 0}%',
            ),
          ),
          if (monthly || yearly) ...[
            pw.Expanded(
              child: _statCard(
                _t('معدل الرفض / Rejection %', 'Rejection %'),
                '${ctx['rejection_rate'] ?? 0}%',
              ),
            ),
          ],
          pw.Expanded(
            child: _statCard(
              _t('الكمية الكلية / Total qty', 'Total qty'),
              '${ctx['total_quantity'] ?? '-'}',
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('الكمية المقبولة / Accepted qty', 'Accepted qty'),
              _acceptedQtyCtx(ctx),
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('الكمية المرفوضة / Rejected qty', 'Rejected qty'),
              '${ctx['total_rejected_quantity'] ?? ctx['total_rejected_qty'] ?? '-'}',
            ),
          ),
        ],
      ),
      _spacer(4),
      pw.Row(
        children: [
          pw.Expanded(
            child: _statCard(
              _t('الموردون المميزون / Suppliers', 'Suppliers'),
              '${ctx['unique_suppliers'] ?? 0}',
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('عدد الخامات / Materials', 'Materials'),
              '${ctx['unique_materials'] ?? 0}',
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('مقبول مشروط + جزئي', 'Conditional + partial'),
              '${ctx['conditional_partial'] ?? 0}',
            ),
          ),
        ],
      ),
    ];
  }

  static String _acceptedQtyCtx(Map<String, dynamic> ctx) {
    final a = ctx['total_accepted_quantity'];
    final b = ctx['total_accepted_qty'];
    return '${a ?? b ?? '-'}';
  }

  static Future<Uint8List> renderDaily(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    return _renderPeriod(
      _Kind.daily,
      ctx,
      _t('التقرير اليومي / Daily Report', 'Daily Report'),
      _dailySubtitle(ctx),
    );
  }

  static String _dailySubtitle(Map<String, dynamic> ctx) {
    final shift = '${ctx['shift_label'] ?? ''}'.trim();
    final date = '${ctx['formatted_date'] ?? ctx['date_str'] ?? ''}';
    final gen = '${ctx['generation_time'] ?? ''}';
    var s = date;
    if (shift.isNotEmpty) s = '$s — $shift';
    if (gen.isNotEmpty)
      s =
          '$s   (${_t('انشئ', 'Generated')} ${gen.substring(0, gen.length > 16 ? 16 : gen.length)})';
    return s;
  }

  static Future<Uint8List> renderMonthly(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    return _renderPeriod(
      _Kind.monthly,
      ctx,
      _t('التقرير الشهري / Monthly Report', 'Monthly Report'),
      _periodSubtitle(ctx),
    );
  }

  static String _periodSubtitle(Map<String, dynamic> ctx) {
    final label = ctx['month_name_ar'] is String
        ? '${ctx['month_name_ar']}'
        : '';
    final en = '${ctx['month_name']}';
    var s = _ar
        ? '$label ${ctx['year']} — $en'
        : '$en ${ctx['year']}';
    final now = '${ctx['now'] ?? ''}';
    if (now.isNotEmpty) s = '$s   (${_t('انشئ', 'Generated')} $now)';
    return s;
  }

  static Future<Uint8List> renderYearly(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    return _renderPeriod(
      _Kind.yearly,
      ctx,
      _t('التقرير السنوي / Yearly Report', 'Yearly Report'),
      '${ctx['year']}   (${_t('انشئ', 'Generated')} ${ctx['now']})',
    );
  }

  static Future<Uint8List> renderFollowUp(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    return _renderPeriod(
      _Kind.followUp,
      ctx,
      _t('تقرير المتابعة / Follow-up Report', 'Follow-up Report'),
      _dailySubtitle(ctx),
    );
  }

  static Future<Uint8List> _renderPeriod(
    _Kind kind,
    Map<String, dynamic> ctx,
    String title,
    String subtitle,
  ) async {
    await _font();
    final body = <pw.Widget>[];
    body.add(_periodHeader(title, subtitle, ctx));
    body.add(_spacer(8));
    body.addAll(
      _summaryStats(
        ctx,
        monthly: kind == _Kind.monthly,
        yearly: kind == _Kind.yearly,
      ),
    );

    if (kind == _Kind.monthly) {
      body.addAll([
        _spacer(10),
        _sectionTitle(_t('الاتجاه الشهري / Monthly Trend (آخر 6 شهور)', 'Monthly Trend (last 6 months)')),
        _spacer(4),
        _trendTable((ctx['trend_months'] as List?) ?? const []),
        _spacer(10),
        _sectionTitle(_t('تفصيل حسب الخامة / Material Summary', 'Material Summary')),
        _spacer(4),
        ..._materialSectionsTables(ctx['materials'] as List? ?? const []),
        _spacer(10),
        _sectionTitle(_t('تفصيل حسب المورد / Supplier Summary', 'Supplier Summary')),
        _spacer(4),
        _supplierTable(ctx['suppliers'] as List? ?? const []),
      ]);
    } else if (kind == _Kind.yearly) {
      body.addAll([
        _spacer(10),
        _sectionTitle(_t('تحليل شهري / Monthly Analysis', 'Monthly Analysis')),
        _spacer(4),
        _yearlyMonthlyTable((ctx['monthly_stats'] as List?) ?? const []),
        _spacer(10),
        _sectionTitle(_t('تحليل رباعي / Quarterly Analysis', 'Quarterly Analysis')),
        _spacer(4),
        _quarterlyTable((ctx['quarterly_stats'] as List?) ?? const []),
        _spacer(10),
        _sectionTitle(_t('تفصيل حسب الخامة / Material Summary', 'Material Summary')),
        _spacer(4),
        ..._materialSectionsTables(ctx['materials'] as List? ?? const []),
        _spacer(10),
        _sectionTitle(_t('أهم خمسة موردين / Top 5 Suppliers', 'Top 5 Suppliers')),
        _spacer(4),
        _supplierTable(ctx['top_suppliers'] as List? ?? const []),
      ]);
    } else {
      body.addAll([
        _spacer(10),
        _sectionTitle(_t('تفصيل حسب الخامة / Material Summary', 'Material Summary')),
        _spacer(4),
        ..._materialSectionsTables(
          (ctx['material_sections'] as List?) ??
              (ctx['materials'] as List?) ??
              const [],
        ),
      ]);
    }

    final recommendations = (ctx['recommendations'] as List?) ?? const [];
    if (recommendations.isNotEmpty) {
      body.add(_spacer(10));
      body.add(_sectionTitle(_t('التوصيات / Recommendations', 'Recommendations')));
      body.add(_spacer(4));
      final recs = <pw.Widget>[];
      for (var i = 0; i < recommendations.length; i++) {
        recs.add(
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _txt('${i + 1}. ', size: 9, bold: true),
              pw.Expanded(child: _txt('${recommendations[i]}', size: 9)),
            ],
          ),
        );
        recs.add(_spacer(3));
      }
      body.addAll(recs);
    }

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: _a4(),
        build: (c) => [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: body,
          ),
        ],
      ),
    );
    return doc.save();
  }

  static pw.Widget _trendTable(List<dynamic> months) {
    final rows = <List<pw.Widget>>[];
    for (final entry in months) {
      final m = entry as Map;
      rows.add([
        _txt('${m['label']}', size: 8),
        _txt('${m['count']}', size: 8),
        _txt('${m['approved']}', size: 8),
        _txt('${m['rejected']}', size: 8),
        _txt('${m['approval_rate']}%', size: 8),
        _txt('${m['rejection_rate']}%', size: 8),
        _txt('${m['total_qty']}', size: 8),
      ]);
    }
    return _simpleTable(
      [
        _t('الشهر / Month', 'Month'),
        _t('العدد / Count', 'Count'),
        _t('قبول / Accept', 'Accept'),
        _t('رفض / Reject', 'Reject'),
        _t('نسبة القبول % / Accept %', 'Accept %'),
        _t('نسبة الرفض % / Reject %', 'Reject %'),
        _t('الكمية / Qty', 'Qty'),
      ],
      rows,
      const {
        0: pw.FlexColumnWidth(1.7),
        1: pw.FlexColumnWidth(0.7),
        2: pw.FlexColumnWidth(0.7),
        3: pw.FlexColumnWidth(0.7),
        4: pw.FlexColumnWidth(1.1),
        5: pw.FlexColumnWidth(1.1),
        6: pw.FlexColumnWidth(1.3),
      },
    );
  }

  static pw.Widget _yearlyMonthlyTable(List<dynamic> months) {
    final rows = <List<pw.Widget>>[];
    for (final entry in months) {
      final m = entry as Map;
      rows.add([
        _txt('${m['month']}', size: 8),
        _txt('${m['total']}', size: 8),
        _txt('${m['approved']}', size: 8),
        _txt('${m['conditional']}', size: 8),
        _txt('${m['partial']}', size: 8),
        _txt('${m['rejected']}', size: 8),
        _txt('${m['approval_rate']}%', size: 8),
        _txt('${m['rejection_rate']}%', size: 8),
        _txt('${m['total_qty']}', size: 8),
      ]);
    }
    return _simpleTable(
      [
        _t('الشهر', 'Month'),
        _t('العدد', 'Count'),
        _t('قبول', 'Accept'),
        _t('مشروط', 'Conditional'),
        _t('جزئي', 'Partial'),
        _t('رفض', 'Reject'),
        _t('قبول %', 'Accept %'),
        _t('رفض %', 'Reject %'),
        _t('الكمية', 'Qty'),
      ],
      rows,
      const {
        0: pw.FlexColumnWidth(1.4),
        1: pw.FlexColumnWidth(0.6),
        2: pw.FlexColumnWidth(0.6),
        3: pw.FlexColumnWidth(0.7),
        4: pw.FlexColumnWidth(0.6),
        5: pw.FlexColumnWidth(0.6),
        6: pw.FlexColumnWidth(0.9),
        7: pw.FlexColumnWidth(0.9),
        8: pw.FlexColumnWidth(1.2),
      },
    );
  }

  static pw.Widget _quarterlyTable(List<dynamic> quarters) {
    final rows = <List<pw.Widget>>[];
    for (final entry in quarters) {
      final q = entry as Map;
      rows.add([
        _txt('${q['name']}', size: 8),
        _txt('${q['total']}', size: 8),
        _txt('${q['approved']}', size: 8),
        _txt('${q['partial']}', size: 8),
        _txt('${q['rejected']}', size: 8),
        _txt('${q['approval_rate']}%', size: 8),
        _txt('${q['rejection_rate']}%', size: 8),
      ]);
    }
    return _simpleTable(
      [_t('الربع', 'Quarter'), _t('العدد', 'Count'), _t('قبول', 'Accept'), _t('جزئي', 'Partial'), _t('رفض', 'Reject'), _t('قبول %', 'Accept %'), _t('رفض %', 'Reject %')],
      rows,
      const {
        0: pw.FlexColumnWidth(2.2),
        1: pw.FlexColumnWidth(0.7),
        2: pw.FlexColumnWidth(0.7),
        3: pw.FlexColumnWidth(0.7),
        4: pw.FlexColumnWidth(0.7),
        5: pw.FlexColumnWidth(1.0),
        6: pw.FlexColumnWidth(1.0),
      },
    );
  }

  static List<pw.Widget> _materialSectionsTables(List<dynamic> sections) {
    final widgets = <pw.Widget>[];
    for (final section in sections) {
      final s = section as Map;
      widgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 8),
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(
              color: PdfColor.fromInt(0xFFDDDDDD),
              width: 0.6,
            ),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                children: [
                  pw.Expanded(
                    child: _txt(
                      '${s['name'] ?? ''}',
                      size: 9.5,
                      bold: true,
                      color: _accent,
                    ),
                  ),
                  _txt(_t('العدد: ${s['count'] ?? 0}', 'Count: ${s['count'] ?? 0}'), size: 8, color: _muted),
                ],
              ),
              _spacer(3),
              _supplierRow(s),
              _spacer(3),
              if (s['rows'] != null)
                _detailRows(s['rows'] as List? ?? const [])
              else if (s['suppliers'] != null) ...[
                _txt(_t('الموردين / Suppliers:', 'Suppliers:'), size: 8, bold: true),
                _spacer(2),
                _supplierTable(s['suppliers'] as List? ?? const []),
              ],
            ],
          ),
        ),
      );
    }
    return widgets;
  }

  static pw.Widget _supplierRow(Map s) {
    return pw.Row(
      children: [
        pw.Expanded(child: _txt(_t('قبول: ${s['approved'] ?? 0}', 'Accept: ${s['approved'] ?? 0}'), size: 8)),
        pw.Expanded(
          child: _txt(_t('مقبول مشروط: ${s['conditional'] ?? 0}', 'Conditional: ${s['conditional'] ?? 0}'), size: 8),
        ),
        pw.Expanded(child: _txt(_t('جزئي: ${s['partial'] ?? 0}', 'Partial: ${s['partial'] ?? 0}'), size: 8)),
        pw.Expanded(child: _txt(_t('رفض: ${s['rejected'] ?? 0}', 'Reject: ${s['rejected'] ?? 0}'), size: 8)),
        pw.Expanded(
          child: _txt(
            _t('نسبة القبول: ${s['approval_rate'] ?? 0}%', 'Accept %: ${s['approval_rate'] ?? 0}%'),
            size: 8,
            bold: true,
          ),
        ),
      ],
    );
  }

  static pw.Widget _detailRows(List<dynamic> rows) {
    final tr = <List<pw.Widget>>[];
    for (final row in rows) {
      final r = row as Map;
      tr.add([
        _txt('${r['index'] ?? ''}', size: 7.5),
        _txt('${r['entry_code'] ?? ''}', size: 7.5),
        _txt('${r['supplier'] ?? ''}', size: 7.5),
        _txt('${r['decision_time'] ?? ''}', size: 7.5),
        _txt('${r['quantity'] ?? ''}', size: 7.5),
        _txt('${r['decision_status'] ?? ''}', size: 7.5),
      ]);
    }
    return _simpleTable(
      ['#', _t('رقم العينة', 'Sample No.'), _t('المورد', 'Supplier'), _t('وقت القرار', 'Decision time'), _t('الكمية', 'Qty'), _t('الحالة', 'Status')],
      tr,
      const {
        0: pw.FlexColumnWidth(0.4),
        1: pw.FlexColumnWidth(1.4),
        2: pw.FlexColumnWidth(1.5),
        3: pw.FlexColumnWidth(1.1),
        4: pw.FlexColumnWidth(1.0),
        5: pw.FlexColumnWidth(1.2),
      },
    );
  }

  static pw.Widget _supplierTable(List<dynamic> sections) {
    final rows = <List<pw.Widget>>[];
    for (final s in sections) {
      final m = Map<String, dynamic>.from(s as Map);
      rows.add([
        _txt('${m['name'] ?? ''}', size: 8),
        _txt('${m['count'] ?? 0}', size: 8),
        _txt('${m['total_qty'] ?? ''}', size: 8),
        _txt('${m['accepted_qty'] ?? ''}', size: 8),
        _txt('${m['rejected_qty'] ?? ''}', size: 8),
        _txt('${m['approved'] ?? 0}', size: 8),
        _txt('${m['partial'] ?? 0}', size: 8),
        _txt('${m['rejected'] ?? 0}', size: 8),
        _txt('${m['approval_rate'] ?? 0}%', size: 8),
      ]);
    }
    return _simpleTable(
      [
        _t('المورد', 'Supplier'),
        _t('العدد', 'Count'),
        _t('الكمية', 'Qty'),
        _t('المقبول', 'Accepted'),
        _t('المرفوض', 'Rejected'),
        _t('قبول', 'Accept'),
        _t('جزئي', 'Partial'),
        _t('رفض', 'Reject'),
        _t('قبول %', 'Accept %'),
      ],
      rows,
      const {
        0: pw.FlexColumnWidth(1.6),
        1: pw.FlexColumnWidth(0.5),
        2: pw.FlexColumnWidth(1.1),
        3: pw.FlexColumnWidth(1.1),
        4: pw.FlexColumnWidth(1.1),
        5: pw.FlexColumnWidth(0.5),
        6: pw.FlexColumnWidth(0.5),
        7: pw.FlexColumnWidth(0.5),
        8: pw.FlexColumnWidth(0.9),
      },
    );
  }

  // ── Lab report ────────────────────────────────────────────────────────

  static Future<Uint8List> renderLab(Map<String, dynamic> ctx) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    final body = <pw.Widget>[
      _periodHeader(
        '${ctx['title'] ?? 'Lab Report'}',
        '${ctx['period_label'] ?? ''}',
        ctx,
      ),
      _spacer(8),
      pw.Row(
        children: [
          pw.Expanded(
            child: _statCard(
              _t('إجمالي الفحوصات / Total', 'Total'),
              '${ctx['total'] ?? 0}',
              highlighted: true,
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('داخل المدى / In range', 'In range'),
              '${ctx['in_count'] ?? 0}',
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('خارج المدى / Out of range', 'Out of range'),
              '${ctx['out_count'] ?? 0}',
              highlighted: true,
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('بدون مدى / No range', 'No range'),
              '${ctx['no_range_count'] ?? 0}',
            ),
          ),
          pw.Expanded(
            child: _statCard(
              _t('المصادر / Sources', 'Sources'),
              '${ctx['unique_sources'] ?? 0}',
            ),
          ),
        ],
      ),
    ];
    final sections = (ctx['sections'] as List?) ?? const [];
    for (final section in sections) {
      final s = section as Map;
      body.add(_spacer(10));
      body.add(
        _sectionTitle(
          _t(
            '${s['name']} (${s['type_label']}) — ${s['count']} فحص، خارج المدى ${s['out_count']}',
            '${s['name']} (${s['type_label']}) — ${s['count']} tests, out of range ${s['out_count']}',
          ),
        ),
      );
      body.add(_spacer(4));
      final rows = <List<pw.Widget>>[];
      for (final row in (s['rows'] as List?) ?? const []) {
        final r = row as Map;
        final state = '${r['range_state'] ?? ''}';
        final isOut = state == 'out';
        rows.add([
          _txt('${r['index'] ?? ''}', size: 7.5),
          _txt('${r['tested_at'] ?? ''}', size: 7.5),
          _txt('${r['sample_name'] ?? ''}', size: 7.5),
          _txt('${r['entry_code'] ?? ''}', size: 7.5),
          _txt('${r['analysis_name'] ?? ''}', size: 7.5),
          _txt('${r['analysis_reference'] ?? ''}', size: 7.5),
          pw.Container(
            color: isOut ? _redBg : null,
            child: _txt(
              '${r['result_text'] ?? ''}',
              size: 7.5,
              color: isOut ? _red : _ink,
              bold: isOut,
            ),
          ),
          _txt('${r['range_text'] ?? ''}', size: 7.5),
          _txt('${r['tested_by_name'] ?? ''}', size: 7.5),
        ]);
      }
      body.add(
        _simpleTable(
          [
            '#',
            'التاريخ',
            'العينة',
            'رقم الدخول',
            'التحليل',
            'المرجع',
            'النتيجة',
            'المدى',
            'الفني',
          ],
          rows,
          const {
            0: pw.FlexColumnWidth(0.4),
            1: pw.FlexColumnWidth(1.2),
            2: pw.FlexColumnWidth(1.2),
            3: pw.FlexColumnWidth(1.2),
            4: pw.FlexColumnWidth(1.5),
            5: pw.FlexColumnWidth(1.4),
            6: pw.FlexColumnWidth(1.4),
            7: pw.FlexColumnWidth(1.2),
            8: pw.FlexColumnWidth(1.2),
          },
        ),
      );
    }
    body.add(_spacer(8));
    body.add(
      _txt(_t('انشئ في: ${ctx['generation_time'] ?? ''}', 'Generated at: ${ctx['generation_time'] ?? ''}'), size: 8, color: _muted),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: _a4(),
        build: (c) => [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: body,
          ),
        ],
      ),
    );
    return doc.save();
  }

  // ── Generic register table (test log) ─────────────────────────────

  /// One A4 table document for register-style exports that have no HTML
  /// template of their own (the test log's PDF fallback when no headless
  /// browser is available). The `pdf` package spans the [pw.Table] across as
  /// many pages as it needs and repeats the header row on each.
  static Future<Uint8List> renderTable({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
  }) async {
    _ar = AppText.arabic;
    await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()),
    );
    pw.Widget cell(String value, {bool bold = false}) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: _txt(value, size: 8, bold: bold),
    );
    final table = pw.Table(
      columnWidths: {
        for (var i = 0; i < headers.length; i++)
          i: const pw.FlexColumnWidth(1),
      },
      border: pw.TableBorder.all(
        color: PdfColor.fromInt(0xFFCCCCCC),
        width: 0.4,
      ),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: pw.BoxDecoration(color: _light),
          children: [for (final h in headers) cell(h, bold: true)],
        ),
        for (var ri = 0; ri < rows.length; ri++)
          pw.TableRow(
            decoration: pw.BoxDecoration(
              color: ri.isEven ? _zebraA : _zebraB,
            ),
            children: [
              for (var ci = 0; ci < headers.length; ci++)
                cell(ci < rows[ri].length ? rows[ri][ci] : ''),
            ],
          ),
      ],
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: _a4(),
        header: (c) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: _txt(title, size: 13, bold: true),
        ),
        build: (c) => [table],
      ),
    );
    return doc.save();
  }
}
