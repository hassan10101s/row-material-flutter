import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';

/// Small list widgets for the analyses tab, composed by both variants.
///
/// The desktop variant composes [AnalysesHeader] + [AnalysesTable] (the
/// pre-split pixels); the mobile variant composes [AnalysesHeader.compact]
/// + [AnalysesCards]. Neither owns data or actions — those stay in the
/// variant so both share the same cubit through the host.

/// Title + add action. Compact stacks a full-width 52h CTA under the title
/// (at 400dp a trailing button shares its row with a long Arabic title).
class AnalysesHeader extends StatelessWidget {
  const AnalysesHeader({super.key, required this.onAdd, this.compact = false});

  final VoidCallback onAdd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      AppText.t('التحليلات', 'Analyses'),
      style: Theme.of(context).textTheme.titleLarge,
    );
    if (!compact) {
      return Row(
        children: [
          title,
          const Spacer(),
          AppButton(
            small: true,
            label: AppText.t('إضافة تحليل', 'Add analysis'),
            icon: Icon(Icons.add, size: 16.r),
            onPressed: onAdd,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: Icon(Icons.add, size: 20.r),
            label: Text(AppText.t('إضافة تحليل', 'Add analysis')),
          ),
        ),
      ],
    );
  }
}

/// Desktop six-column table, verbatim from the pre-split screen.
class AnalysesTable extends StatelessWidget {
  const AnalysesTable({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        child: SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(label: Text(AppText.t('الاسم', 'Name'))),
                DataColumn(label: Text(AppText.t('الوحدة', 'Unit'))),
                DataColumn(
                  label: Text(AppText.t('بارامتر المرجع', 'Reference parameter')),
                ),
                DataColumn(label: Text(AppText.t('المعادلة', 'Formula'))),
                DataColumn(label: Text(AppText.t('المواد', 'Items'))),
                DataColumn(label: Text(AppText.t('الحقول', 'Fields'))),
                DataColumn(label: Text('')),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    cells: [
                      DataCell(
                        Text(
                          '${r['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DataCell(Text('${r['unit'] ?? '%'}')),
                      DataCell(
                        Text(
                          '${r['reference_parameter_name'] ?? '-'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DataCell(
                        Text(
                          '${(r['formula'] is Map ? (r['formula'] as Map)['expression'] : '') ?? ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DataCell(
                        Text('${(r['items'] as List?)?.length ?? 0}'),
                      ),
                      DataCell(
                        Text(
                          (r['dynamic_fields'] as List?)?.join(', ') ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: AppStrings.edit,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onEdit(r),
                              icon: Icon(Icons.edit_outlined, size: 18.r),
                            ),
                            IconButton(
                              tooltip: AppStrings.delete,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onDelete(r),
                              icon: Icon(Icons.delete_outline, size: 18.r),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mobile card list: one card per analysis (a six-column DataTable at
/// 400dp would be a horizontal-scrolling smear).
class AnalysesCards extends StatelessWidget {
  const AnalysesCards({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final r = rows[index];
        return AnalysisCard(
          name: '${r['name']}',
          unit: '${r['unit'] ?? '%'}',
          reference: '${r['reference_parameter_name'] ?? '—'}',
          formula:
              '${(r['formula'] is Map ? (r['formula'] as Map)['expression'] : '') ?? ''}',
          itemsCount: (r['items'] as List?)?.length ?? 0,
          fields: (r['dynamic_fields'] as List?)?.join(', ') ?? '',
          onEdit: () => onEdit(r),
          onDelete: () => onDelete(r),
        );
      },
    );
  }
}

class AnalysisCard extends StatelessWidget {
  const AnalysisCard({
    super.key,
    required this.name,
    required this.unit,
    required this.reference,
    required this.formula,
    required this.itemsCount,
    required this.fields,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String unit;
  final String reference;
  final String formula;
  final int itemsCount;
  final String fields;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.spMax,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textStrong,
                        ),
                      ),
                      Text(
                        '$reference • $unit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                // 48dp is the accessibility floor for a tap target.
                IconButton(
                  tooltip: AppStrings.edit,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: onEdit,
                  icon: Icon(Icons.edit_outlined, size: 20.r),
                ),
                IconButton(
                  tooltip: AppStrings.delete,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, size: 20.r),
                ),
              ],
            ),
            if (formula.isNotEmpty) ...[
              const Divider(height: AppSpacing.lg),
              Text(
                formula,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '$itemsCount ${AppText.t('مواد', 'items')}'
              '${fields.isEmpty ? '' : ' • $fields'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.spMax,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
