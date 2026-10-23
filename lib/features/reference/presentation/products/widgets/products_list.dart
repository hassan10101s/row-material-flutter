import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_format.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/export/table_html_export.dart';

/// Small list widgets for the products tab, composed by both variants.

class ProductsHeader extends StatelessWidget {
  const ProductsHeader({
    super.key,
    required this.onAdd,
    this.compact = false,
    this.onExportTable,
    this.canExport = false,
    this.subtitle,
    this.showAdd = true,
  });

  final VoidCallback onAdd;
  final bool compact;

  /// Mobile hides the inline add button: adding floats (FAB) like the
  /// raw-material register instead of blocking the top of the screen.
  final bool showAdd;

  /// Mobile-only count line under the title (desktop keeps title-only).
  final String? subtitle;

  /// Export-all action (HTML table file). Shown when [canExport] is true.
  final VoidCallback? onExportTable;
  final bool canExport;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      AppText.t('المنتجات', 'Products'),
      style: Theme.of(context).textTheme.titleLarge,
    );
    final exportButton = canExport
        ? IconButton(
            tooltip: AppText.t('تصدير جدول', 'Export table'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onExportTable,
            icon: Icon(Icons.table_view_outlined, size: 20.r),
          )
        : const SizedBox.shrink();
    if (!compact) {
      // Desktop title lives in the shell topbar; only actions stay.
      return Row(
        children: [
          const Spacer(),
          exportButton,
          AppButton(
            small: true,
            icon: Icon(Icons.add, size: 16.r),
            label: AppText.t('منتج جديد', 'New Product'),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  title,
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
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
            exportButton,
          ],
        ),
        if (showAdd) ...[
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onAdd,
              icon: Icon(Icons.add, size: 20.r),
              label: Text(AppText.t('منتج جديد', 'New Product')),
            ),
          ),
        ],
      ],
    );
  }
}

/// Desktop: one reference table, matching the raw-material register. Ranges
/// live in the same row as the product instead of a second detached card.
class ProductsTable extends StatefulWidget {
  const ProductsTable({
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
    AppText.t('المنتج', 'Product'),
    AppText.t('النوع', 'Category'),
    AppText.t('الوصف', 'Description'),
  ];

  static List<List<String>> exportRows(List<Map<String, dynamic>> rows) => [
    for (final p in rows)
      [
        '${p['name'] ?? ''}',
        '${p['category'] ?? '-'}',
        '${p['description'] ?? '-'}',
      ],
  ];

  static String exportTitle() => AppText.t('المنتجات', 'Products');

  @override
  State<ProductsTable> createState() => _ProductsTableState();
}

class _ProductsTableState extends State<ProductsTable> {
  /// Table indices picked with the checkbox column (same idea every table).
  final Set<int> _selected = <int>{};

  Future<void> _exportSelected() async {
    final picked = [
      for (var i = 0; i < widget.rows.length; i++)
        if (_selected.contains(i)) widget.rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'products',
      title: ProductsTable.exportTitle(),
      headers: ProductsTable.exportHeaders(),
      rows: ProductsTable.exportRows(picked),
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
            // The parent supplies a loose Flexible constraint; a concrete height
            // keeps the table's internal body Expanded bounded.
            height: 520,
            minTableWidth: 760,
            columnFlex: const [1.2, 0.9, 2.4, 1.0],
            headers: [
              ...ProductsTable.exportHeaders(),
              AppText.t('الإجراءات', 'Actions'),
            ],
            rows: [
              for (final p in rows)
                [
                  Text(
                    '${p['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${p['category'] ?? '-'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${p['description'] ?? '-'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: AppStrings.edit,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onEdit(p),
                        icon: Icon(Icons.edit_outlined, size: 18.r),
                      ),
                      IconButton(
                        tooltip: AppStrings.delete,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onDelete(p),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 18.r,
                          color: AppColors.danger,
                        ),
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

/// Analysis-range chips, shared by the desktop ranges card and mobile cards.
class RangesChips extends StatelessWidget {
  const RangesChips(this.ranges, {super.key});

  final List<dynamic> ranges;

  @override
  Widget build(BuildContext context) {
    if (ranges.isEmpty) return const Text('—');
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final r in ranges)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderMuted),
            ),
            child: Text(
              '${r['analysis_name'] ?? ''}: '
              '${r['min_value'] ?? '-'} - ${r['max_value'] ?? '-'} '
              '${r['unit'] ?? ''}',
              style: TextStyle(fontSize: 12.spMax),
            ),
          ),
      ],
    );
  }
}

/// Reference chips for one product: physical + chemical entries from the
/// reference maps (مطلوب entries get a check), falling back to the legacy
/// ranges table for products saved before the reference editor.
class ProductRefChips extends StatelessWidget {
  const ProductRefChips(this.product, {super.key, this.compact = false});

