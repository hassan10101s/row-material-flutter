import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'qr_render.dart';

/// Renders the report contexts (built in report_builder.dart) to PDF bytes
/// using the `pdf` package. The package performs Arabic shaping + bidi so the
/// bilingual content renders correctly.

enum _Kind { daily, monthly, yearly, followUp }

class PdfRenderer {
  static pw.Font? _baseFont;
  static pw.Font? _boldFont;

  static Future<pw.Font> _font() async {
    if (_baseFont == null) {
      final data = await rootBundle.load('assets/fonts/Cairo-Variable.ttf');
      _baseFont = pw.Font.ttf(data);
      _boldFont = pw.Font.ttf(data);
    }
    return _baseFont!;
  }

  static pw.Font _bold() => _boldFont ?? _baseFont!;

  static const _ink = PdfColor.fromInt(0xFF1F1F1F);
  static const _muted = PdfColor.fromInt(0xFF555555);
  static const _accent = PdfColor.fromInt(0xFF1B5E20);
  static const _light = PdfColor.fromInt(0xFFF0F7F0);
  static const _red = PdfColor.fromInt(0xFFB71C1C);
  static const _redBg = PdfColor.fromInt(0xFFFDECEA);

  static bool _hasArabic(String? s) {
    if (s == null) return false;
    for (final codeUnit in s.codeUnits) {
      if (codeUnit >= 0x0600 && codeUnit <= 0x06FF) return true;
    }
    return false;
  }

  static pw.TextDirection _dir(String? s) =>
      _hasArabic(s) ? pw.TextDirection.rtl : pw.TextDirection.ltr;

  static pw.TextAlign _align(String? s) =>
      _hasArabic(s) ? pw.TextAlign.right : pw.TextAlign.left;

