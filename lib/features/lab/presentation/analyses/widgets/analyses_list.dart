import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/export/table_html_export.dart';

/// Small list widgets for the analyses tab, composed by both variants.
///
/// The desktop variant composes [AnalysesHeader] + [AnalysesTable] (the
/// pre-split pixels); the mobile variant composes [AnalysesHeader.compact]
/// + [AnalysesCards]. Neither owns data or actions — those stay in the
/// variant so both share the same cubit through the host.

/// Title + add action. Compact stacks a full-width 52h CTA under the title
/// (at 400dp a trailing button shares its row with a long Arabic title).
class AnalysesHeader extends StatelessWidget {
  const AnalysesHeader({
    super.key,
    required this.onAdd,
    this.compact = false,
    this.onExportTable,
    this.canExport = false,
    this.search,
  });

  final VoidCallback onAdd;
  final bool compact;

  /// Export-all action (HTML table file). Shown when [canExport] is true.
  final VoidCallback? onExportTable;
  final bool canExport;

  /// Optional search field for the desktop layout: it shares the actions row
  /// so the table gets a search box without spending an extra row. The mobile
  /// layout renders its own search above the cards and leaves this null.
  final Widget? search;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      AppText.t('التحاليل', 'Analyses'),
      style: Theme.of(context).textTheme.titleLarge,
    );
    final exportButton = canExport
        ? IconButton(
            tooltip: AppText.t('تصدير جدول', 'Export table'),
            visualDensity: VisualDensity.compact,
            onPressed: onExportTable,
            icon: Icon(Icons.table_view_outlined, size: 20.r),
          )
        : const SizedBox.shrink();
    if (!compact) {
      // Desktop title lives in the shell topbar; the search takes the free
      // width and the actions stay on the same row (no wasted vertical space).
      return Row(
        children: [
          Expanded(child: search ?? const SizedBox.shrink()),
          const SizedBox(width: AppSpacing.sm),
          exportButton,
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
        Row(
          children: [
            Expanded(child: title),
            exportButton,
          ],
        ),
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
class AnalysesTable extends StatefulWidget {
  const AnalysesTable({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onDelete;

  /// Export mapping shared by the desktop table and the mobile cards.
  static List<String> exportHeaders() => [
    AppText.t('الاسم', 'Name'),
    AppText.t('الوحدة', 'Unit'),
    AppText.t('المواد', 'Items'),
    AppText.t('الحقول', 'Fields'),
  ];

  static List<List<String>> exportRows(List<Map<String, dynamic>> rows) => [
    for (final r in rows)
      [
        '${r['name']}',
        '${r['unit'] ?? '%'}',
        '${(r['items'] as List?)?.length ?? 0}',
        (r['dynamic_fields'] as List?)?.join(', ') ?? '',
      ],
  ];

  static String exportTitle() => AppText.t('التحليلات', 'Analyses');

  @override
  State<AnalysesTable> createState() => _AnalysesTableState();
}

class _AnalysesTableState extends State<AnalysesTable> {
  /// Table indices picked with the checkbox column (same idea every table).
  final Set<int> _selected = <int>{};

  Future<void> _exportSelected() async {
    final picked = [
      for (var i = 0; i < widget.rows.length; i++)
        if (_selected.contains(i)) widget.rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'analyses',
      title: AnalysesTable.exportTitle(),
      headers: AnalysesTable.exportHeaders(),
      rows: AnalysesTable.exportRows(picked),
    );
    if (mounted && picked.isNotEmpty) {
      setState(_selected.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_selected.isNotEmpty) ...[
          TableSelectionBar(
            selectedCount: _selected.length,
            onExportTable: _exportSelected,
            onClear: () => setState(_selected.clear),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        Expanded(
          child: AppPaginatedTable(
            height: null,
            minTableWidth: 720,
            columnFlex: const [1.2, 0.6, 0.6, 1.4, 0.8],
            headers: [...AnalysesTable.exportHeaders(), ''],
            rows: [
              for (final r in rows)
                [
                  Text(
                    '${r['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text('${r['unit'] ?? '%'}'),
                  Text('${(r['items'] as List?)?.length ?? 0}'),
                  Text(
                    (r['dynamic_fields'] as List?)?.join(', ') ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: AppStrings.edit,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onEdit(r),
                        icon: Icon(Icons.edit_outlined, size: 18.r),
                      ),
                      IconButton(
                        tooltip: AppStrings.delete,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onDelete(r),
                        icon: Icon(Icons.delete_outline, size: 18.r),
                      ),
                    ],
                  ),
                ],
            ],
            selectedIndices: _selected,
            selectHidden: true,
            onToggleIndex: (i) => setState(() {
              if (!_selected.remove(i)) _selected.add(i);
            }),
            selectAllValue: _selected.isEmpty
                ? false
                : _selected.length >= rows.length
                ? true
                : null,
            onToggleAll: (_) => setState(() {
              if (_selected.length >= rows.length) {
                _selected.clear();
              } else {
                _selected.addAll(List.generate(rows.length, (i) => i));
              }
            }),
          ),
        ),
      ],
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
    return AppCard(
      enableHover: false,
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
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined, size: 20.r),
              ),
              IconButton(
                tooltip: AppStrings.delete,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