  final Map<String, dynamic> product;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final physical = product['physical_reference'] is Map
        ? Map<String, dynamic>.from(product['physical_reference'] as Map)
        : <String, dynamic>{};
    final chemical = product['chemical_reference'] is Map
        ? Map<String, dynamic>.from(product['chemical_reference'] as Map)
        : <String, dynamic>{};
    if (physical.isEmpty && chemical.isEmpty) {
      return RangesChips(product['ranges'] as List? ?? []);
    }
    if (compact) {
      return SizedBox(
        height: 40,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              if (physical.isNotEmpty)
                _compactSection(AppText.t('ف', 'P'), physical),
              if (physical.isNotEmpty && chemical.isNotEmpty)
                const SizedBox(width: 8),
              if (chemical.isNotEmpty)
                _compactSection(AppText.t('ك', 'C'), chemical),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _refSection(AppText.t('الفحص الظاهري', 'Physical'), physical),
        _refSection(AppText.t('التحليل الكيميائي', 'Chemical'), chemical),
      ],
    );
  }

  Widget _compactSection(String title, Map<String, dynamic> map) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$title: ',
          style: TextStyle(
            fontSize: 11.spMax,
            color: AppColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final e in map.entries) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: isReferenceRequired(e.value)
                  ? AppColors.primary.withValues(alpha: 0.10)
                  : AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isReferenceRequired(e.value)
                    ? AppColors.primary.withValues(alpha: 0.4)
                    : AppColors.borderMuted,
              ),
            ),
            child: Text(
              '${isReferenceRequired(e.value) ? '✓ ' : ''}${e.key}: ${referenceValueText(e.value)}',
              style: TextStyle(fontSize: 11.spMax),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ],
    );
  }

  Widget _refSection(String title, Map<String, dynamic> map) {
    if (map.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12.spMax,
            color: AppColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final e in map.entries)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isReferenceRequired(e.value)
                      ? AppColors.primary.withValues(alpha: 0.10)
                      : AppColors.surfaceSoft,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isReferenceRequired(e.value)
                        ? AppColors.primary.withValues(alpha: 0.4)
                        : AppColors.borderMuted,
                  ),
                ),
                child: Text(
                  '${isReferenceRequired(e.value) ? '✓ ' : ''}${e.key}: '
                  '${referenceValueText(e.value)}',
                  style: TextStyle(fontSize: 12.spMax),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Mobile card list: product + ranges inline (no table, no split panes).
class ProductsCards extends StatelessWidget {
  const ProductsCards({
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
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, index) {
        final p = rows[index];
        return ProductCard(
          name: '${p['name'] ?? ''}',
          category: '${p['category'] ?? '-'}',
          description: '${p['description'] ?? '-'}',
          product: p,
          onEdit: () => onEdit(p),
          onDelete: () => onDelete(p),
        );
      },
    );
  }
}

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.name,
    required this.category,
    required this.description,
    required this.product,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String category;
  final String description;
  final Map<String, dynamic> product;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
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
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '$category • $description',
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
                icon: Icon(
                  Icons.delete_outline,
                  size: 20.r,
                  color: AppColors.danger,
                ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.lg),
          ProductRefChips(product),
        ],
      ),
    );
  }
}
