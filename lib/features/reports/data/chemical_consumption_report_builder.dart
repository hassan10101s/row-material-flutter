import '../../../core/utils/app_dates.dart';
import '../../../core/utils/report_language.dart';
import '../../lab/domain/chemical_consumption_report.dart';

Map<String, dynamic> buildChemicalConsumptionContext(
  ChemicalConsumptionReport report, {
  required Map<String, dynamic> settings,
}) => ReportText.withSettings(
  settings,
  () => {
    'is_en': !ReportText.arabic,
    'title': ReportText.t(
      'تقرير استهلاك الكيماويات',
      'Chemical consumption report',
    ),
    'organization_name': settings['organization_name'] ?? '',
    'department_label': ReportText.department(settings),
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'period': report.period.label,
    'selection': {
      'name': report.inventoryId == null
          ? ReportText.t('كل المواد', 'All chemicals')
          : report.rows.isEmpty
          ? '-'
          : report.rows.first.name,
    },
    'generated_at': nowIso(),
    'chemical_count': report.rows.length,
    'note': ReportText.t(
      'الكميات الفعلية بوحدة مخزون كل مادة. الصافي = المستهلك - المرتجع داخل الفترة. قد يكون الصافي سالبًا عند إرجاع استهلاك من فترة سابقة.',
      'Actual quantities in each chemical\'s stock unit. Net = consumed - returned within the period. Net may be negative when earlier consumption is returned.',
    ),
    'rows': [
      for (final row in report.rows)
        {
          'name': row.name,
          'unit': row.unit,
          'consumed': ChemicalConsumptionRow.quantity(row.consumed),
          'returned': ChemicalConsumptionRow.quantity(row.returned),
          'net': ChemicalConsumptionRow.quantity(row.net),
        },
    ],
  },
);