  static pw.Text _txt(String? text,
      {double size = 9, bool bold = false, PdfColor? color, pw.TextAlign? align}) {
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
    await _font();
    final doc = pw.Document(theme: pw.ThemeData.withFont(
      base: _baseFont!,
      bold: _bold(),
    ));
    doc.addPage(pw.Page(
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
    ));
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
              _txt('تقرير فحص / Inspection Report', size: 11, color: _muted),
              _spacer(2),
              _txt('${ctx['sample_number'] ?? ''}', size: 9, color: _muted),
            ],
          ),
        ),
        if (logo != null)
          pw.SizedBox(
              width: 64, height: 48, child: pw.Image(logo)),
      ],
    );
  }

  static List<pw.Widget> _inspectionInfoBlocks(Map<String, dynamic> ctx) {
    final info = _simpleTable(
      ['الخاصية / Field', 'القيمة / Value'],
      [
        [
          _txt('رقم العينة / Sample No.', size: 9, bold: true),
          _txt('${ctx['sample_number'] ?? '-'}', size: 9),
        ],
        [
          _txt('التاريخ / Date', size: 9, bold: true),
          _txt('${ctx['date'] ?? '-'}', size: 9),
        ],
        [
          _txt('تاريخ الانتهاء / Expiry', size: 9, bold: true),
          _txt('${ctx['expiry_date'] ?? '-'}', size: 9),
        ],
        [
          _txt('اسم الخامة / Material', size: 9, bold: true),
          _txt('${ctx['material_name'] ?? '-'}', size: 9),
        ],
        [
          _txt('الكمية / Quantity', size: 9, bold: true),
          _txt('${ctx['quantity'] ?? '-'}', size: 9),
        ],
        [
          _txt('المورد / Supplier', size: 9, bold: true),
          _txt('${ctx['supplier'] ?? '-'}', size: 9),
        ],
        [
          _txt('رقم الشاحنة / Truck No.', size: 9, bold: true),
          _txt('${ctx['truck_number'] ?? '-'}', size: 9),
        ],
        [
          _txt('أخذ العينة / Sample taken by', size: 9, bold: true),
          _txt('${ctx['sample_taken_by'] ?? '-'}', size: 9),
        ],
        [
          _txt('الأخصائي / Specialist', size: 9, bold: true),
          _txt('${ctx['specialist_name'] ?? '-'}', size: 9),
        ],
        [
          _txt('أنشئ بواسطة / Created by', size: 9, bold: true),
          _txt('${ctx['created_by_name'] ?? '-'}', size: 9),
        ],
      ],
const {
        0: pw.FlexColumnWidth(2.0),
        1: pw.FlexColumnWidth(3.0),
      },
    );
    final decision = '${ctx['decision_label'] ?? '-'}';
    final verdict = pw.Container(
      margin: const pw.EdgeInsets.symmetric(vertical: 8),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: ctx['decision_class'] == 'Rejected' || ctx['decision_class'] == 'Partial'
            ? _redBg
            : _light,
        border: pw.Border.all(
            color: ctx['decision_class'] == 'Rejected' || ctx['decision_class'] == 'Partial'
                ? _red
                : _accent,
            width: 1),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(children: [
            _txt('النتيجة / Decision: ', size: 10, bold: true),
            _txt(decision, size: 10.5, bold: true, color: _accent),
            _spacer(1),
            _txt('الإصدار ${ctx['decision_version'] ?? 1}', size: 9, color: _muted),
          ]),
          if (ctx['decision_reason'] is String &&
              '${ctx['decision_reason']}' != '-' &&
              '${ctx['decision_reason']}'.isNotEmpty &&
              ctx['decision_status'] != 'APPROVED') ...[
            _spacer(4),
            _txt('السبب / Reason: ${ctx['decision_reason']}', size: 9.5),
          ],
        ],
      ),
    );
    return [info, verdict];
  }

  static List<pw.Widget> _inspectionResultTables(Map<String, dynamic> ctx) {
    final widgets = <pw.Widget>[];
    final sampleNames = (ctx['sample_names'] as List?) ?? const [];
    final physical = (ctx['physical_data'] as List?) ?? const [];
    final chemical = (ctx['chemical_data'] as List?) ?? const [];

    if (physical.isNotEmpty) {
      widgets.add(_spacer(10));
      widgets.add(_sectionTitle('الفحوصات الفيزيائية / Physical Properties'));
      widgets.add(_spacer(4));
      final cols = <int, pw.FlexColumnWidth>{
        0: const pw.FlexColumnWidth(2.2),
        1: const pw.FlexColumnWidth(1.6),
      };
      final header = <String>['الخاصية / Property', 'المتطلب / Requirement'];
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
          cells.add(pw.Container(
            color: out ? _redBg : null,
            child: _txt('${actuals[i]}',
                size: 8.5, color: out ? _red : _ink, bold: out),
          ));
        }
        rows.add(cells);
      }
      widgets.add(_simpleTable(header, rows, cols, colorHeader: true));
    }

    if (chemical.isNotEmpty) {
      widgets.add(_spacer(10));
      widgets.add(_sectionTitle('النتائج الكيميائية / Chemical Results'));
      widgets.add(_spacer(4));
      final cols = <int, pw.FlexColumnWidth>{
        0: const pw.FlexColumnWidth(2.0),
        1: const pw.FlexColumnWidth(1.1),
        2: const pw.FlexColumnWidth(1.1),
        3: const pw.FlexColumnWidth(0.7),
      };
      final header = <String>[
        'الخاصية / Property',
        'الحد الأدنى / Min',
        'الحد الأقصى / Max',
        'الوحدة / Unit',
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
          cells.add(pw.Container(
            color: out ? _redBg : null,
            child: _txt('${actuals[i]}',
                size: 8.5, color: out ? _red : _ink, bold: out),
          ));
        }
        rows.add(cells);
      }
      widgets.add(_simpleTable(header, rows, cols, colorHeader: true));
    }
    return widgets;
  }

  static pw.Widget _simpleTable(
    List<String> header,
    List<List<pw.Widget>> rows,
    Map<int, pw.FlexColumnWidth> cols, {
    bool colorHeader = true,
  }) {
    final tr = <pw.TableRow>[];
    tr.add(pw.TableRow(
      decoration: pw.BoxDecoration(color: colorHeader ? _light : null),
      children: [
        for (final h in header)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: _txt(h, size: 8.2, bold: true),
          ),
      ],
    ));
    for (final row in rows) {
      tr.add(pw.TableRow(children: [
        for (var ci = 0; ci < header.length; ci++)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: ci < row.length ? row[ci] : _txt(''),
          ),
      ]));
    }
    return pw.Table(
      columnWidths: cols,
      defaultColumnWidth: const pw.IntrinsicColumnWidth(),
      border: pw.TableBorder.all(
          color: PdfColor.fromInt(0xFFCCCCCC), width: 0.4),
      children: tr,
    );
  }

  static List<pw.Widget> _inspectionNotes(Map<String, dynamic> ctx) {
    final widgets = <pw.Widget>[];
    if (ctx['show_follow_up_note'] == true) {
      final note = '${ctx['follow_up_note'] ?? '-'}';
      if (note.isNotEmpty && note != '-') {
        widgets.add(_spacer(8));
        widgets.add(pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFE8F5E9),
              border: pw.Border(left: pw.BorderSide(color: _accent, width: 3))),
          child: _txt('ملاحظة المتابعة / Follow-up note: $note', size: 9, color: _accent),
        ));
      }
    }
    if (ctx['show_rejected_quantity'] == true) {
      widgets.add(_spacer(6));
      widgets.add(pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration: const pw.BoxDecoration(
            color: _redBg,
            border: pw.Border(left: pw.BorderSide(color: _red, width: 3))),
        child: _txt('الكمية المرفوضة / Rejected quantity: ${ctx['rejected_quantity']}', size: 9, color: _red),
      ));
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
        _txt('${row['label_ar'] ?? ''} / ${row['label_en'] ?? ''}',
            size: 8.5, bold: true),
        _txt('${row['reason'] ?? ''}', size: 8.5),
        _txt('${row['changed_at'] ?? ''}', size: 8.5),
      ]);
    }
    return [
      _spacer(10),
      _sectionTitle('تاريخ القرارات / Decision History'),
      _spacer(4),
      _simpleTable(
        ['الإصدار', 'الحالة', 'السبب', 'التاريخ'],
        rows,
        const {
          0: pw.FlexColumnWidth(0.7),
          1: pw.FlexColumnWidth(1.6),
          2: pw.FlexColumnWidth(2.4),
          3: pw.FlexColumnWidth(1.4),
        },
      ),
    ];
  }

  static pw.Widget _qrFooter(Map<String, dynamic> ctx, {double marginTop = 0}) {
    final payload = '${ctx['qr_payload_text'] ?? ''}';
    final qrBytes = payload.isEmpty ? null : qrPngBytes(payload);
    final pwImage =
        qrBytes == null ? null : pw.Image(pw.MemoryImage(qrBytes), width: 92, height: 92);
    return pw.Container(
      margin: pw.EdgeInsets.only(top: marginTop),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: PdfColor.fromInt(0xFFCCCCCC)))),
      padding: const pw.EdgeInsets.only(top: 6),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          if (pwImage != null) ...[
            pwImage,
            _spacer(10),
          ],
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _txt('تاريخ الإنشاء / Generated: ${ctx['generated_at']}', size: 8, color: _muted),
                _spacer(3),
                _txt('توقيع الأخصائي / Specialist signature: ______________', size: 8.5),
                _spacer(3),
                _txt('توقيع مدير الجودة / QA manager signature: ____________', size: 8.5),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Label (10x5cm) ────────────────────────────────────────────────────

  static Future<Uint8List> renderLabel(Map<String, dynamic> ctx) async {
    await _font();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()));
    final insp = (ctx['inspection'] as Map?) ?? const {};
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(
        10 * PdfPageFormat.cm,
        5 * PdfPageFormat.cm,
        marginAll: 2 * PdfPageFormat.mm,
      ),
      build: (c) {
        final payload = '${ctx['qr_payload_text'] ?? ''}';
        final img = payload.isEmpty ? null : pw.Image(pw.MemoryImage(qrPngBytes(payload)), width: 30, height: 30);
        return pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _txt('${insp['material_name'] ?? ''}', size: 8.5, bold: true),
                  _spacer(1),
                  _txt('${ctx['department_label']}', size: 6.5, color: _muted),
                  _spacer(2),
                  pw.Wrap(spacing: 6, runSpacing: 1, children: [
                    _txt('رقم: ${insp['entry_code'] ?? ''}', size: 7),
                    _txt('${insp['inspection_date'] ?? ''}', size: 7),
                  ]),
                  _spacer(1),
                  pw.Wrap(spacing: 6, runSpacing: 1, children: [
                    _txt('كمية: ${ctx['quantity_display']}', size: 7),
                    _txt('مورد: ${insp['supplier'] ?? ''}', size: 7),
                    _txt('شاحنة: ${insp['truck_number'] ?? ''}', size: 7),
                  ]),
                  _spacer(1),
                  pw.Wrap(spacing: 6, runSpacing: 1, children: [
                    _txt('أخذ: ${insp['sample_taken_by'] ?? ''}', size: 7),
                    _txt('أخصائي: ${insp['specialist_name'] ?? ''}', size: 7),
                  ]),
                  _spacer(1),
                  _txt('${ctx['generated_at']}', size: 6, color: _muted),
                ],
              ),
            ),
            ?img,
          ],
        );
      },
    ));
    return doc.save();
  }

  // ── Batch labels ──────────────────────────────────────────────────────

  static Future<Uint8List> renderBatchLabels(Map<String, dynamic> ctx) async {
    await _font();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()));
    final labels = (ctx['labels'] as List?) ?? const [];
    final pages = <pw.Page>[];
    for (var i = 0; i < labels.length; i += 6) {
      final slice = labels.sublist(i, i + 6 > labels.length ? labels.length : i + 6);
      final cells = <pw.Widget>[];
      for (final label in slice) {
        cells.add(pw.Container(
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColor.fromInt(0xFFCCCCCC), width: 0.6),
          ),
          padding: const pw.EdgeInsets.all(6),
          child: _batchLabelInner(label),
        ));
      }
      pages.add(pw.Page(
        pageFormat: _a4(),
        margin: const pw.EdgeInsets.all(5),
        build: (c) => pw.GridView(
          crossAxisCount: 2,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1.9,
          children: cells,
        ),
      ));
    }
    if (pages.isEmpty) {
      pages.add(pw.Page(pageFormat: _a4(), build: (_) => _txt('No labels', size: 10)));
    }
    for (final p in pages) {
      doc.addPage(p);
    }
    return doc.save();
  }

  static pw.Widget _batchLabelInner(Map<String, dynamic> label) {
    final payload = '${label['qr_payload_text'] ?? ''}';
    final img = payload.isEmpty ? null : pw.Image(pw.MemoryImage(qrPngBytes(payload)), width: 30, height: 30);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _txt('${label['material_name'] ?? ''}', size: 8.5, bold: true),
              _spacer(1),
              _txt('رقم: ${label['entry_code'] ?? ''} | ${label['inspection_date'] ?? ''}', size: 7),
              _spacer(1),
              _txt('مورد: ${label['supplier'] ?? ''} | شاحنة: ${label['truck_number'] ?? ''} | كمية: ${label['quantity_display'] ?? ''}', size: 7),
              _spacer(1),
              _txt('أخذ: ${label['sample_taken_by'] ?? ''} | أخصائي: ${label['specialist_name'] ?? ''}', size: 7),
              _spacer(1),
              _txt('الحالة: ${label['decision_status'] ?? ''} (v${label['decision_version'] ?? 1})', size: 7, bold: true),
            ],
          ),
        ),
        ?img,
      ],
    );
  }

  // ── Daily / Monthly / Yearly / Follow-up ──────────────────────────────

  static pw.Widget _statCard(String label, String value, {bool highlighted = false}) {
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
          _txt(value, size: 11, bold: true, color: highlighted ? _accent : _ink),
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
            ],
          ),
        ),
        if (logo != null)
          pw.SizedBox(height: 42, width: 56, child: pw.Image(logo)),
      ],
    );
  }

  static List<pw.Widget> _summaryStats(Map<String, dynamic> ctx, {bool monthly = false, bool yearly = false}) {
    return [
      pw.Row(children: [
        pw.Expanded(child: _statCard('إجمالي / Total', '${ctx['total'] ?? 0}')),
        pw.Expanded(child: _statCard('قبول نهائي / Approved', '${ctx['approved'] ?? 0}', highlighted: true)),
        pw.Expanded(child: _statCard('قبول مع متابعة / Conditional', '${ctx['conditional'] ?? 0}')),
        pw.Expanded(child: _statCard('رفض جزئي / Partial', '${ctx['partial'] ?? 0}')),
        pw.Expanded(child: _statCard('رفض كلي / Rejected', '${ctx['rejected'] ?? 0}')),
      ]),
      _spacer(4),
      pw.Row(children: [
        pw.Expanded(child: _statCard('معدل القبول / Acceptance %', '${ctx['approval_rate'] ?? 0}%')),
        if (monthly || yearly) ...[
          pw.Expanded(child: _statCard('معدل الرفض / Rejection %', '${ctx['rejection_rate'] ?? 0}%')),
        ],
        pw.Expanded(child: _statCard('الكمية الكلية / Total qty', '${ctx['total_quantity'] ?? '-'}')),
        pw.Expanded(child: _statCard('الكمية المقبولة / Accepted qty', _acceptedQtyCtx(ctx))),
        pw.Expanded(child: _statCard('الكمية المرفوضة / Rejected qty', '${ctx['total_rejected_quantity'] ?? ctx['total_rejected_qty'] ?? '-'}')),
      ]),
      _spacer(4),
      pw.Row(children: [
        pw.Expanded(child: _statCard('الموردون المميزون / Suppliers', '${ctx['unique_suppliers'] ?? 0}')),
        pw.Expanded(child: _statCard('عدد الخامات / Materials', '${ctx['unique_materials'] ?? 0}')),
        pw.Expanded(child: _statCard('مقبول مشروط + جزئي', '${ctx['conditional_partial'] ?? 0}')),
      ]),
    ];
  }

  static String _acceptedQtyCtx(Map<String, dynamic> ctx) {
    final a = ctx['total_accepted_quantity'];
    final b = ctx['total_accepted_qty'];
    return '${a ?? b ?? '-'}';
  }

  static Future<Uint8List> renderDaily(Map<String, dynamic> ctx) async {
    return _renderPeriod(_Kind.daily, ctx, 'التقرير اليومي / Daily Report', _dailySubtitle(ctx));
  }

  static String _dailySubtitle(Map<String, dynamic> ctx) {
    final shift = '${ctx['shift_label'] ?? ''}'.trim();
    final date = '${ctx['formatted_date'] ?? ctx['date_str'] ?? ''}';
    final gen = '${ctx['generation_time'] ?? ''}';
    var s = date;
    if (shift.isNotEmpty) s = '$s — $shift';
    if (gen.isNotEmpty) s = '$s   (انشئ ${gen.substring(0, gen.length > 16 ? 16 : gen.length)})';
    return s;
  }

  static Future<Uint8List> renderMonthly(Map<String, dynamic> ctx) async {
    return _renderPeriod(_Kind.monthly, ctx, 'التقرير الشهري / Monthly Report', _periodSubtitle(ctx));
  }

  static String _periodSubtitle(Map<String, dynamic> ctx) {
    final label = ctx['month_name_ar'] is String ? '${ctx['month_name_ar']}' : '';
    var s = '$label ${ctx['year']} — ${ctx['month_name']}';
    final now = '${ctx['now'] ?? ''}';
    if (now.isNotEmpty) s = '$s   (انشئ $now)';
    return s;
  }

  static Future<Uint8List> renderYearly(Map<String, dynamic> ctx) async {
    return _renderPeriod(_Kind.yearly, ctx, 'التقرير السنوي / Yearly Report', '${ctx['year']}   (انشئ ${ctx['now']})');
  }

  static Future<Uint8List> renderFollowUp(Map<String, dynamic> ctx) async {
    return _renderPeriod(_Kind.followUp, ctx, 'تقرير المتابعة / Follow-up Report', _dailySubtitle(ctx));
  }

  static Future<Uint8List> _renderPeriod(_Kind kind, Map<String, dynamic> ctx, String title, String subtitle) async {
    await _font();
    final body = <pw.Widget>[];
    body.add(_periodHeader(title, subtitle, ctx));
    body.add(_spacer(8));
    body.addAll(_summaryStats(ctx,
        monthly: kind == _Kind.monthly, yearly: kind == _Kind.yearly));

    if (kind == _Kind.monthly) {
      body.addAll([
        _spacer(10),
        _sectionTitle('الاتجاه الشهري / Monthly Trend (آخر 6 شهور)'),
        _spacer(4),
        _trendTable((ctx['trend_months'] as List?) ?? const []),
        _spacer(10),
        _sectionTitle('تفصيل حسب الخامة / Material Summary'),
        _spacer(4),
        ..._materialSectionsTables(ctx['materials'] as List? ?? const []),
        _spacer(10),
        _sectionTitle('تفصيل حسب المورد / Supplier Summary'),
        _spacer(4),
        _supplierTable(ctx['suppliers'] as List? ?? const []),
      ]);
    } else if (kind == _Kind.yearly) {
      body.addAll([
        _spacer(10),
        _sectionTitle('تحليل شهري / Monthly Analysis'),
        _spacer(4),
        _yearlyMonthlyTable((ctx['monthly_stats'] as List?) ?? const []),
        _spacer(10),
        _sectionTitle('تحليل رباعي / Quarterly Analysis'),
        _spacer(4),
        _quarterlyTable((ctx['quarterly_stats'] as List?) ?? const []),
        _spacer(10),
        _sectionTitle('تفصيل حسب الخامة / Material Summary'),
        _spacer(4),
        ..._materialSectionsTables(ctx['materials'] as List? ?? const []),
        _spacer(10),
        _sectionTitle('أهم خمسة موردين / Top 5 Suppliers'),
        _spacer(4),
        _supplierTable(ctx['top_suppliers'] as List? ?? const []),
      ]);
    } else {
      body.addAll([
        _spacer(10),
        _sectionTitle('تفصيل حسب الخامة / Material Summary'),
        _spacer(4),
        ..._materialSectionsTables(
            (ctx['material_sections'] as List?) ??
                (ctx['materials'] as List?) ??
                const []),
      ]);
    }

    final recommendations = (ctx['recommendations'] as List?) ?? const [];
    if (recommendations.isNotEmpty) {
      body.add(_spacer(10));
      body.add(_sectionTitle('التوصيات / Recommendations'));
      body.add(_spacer(4));
      final recs = <pw.Widget>[];
      for (var i = 0; i < recommendations.length; i++) {
        recs.add(pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _txt('${i + 1}. ', size: 9, bold: true),
          pw.Expanded(child: _txt('${recommendations[i]}', size: 9)),
        ]));
        recs.add(_spacer(3));
      }
      body.addAll(recs);
    }

    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()));
    doc.addPage(pw.MultiPage(
      pageFormat: _a4(),
      build: (c) => [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: body),
      ],
    ));
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
      ['الشهر', 'العدد', 'قبول', 'رفض', 'نسبة القبول %', 'نسبة الرفض %', 'الكمية'],
      rows,
      const {0: pw.FlexColumnWidth(1.7), 1: pw.FlexColumnWidth(0.7), 2: pw.FlexColumnWidth(0.7), 3: pw.FlexColumnWidth(0.7), 4: pw.FlexColumnWidth(1.1), 5: pw.FlexColumnWidth(1.1), 6: pw.FlexColumnWidth(1.3)},
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
      ['الشهر', 'العدد', 'قبول', 'مشروط', 'جزئي', 'رفض', 'قبول %', 'رفض %', 'الكمية'],
      rows,
      const {0: pw.FlexColumnWidth(1.4), 1: pw.FlexColumnWidth(0.6), 2: pw.FlexColumnWidth(0.6), 3: pw.FlexColumnWidth(0.7), 4: pw.FlexColumnWidth(0.6), 5: pw.FlexColumnWidth(0.6), 6: pw.FlexColumnWidth(0.9), 7: pw.FlexColumnWidth(0.9), 8: pw.FlexColumnWidth(1.2)},
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
      ['الربع', 'العدد', 'قبول', 'جزئي', 'رفض', 'قبول %', 'رفض %'],
      rows,
      const {0: pw.FlexColumnWidth(2.2), 1: pw.FlexColumnWidth(0.7), 2: pw.FlexColumnWidth(0.7), 3: pw.FlexColumnWidth(0.7), 4: pw.FlexColumnWidth(0.7), 5: pw.FlexColumnWidth(1.0), 6: pw.FlexColumnWidth(1.0)},
    );
  }

  static List<pw.Widget> _materialSectionsTables(List<dynamic> sections) {
    final widgets = <pw.Widget>[];
    for (final section in sections) {
      final s = section as Map;
      widgets.add(pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 8),
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColor.fromInt(0xFFDDDDDD), width: 0.6),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(children: [
              pw.Expanded(child: _txt('${s['name'] ?? ''}', size: 9.5, bold: true, color: _accent)),
              _txt('العدد: ${s['count'] ?? 0}', size: 8, color: _muted),
            ]),
            _spacer(3),
            _supplierRow(s),
            _spacer(3),
            if (s['rows'] != null)
              _detailRows(s['rows'] as List? ?? const [])
            else if (s['suppliers'] != null) ...[
              _txt('الموردين / Suppliers:', size: 8, bold: true),
              _spacer(2),
              _supplierTable(s['suppliers'] as List? ?? const []),
            ],
          ],
        ),
      ));
    }
    return widgets;
  }

  static pw.Widget _supplierRow(Map s) {
    return pw.Row(children: [
      pw.Expanded(child: _txt('قبول: ${s['approved'] ?? 0}', size: 8)),
      pw.Expanded(child: _txt('مقبول مشروط: ${s['conditional'] ?? 0}', size: 8)),
      pw.Expanded(child: _txt('جزئي: ${s['partial'] ?? 0}', size: 8)),
      pw.Expanded(child: _txt('رفض: ${s['rejected'] ?? 0}', size: 8)),
      pw.Expanded(child: _txt('نسبة القبول: ${s['approval_rate'] ?? 0}%', size: 8, bold: true)),
    ]);
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
      ['#', 'رقم العينة', 'المورد', 'وقت القرار', 'الكمية', 'الحالة'],
      tr,
      const {0: pw.FlexColumnWidth(0.4), 1: pw.FlexColumnWidth(1.4), 2: pw.FlexColumnWidth(1.5), 3: pw.FlexColumnWidth(1.1), 4: pw.FlexColumnWidth(1.0), 5: pw.FlexColumnWidth(1.2)},
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
      ['المورد', 'العدد', 'الكمية', 'المقبول', 'المرفوض', 'قبول', 'جزئي', 'رفض', 'قبول %'],
      rows,
      const {0: pw.FlexColumnWidth(1.6), 1: pw.FlexColumnWidth(0.5), 2: pw.FlexColumnWidth(1.1), 3: pw.FlexColumnWidth(1.1), 4: pw.FlexColumnWidth(1.1), 5: pw.FlexColumnWidth(0.5), 6: pw.FlexColumnWidth(0.5), 7: pw.FlexColumnWidth(0.5), 8: pw.FlexColumnWidth(0.9)},
    );
  }

  // ── Lab report ────────────────────────────────────────────────────────

  static Future<Uint8List> renderLab(Map<String, dynamic> ctx) async {
    await _font();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _baseFont!, bold: _bold()));
    final body = <pw.Widget>[
      _periodHeader('${ctx['title'] ?? 'Lab Report'}', '${ctx['period_label'] ?? ''}', ctx),
      _spacer(8),
      pw.Row(children: [
        pw.Expanded(child: _statCard('إجمالي الفحوصات / Total', '${ctx['total'] ?? 0}', highlighted: true)),
        pw.Expanded(child: _statCard('داخل المدى / In range', '${ctx['in_count'] ?? 0}')),
        pw.Expanded(child: _statCard('خارج المدى / Out of range', '${ctx['out_count'] ?? 0}', highlighted: true)),
        pw.Expanded(child: _statCard('بدون مدى / No range', '${ctx['no_range_count'] ?? 0}')),
        pw.Expanded(child: _statCard('المصادر / Sources', '${ctx['unique_sources'] ?? 0}')),
      ]),
    ];
    final sections = (ctx['sections'] as List?) ?? const [];
    for (final section in sections) {
      final s = section as Map;
      body.add(_spacer(10));
      body.add(_sectionTitle(
          '${s['name']} (${s['type_label']}) — ${s['count']} فحص، خارج المدى ${s['out_count']}'));
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
          pw.Container(
            color: isOut ? _redBg : null,
            child: _txt('${r['result_text'] ?? ''}', size: 7.5, color: isOut ? _red : _ink, bold: isOut),
          ),
          _txt('${r['range_text'] ?? ''}', size: 7.5),
          _txt('${r['tested_by_name'] ?? ''}', size: 7.5),
        ]);
      }
      body.add(_simpleTable(
        ['#', 'التاريخ', 'العينة', 'رقم الدخول', 'التحليل', 'النتيجة', 'المدى', 'الفني'],
        rows,
        const {0: pw.FlexColumnWidth(0.4), 1: pw.FlexColumnWidth(1.2), 2: pw.FlexColumnWidth(1.2), 3: pw.FlexColumnWidth(1.2), 4: pw.FlexColumnWidth(1.5), 5: pw.FlexColumnWidth(1.4), 6: pw.FlexColumnWidth(1.2), 7: pw.FlexColumnWidth(1.2)},
      ));
    }
    body.add(_spacer(8));
    body.add(_txt('انشئ في: ${ctx['generation_time'] ?? ''}', size: 8, color: _muted));

    doc.addPage(pw.MultiPage(pageFormat: _a4(), build: (c) => [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: body)
        ]));
    return doc.save();
  }
}