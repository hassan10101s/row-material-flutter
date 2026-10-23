import 'package:flutter/material.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../domain/qc_inspection.dart';
import '../../domain/qc_sop.dart';
import '../../domain/qc_template.dart';

/// HTML table exports for the QC card registers (inspections / SOPs /
/// templates). These screens are card lists, not `AppPaginatedTable`s, so
/// they cannot reuse the table's selection bar — but the exported file is the
/// same shared HTML table document every other register produces.
class RegisterExports {
  RegisterExports._();

  static Future<void> inspections(
    BuildContext context,
    List<QcInspection> rows,
  ) => TableHtmlExport.export(
    context,
    filePrefix: 'qc_inspections',
    title: AppText.t('فحوصات الجودة', 'Quality inspections'),
    headers: [
      AppText.t('الرقم', 'ID'),
      AppText.t('المرجع', 'Ref'),
      AppText.t('المخزون', 'Lot / batch'),
      AppText.t('القسم', 'Dept'),
      AppText.t('الفاحص', 'Inspector'),
      AppText.t('التاريخ', 'Date'),
      AppText.t('الحالة', 'Status'),
      AppText.t('النتيجة', 'Result'),
    ],
    rows: [
      for (final i in rows)
        [
          '${i.inspectionId ?? '-'}',
          i.refId.isEmpty ? i.refType : i.refId,
          i.lotNo.isNotEmpty
              ? i.lotNo
              : i.batchNo.isNotEmpty
              ? i.batchNo
              : '—',
          i.dept,
          i.inspectorName.isEmpty ? '—' : i.inspectorName,
          i.inspectionDate.isEmpty ? '-' : i.inspectionDate.substring(0, 10),
          i.status,
          i.resultOverall.isEmpty ? '-' : i.resultOverall,
        ],
    ],
  );

  static Future<void> sops(BuildContext context, List<QcSop> rows) =>
      TableHtmlExport.export(
        context,
        filePrefix: 'qc_sops',
        title: AppText.t('إجراءات التشغيل', 'SOPs'),
        headers: [
          AppText.t('الكود', 'Code'),
          AppText.t('العنوان', 'Title'),
          AppText.t('التصنيف', 'Category'),
          AppText.t('القسم', 'Dept'),
          AppText.t('الحالة', 'Status'),
          AppText.t('المراجعة', 'Rev'),
          AppText.t('السريان', 'Effective'),
        ],
        rows: [
          for (final s in rows)
            [
              s.code.isEmpty ? '-' : s.code,
              s.title,
              s.category,
              s.dept,
              s.status,
              '${s.revNo}',
              s.effectiveDate,
            ],
        ],
      );

  static Future<void> templates(BuildContext context, List<QcTemplate> rows) =>
      TableHtmlExport.export(
        context,
        filePrefix: 'qc_templates',
        title: AppText.t('قوائم الفحص', 'Checklist templates'),
        headers: [
          AppText.t('الاسم', 'Name'),
          AppText.t('الكود', 'Code'),
          AppText.t('النوع', 'Type'),
          AppText.t('القسم', 'Dept'),
          AppText.t('الإصدار', 'Version'),
          AppText.t('منشور', 'Published'),
        ],
        rows: [
          for (final t in rows)
            [
              t.name,
              t.code.isEmpty ? '-' : t.code,
              t.type,
              t.dept,
              '${t.version}',
              t.isPublished ? AppText.t('نعم', 'Yes') : AppText.t('لا', 'No'),
            ],
        ],
      );
}
