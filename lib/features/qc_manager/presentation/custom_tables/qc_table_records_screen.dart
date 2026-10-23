import 'dart:convert' as convert;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_adaptive_list.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../domain/qc_custom_table.dart';
import '../cubit/qc_table_rows_cubit.dart';

/// The records register of one user-authored table: newest first, keyset-
/// paged, filterable in memory (search + per-column bounds). The record
/// form auto-builds from the table's live columns, so a definition edit is
/// the next form the screen shows - no screen changes needed.
///
/// Record listing is the design-system data table (`AppPaginatedTable`):
/// every column of the definition renders as a table column, rows are
/// selectable (hidden checkbox column, long-press a row or tap the header
/// toggle) and the selection exports as an HTML table file. On phones the
/// same register falls back to the card list with the long-press affordance.
class QcTableRecordsScreen extends StatelessWidget {
  const QcTableRecordsScreen._({required this.title, this.asWindow = false});

  /// Page title for the full-screen route (the window draws its own).
  final String title;

  /// Rendered inside the unified [AppWindow] chrome on desktop ([showAppWindow]
  /// hands it over). No Scaffold, no back button: the window's own close
  /// control dismisses the register, the way desktop users expect.
  final bool asWindow;

  /// Opens the register for one table. The cubit and its scope are created
  /// here and never leave the screen ([registerFactoryParam] keyed by
  /// `tableId`); a closed register must not be revisited or leak its rows.
  ///
  /// Desktop: a design-system window ([AppWindow]) — the register closes by
  /// the window's ✕, not by navigating back. Phones keep the full-screen
  /// route with the system back affordance.
  static Future<void> open(BuildContext context, int tableId) {
    if (supportsDataTable) {
      final cubit = getIt<QcTableRowsCubit>(param1: tableId)..load();
      final window = showDialog(
        context: context,
        builder: (_) => BlocProvider<QcTableRowsCubit>.value(
          value: cubit,
          child: Builder(
            builder: (windowContext) {
              final state = windowContext.watch<QcTableRowsCubit>().state;
              return AppWindow(
                title: state.table?.title ??
                    AppText.t('سجل جدول', 'Table register'),
                icon: Icons.table_chart_outlined,
                subtitle: state.table?.description,
                maxWidth: 1150,
                scrollBody: false,
                child: const QcTableRecordsScreen._(title: '', asWindow: true),
              );
            },
          ),
        ),
      );
      return window.whenComplete(() async => cubit.close());
    }
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) {
          return BlocProvider<QcTableRowsCubit>(
            create: (_) => getIt<QcTableRowsCubit>(param1: tableId)..load(),
            child: Builder(
              builder: (context) {
                final state = context.watch<QcTableRowsCubit>().state;
                return QcTableRecordsScreen._(
                  title:
                      state.table?.title ??
                      AppText.t('سجل جدول', 'Table register'),
                );
              },
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chromeless = asWindow;
    final body = SafeArea(
      child: BlocConsumer<QcTableRowsCubit, QcTableRowsState>(
        listenWhen: (prev, curr) =>
            curr.error != null && curr.error != prev.error,
        listener: (context, state) {
          AppFeedback.error(context, state.error!);
          context.read<QcTableRowsCubit>().clearError();
        },
        builder: (context, state) {
          if (state.table == null && state.loading) {
            return const AppSkeletonList(rows: 5);
          }
          return Column(
            children: [
              if (chromeless) _RecordToolbar(state: state),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: AppFilterBar(
                  searchHint: AppText.t('ابحث في السجل', 'Search records'),
                  onSearch: (v) => context
                      .read<QcTableRowsCubit>()
                      .applyFilters(state.filters.copyWith(search: v.trim())),
                  trailing: _ActionBar(state: state),
                ),
              ),
              Expanded(child: _RowsBody()),
            ],
          );
        },
      ),
    );
    if (chromeless) return body;
    return Scaffold(
      appBar: AppTopAppBar(title: title),
      floatingActionButton: BlocBuilder<QcTableRowsCubit, QcTableRowsState>(
        buildWhen: (a, b) => a.fields != b.fields || a.saving != b.saving,
        builder: (context, state) {
          if (state.fields.isEmpty || state.saving) return const SizedBox();
          return FloatingActionButton(
            onPressed: () => _record(context),
            child: Icon(Icons.add, size: 24.r),
          );
        },
      ),
      body: body,
    );
  }

  Future<void> _record(BuildContext context) async {
    final cubit = context.read<QcTableRowsCubit>();
    final ok = await showRecordForm(context, cubit.state);
    if (ok ?? false) await cubit.refresh();
  }

  static Future<void> _openFilters(
    BuildContext context,
    QcTableRowsState state,
  ) async {
    final cubit = context.read<QcTableRowsCubit>();
    final applied = await showModalBottomSheet<QcCustomRowFilters>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _FiltersSheet(fields: state.fields, filters: state.filters),
    );
    if (applied != null && cubit.isClosed == false) {
      cubit.applyFilters(applied);
    }
  }
}

/// The register's window toolbar: a ghost "new record" button on the
/// trailing edge, like the other QC toolbars.
class _RecordToolbar extends StatelessWidget {
  const _RecordToolbar({required this.state});

  final QcTableRowsState state;

  @override
  Widget build(BuildContext context) {
    if (state.fields.isEmpty || state.saving) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          const Spacer(),
          AppButton(
            small: true,
            label: AppText.t('تسجيل جديد', 'New record'),
            icon: Icon(Icons.add, size: 18.r),
            onPressed: () => showRecordForm(context, state),
          ),
        ],
      ),
    );
  }
}

/// The register's action row: the filters toggle plus the table-export
/// button. Export writes the SELECTED rows as a design-system HTML table
/// when anything is picked, otherwise all currently visible ones — so the
/// button works both as a bulk action for the checkbox column and as a
/// one-click "export what I see".
class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.state});

  final QcTableRowsState state;

  @override
  Widget build(BuildContext context) {
    final count = state.selectedIds.length;
    return Wrap(
      // Narrow phones squeeze three actions next to the search field;
      // wrapping keeps the row intact without overflowing.
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (count > 0)
          AppButton(
            small: true,
            style: AppButtonStyle.ghost,
            icon: Icon(Icons.checklist_rounded, size: 18.r),
            label: AppText.t('إلغاء التحديد', 'Clear selection'),
            onPressed: () => context.read<QcTableRowsCubit>().clearSelection(),
          ),
        AppButton(
          small: true,
          style: AppButtonStyle.ghost,
          icon: Icon(Icons.table_view_outlined, size: 18.r),
          label: count > 0
              ? AppText.t('تصدير ($count)', 'Export ($count)')
              : AppText.t('تصدير الجدول', 'Export table'),
          onPressed:
              state.rows.isEmpty ? null : () => exportRowsTable(context),
        ),
        AppButton(
          label: state.filters.activeCount == 0
              ? AppText.t('عوامل التصفية', 'Filters')
              : AppText.t(
                  'عوامل التصفية (${state.filters.activeCount})',
                  'Filters (${state.filters.activeCount})',
                ),
          icon: Icon(Icons.tune, size: 18.r),
          style: AppButtonStyle.ghost,
          small: true,
          onPressed: () => QcTableRecordsScreen._openFilters(context, state),
        ),
      ],
    );
  }
}

/// The register as a design-system HTML table file (`TableHtmlExport`, the
/// same shared export every ledger uses). Selected rows go first — in
/// table order; with nothing picked all currently visible rows export.
Future<void> exportRowsTable(BuildContext context) async {
  final state = context.read<QcTableRowsCubit>().state;
  final table = state.table;
  final visible = state.visibleRows();
  final picked = [
    for (final r in visible) if (state.selectedIds.contains(r.rowId)) r,
  ];
  final rows = picked.isNotEmpty ? picked : visible;
  if (rows.isEmpty) return;
  final fields = state.fields;
  String cell(QcCustomTableField f, QcCustomTableRow r) {
    final v = r.values[f.remoteId];
    if (v == null) return '';
    return f.colType == QcCustomColType.date
        ? ('$v'.length >= 10 ? '$v'.substring(0, 10) : '$v')
        : '$v';
  }

  try {
    await TableHtmlExport.export(
      context,
      filePrefix: 'qc_table',
      title: table?.title ?? AppText.t('سجل جدول', 'Table register'),
      headers: [
        AppText.t('التسجيل', 'Recorded'),
        AppText.t('بواسطة', 'By'),
        ...[for (final f in fields) f.label],
        AppText.t('ملاحظة', 'Note'),
      ],
      rows: [
        for (final r in rows) [
          parseIsoToDisplay(r.recordedAt) ?? r.recordedAt,
          r.recordedByName,
          ...[for (final f in fields) cell(f, r)],
          r.note,
        ],
      ],
    );
  } on AppError catch (e) {
    if (context.mounted) AppFeedback.error(context, e.message);
  } catch (e) {
    if (context.mounted) AppFeedback.errorFrom(context, e);
  }
}

class _RowsBody extends StatelessWidget {
  const _RowsBody();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcTableRowsCubit>();
    return BlocBuilder<QcTableRowsCubit, QcTableRowsState>(
      builder: (context, state) {
        if (state.table == null) {
          return AppEmptyState(
            icon: Icons.table_chart_outlined,
            title:
                state.error ?? AppText.t('الجدول غير موجود', 'Table not found'),
            action: AppButton(
              label: AppText.t('رجوع', 'Back'),
              style: AppButtonStyle.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          );
        }
        if (state.loading && state.rows.isEmpty) {
          return const AppSkeletonList(rows: 5);
        }
        final visible = state.visibleRows();
        if (visible.isEmpty) {
          return AppEmptyState(
            icon: Icons.notes_outlined,
            title: state.filters.isEmpty
                ? AppText.t('لا توجد تسجيلات بعد', 'No records yet')
                : AppText.t(
                    'لا تسجيلات تطابق العوامل',
                    'No records match these filters',
                  ),
            action: state.filters.isEmpty
                ? null
                : AppButton(
                    label: AppText.t('تصفير', 'Clear'),
                    style: AppButtonStyle.secondary,
                    onPressed: () => cubit.clearFilters(),
                  ),
          );
        }
        // Desktop / wide screens: the full design-system data table —
        // every definition column as a column, selection and export.
        if (supportsDataTable) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: _RowsTable(state: state, visible: visible),
          );
        }
        return RefreshIndicator(
          onRefresh: () => cubit.refresh(),
          child: AppInfiniteList(
            itemCount: visible.length,
            hasMore: state.hasMore,
            loadingMore: state.loadingMore,
            onLoadMore: () => cubit.loadMore(),
            itemBuilder: (context, i) => _RecordTile(
              fields: state.fields,
              row: visible[i],
              selected: state.selectedIds.contains(visible[i].rowId),
              onLongPress: () => cubit.toggleSelect(visible[i].rowId!),
              onEdit: () {
                final r = visible[i];
                showRecordForm(context, state, editing: r).then((ok) {
                  if (ok ?? false) cubit.refresh();
                });
              },
              onDelete: () async {
                final r = visible[i];
                final confirmed = await showAppConfirm(
                  context,
                  danger: true,
                  icon: Icons.delete_outline,
                  title: AppText.t('حذف السجل؟', 'Delete record?'),
                  message: AppText.t(
                    'سيحذف هذا التسجيل نهائياً من السجل. لا يمكن التراجع.',
                    'This record will be deleted permanently. '
                        'This cannot be undone.',
                  ),
                  confirmLabel: AppText.t('حذف', 'Delete'),
                  cancelLabel: AppText.t('إلغاء', 'Cancel'),
                );
                if (confirmed == true) await cubit.deleteRow(r.rowId!);
              },
            ),
          ),
        );
      },
    );
  }
}

/// The desktop register body: the whole definition renders as one
/// `AppPaginatedTable` — headers follow the live columns, rows are
/// selectable through the hidden checkbox column (long-press any row or
/// the header toggle reveals it) and the selection drives the export.
///
/// Every row ends with the edit / delete actions (compact icon buttons);
/// edit opens the same record form pre-filled with the row, delete asks
/// through the shared confirm dialog before tombstoning.
class _RowsTable extends StatelessWidget {
  const _RowsTable({required this.state, required this.visible});

  final QcTableRowsState state;
  final List<QcCustomTableRow> visible;

  Future<void> _editRow(BuildContext context, QcCustomTableRow r) async {
    final cubit = context.read<QcTableRowsCubit>();
    final ok = await showRecordForm(context, state, editing: r);
    if (ok ?? false) await cubit.refresh();
  }

  Future<void> _deleteRow(BuildContext context, QcCustomTableRow r) async {
    final cubit = context.read<QcTableRowsCubit>();
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.delete_outline,
      title: AppText.t('حذف السجل؟', 'Delete record?'),
      message: AppText.t(
        'سيحذف هذا التسجيل نهائياً من السجل. لا يمكن التراجع.',
        'This record will be deleted permanently. This cannot be undone.',
      ),
      confirmLabel: AppText.t('حذف', 'Delete'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (confirmed == true) await cubit.deleteRow(r.rowId!);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcTableRowsCubit>();
    final fields = state.fields;
    final ids = [for (final r in visible) r.rowId!];
    final selectedOnRows = ids
        .where(state.selectedIds.contains)
        .length;
    final bool? selectAllValue = ids.isEmpty
        ? false
        : selectedOnRows == 0
            ? false
            : selectedOnRows == ids.length
                ? true
                : null;
    final selectedIndices = <int>{
      for (var i = 0; i < ids.length; i++)
        if (state.selectedIds.contains(ids[i])) i,
    };
    String cellText(QcCustomTableField f, QcCustomTableRow r) {
      final v = r.values[f.remoteId];
      if (v == null) return '';
      return f.colType == QcCustomColType.date
          ? ('$v'.length >= 10 ? '$v'.substring(0, 10) : '$v')
          : '$v';
    }

    Widget actionsCell(QcCustomTableRow r) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: AppText.t('تعديل', 'Edit'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
            onPressed: () => _editRow(context, r),
          ),
          IconButton(
            tooltip: AppText.t('حذف', 'Delete'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
            onPressed: () => _deleteRow(context, r),
          ),
        ],
      );
    }

    return AppPaginatedTable(
      height: null,
      rowsPerPage: 25,
      minTableWidth: 790,
      columnFlex: [
        1.3,
        1.05,
        ...List<double>.filled(fields.length, 1.2),
        1.7,
        0.9,
      ],
      headers: [
        AppText.t('التسجيل', 'Recorded'),
        AppText.t('بواسطة', 'By'),
        ...[for (final f in fields) f.label],
        AppText.t('ملاحظة', 'Note'),
        AppText.t('إجراءات', 'Actions'),
      ],
      rows: [
        for (final r in visible)
          [
            Text(
              parseIsoToDisplay(r.recordedAt) ?? r.recordedAt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
            Text(
              r.recordedByName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
              ),
            ),
            for (final f in fields)
              Text(
                cellText(f, r),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            Text(
              r.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: r.note.isEmpty
                    ? AppColors.textMuted
                    : AppColors.textStrong,
              ),
            ),
            actionsCell(r),
          ],
      ],
      selectedIndices: selectedIndices,
      selectHidden: true,
      onToggleIndex: (index) => cubit.toggleSelect(ids[index]),
      selectAllValue: selectAllValue,
      onToggleAll: (select) =>
          cubit.setAllSelection(ids, select ?? false),
      totalLabel: AppText.t(
        '${visible.length} تسجيل',
        '${visible.length} records',
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.fields,
    required this.row,
    this.selected = false,
    this.onLongPress,
    this.onEdit,
    this.onDelete,
  });

  final List<QcCustomTableField> fields;
  final QcCustomTableRow row;

  /// Bulk-pick affordance for phones (mirrors the desktop checkbox
  /// column): long-press toggles the record into the export selection.
  final bool selected;
  final VoidCallback? onLongPress;

  /// Per-record edit / delete actions, mirroring the desktop table's
  /// trailing action column.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final values = row.values;
    String dayLabel(String iso) =>
        iso.length >= 10 ? iso.substring(0, 10) : iso;
    String timeLabel(String iso) {
      final parsed = DateTime.tryParse(iso);
      return parsed == null
          ? ''
          : TimeOfDay.fromDateTime(parsed).format(context);
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onLongPress: onLongPress,
      color: selected ? AppColors.primary.withValues(alpha: 0.06) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${dayLabel(row.recordedAt)}'
                  '  ${timeLabel(row.recordedAt)}'
                  '${row.recordedByName.isEmpty ? '' : '  ·  ${row.recordedByName}'}',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onEdit != null)
                IconButton(
                  tooltip: AppText.t('تعديل', 'Edit'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: AppColors.primary,
                  ),
                  onPressed: onEdit,
                ),
              if (onDelete != null)
                IconButton(
                  tooltip: AppText.t('حذف', 'Delete'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: AppColors.danger,
                  ),
                  onPressed: onDelete,
                ),
              if (selected)
                Icon(Icons.check_circle, size: 20.r, color: AppColors.primary),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final f in fields)
                if (values[f.remoteId] != null)
                  _ValueChip(field: f, value: values[f.remoteId]),
            ],
          ),
          if (row.note.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              row.note,
              style: TextStyle(fontSize: 13.spMax, color: AppColors.textStrong),
            ),
          ],
        ],
      ),
    );
  }
}

class _ValueChip extends StatelessWidget {
  const _ValueChip({required this.field, required this.value});

  final QcCustomTableField field;
  final Object value;

  @override
  Widget build(BuildContext context) {
    final text = field.colType == QcCustomColType.date
        ? (('$value').length >= 10 ? ('$value').substring(0, 10) : '$value')
        : '$value';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(
        '${field.label}: $text',
        style: TextStyle(
          fontSize: 12.spMax,
          color: AppColors.textStrong,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Per-column filter inputs, one row per column, by its type. Applied only
/// on "apply" so typing never flickers the list behind the bottom sheet.
class _FiltersSheet extends StatefulWidget {
  const _FiltersSheet({required this.fields, required this.filters});

  final List<QcCustomTableField> fields;
  final QcCustomRowFilters filters;

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late final Map<int, TextEditingController> _controllers = _build();

  Map<int, TextEditingController> _build() {
    final out = <int, TextEditingController>{};
    for (final f in widget.fields) {
      final id = f.fieldId;
      if (id != null) out[id] = TextEditingController();
    }
    return out;
  }

  Map<String, TextEditingController> get _byRemote {
    final out = <String, TextEditingController>{};
    for (final f in widget.fields) {
      out[f.remoteId] = _controllers[f.fieldId]!;
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final c = _controllers[f.fieldId]!;
      final filters = widget.filters;
      switch (f.colType) {
        case QcCustomColType.number:
          final minC = TextEditingController(
            text: filters.numberMin[f.remoteId] == null
                ? ''
                : '${filters.numberMin[f.remoteId]}',
          );
          final maxC = TextEditingController(
            text: filters.numberMax[f.remoteId] == null
                ? ''
                : '${filters.numberMax[f.remoteId]}',
          );
          _numberMin[f.remoteId] = minC;
          _numberMax[f.remoteId] = maxC;
        case QcCustomColType.date:
          c.text = filters.dateFrom[f.remoteId] ?? '';
          _dateTo[f.remoteId] = TextEditingController(
            text: filters.dateTo[f.remoteId] ?? '',
          );
        default:
          c.text = filters.textIn[f.remoteId] ?? '';
      }
    }
  }

  final Map<String, TextEditingController> _numberMin = {};
  final Map<String, TextEditingController> _numberMax = {};
  final Map<String, TextEditingController> _dateTo = {};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final c in _numberMin.values) {
      c.dispose();
    }
    for (final c in _numberMax.values) {
      c.dispose();
    }
    for (final c in _dateTo.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    final text = _byRemote;
    final next = QcCustomRowFilters(
      search: widget.filters.search,
      numberMin: {
        for (final e in _numberMin.entries)
          e.key: ?num.tryParse(e.value.text.trim()),
      },
      numberMax: {
        for (final e in _numberMax.entries)
          e.key: ?num.tryParse(e.value.text.trim()),
      },
      dateFrom: {
        for (final e in text.entries)
          if (e.value.text.trim().length >= 10) e.key: e.value.text.trim(),
      },
      dateTo: {
        for (final e in _dateTo.entries)
          if (e.value.text.trim().length >= 10) e.key: e.value.text.trim(),
      },
      textIn: {
        for (final e in text.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
      },
    );
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageMobile),
        // One scroll sheet: every column of the table gets its row(s), so a
        // filter pass covers the whole definition in one gesture.
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                AppText.t('عوامل التصفية', 'Filters'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              for (final f in widget.fields) ...[
                Text(
                  f.label,
                  style: TextStyle(
                    fontSize: 13.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                if (f.colType == QcCustomColType.number)
                  Row(
                    children: [
                      Expanded(
                        child: AppField(
                          label: AppText.t('من (رقم)', 'Min'),
                          controller: _numberMin[f.remoteId]!,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: AppField(
                          label: AppText.t('إلى (رقم)', 'Max'),
                          controller: _numberMax[f.remoteId]!,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  )
                else if (f.colType == QcCustomColType.date)
                  Row(
                    children: [
                      Expanded(
                        child: AppDateField(
                          label: AppText.t('من تاريخ', 'From date'),
                          controller: _controllers[f.fieldId]!,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: AppDateField(
                          label: AppText.t('إلى تاريخ', 'To date'),
                          controller: _dateTo[f.remoteId]!,
                        ),
                      ),
                    ],
                  )
                else
                  AppField(
                    label: AppText.t('يحتوي على', 'Contains'),
                    controller: _controllers[f.fieldId]!,
                  ),
                const SizedBox(height: AppSpacing.md),
              ],
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      style: AppButtonStyle.secondary,
                      label: AppText.t('تصفير', 'Clear'),
                      onPressed: () =>
                          Navigator.of(context).pop(const QcCustomRowFilters()),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppButton(
                      label: AppText.t('تطبيق', 'Apply'),
                      onPressed: _apply,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The record form overlay: one input per live column - number fields take
/// `[FieldType.number]`, text fields free text, date fields
/// `[AppDateField]` - plus an optional note. With [editing] the same form
/// opens pre-filled from that row and saves in place (the «بواسطة» name
/// moves to the editor at that moment); without it, it creates a record.
/// Returns true when a row was written. `showQcTableEditor`-style adaptive:
/// window on desktop, route on phones.
Future<bool?> showRecordForm(
  BuildContext context,
  QcTableRowsState state, {
  QcCustomTableRow? editing,
}) async {
  final table = state.table;
  if (table == null) return false;
  // The overlay is a new Navigator route, so it lives ABOVE the screen's
  // BlocProvider and cannot look the cubit up from its own context. Capture
  // it here (inside the provider scope) and inject it into the form.
  final cubit = context.read<QcTableRowsCubit>();
  final form = _RecordForm(state: state, cubit: cubit, editing: editing);
  final title = editing == null
      ? AppText.t('تسجيل جديد — ${table.title}', 'New record — ${table.title}')
      : AppText.t(
          'تعديل تسجيل — ${table.title}',
          'Edit record — ${table.title}',
        );
  // Fixed-window chrome only where data tables exist at all; phones push a
  // full-screen route instead (the showQcTableEditor split).
  if (supportsDataTable) {
    return await showAppWindow<bool>(
      context,
      title: editing == null
          ? AppText.t('تسجيل جديد', 'New record')
          : AppText.t('تعديل تسجيل', 'Edit record'),
      subtitle: table.title,
      icon: editing == null
          ? Icons.note_add_outlined
          : Icons.edit_note_outlined,
      maxWidth: 620,
      child: form,
    );
  }
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppTopAppBar(title: title),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.pageMobile),
            child: form,
          ),
        ),
      ),
    ),
  );
}

class _RecordForm extends StatefulWidget {
  const _RecordForm({
    required this.state,
    required this.cubit,
    this.editing,
  });

  final QcTableRowsState state;
  final QcTableRowsCubit cubit;

  /// When set, the form edits this record: every column starts pre-filled
  /// from the row and the save goes through `saveRow` instead of `addRow`.
  final QcCustomTableRow? editing;

  @override
  State<_RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends State<_RecordForm> {
  /// `null` renders as an empty field so a missing value starts off blank
  /// rather than as the string "null"; numbers render without a trailing
  /// `.0` when they are whole.
  static String _prefill(Object? v) {
    if (v == null) return '';
    if (v is num) {
      final whole = v.truncateToDouble();
      return v.toDouble() == whole ? '${whole.toInt()}' : '$v';
    }
    return '$v';
  }

  late final Map<int, TextEditingController> _valueInputs = {
    for (final f in widget.state.fields)
      f.fieldId!: TextEditingController(
        text: widget.editing == null
            ? ''
            : _prefill(widget.editing!.values[f.remoteId]),
      ),
  };
  final TextEditingController _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _note.text = widget.editing?.note ?? '';
  }

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _saving = false;

  @override
  void dispose() {
    for (final c in _valueInputs.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  /// Inline validation per column type: required, numeric, ISO date.
  String? _validate(QcCustomTableField f, String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) {
      return f.required
          ? AppText.t('«${f.label}» مطلوب', '"${f.label}" is required')
          : null;
    }
    if (f.colType == QcCustomColType.number &&
        num.tryParse(text.replaceAll(',', '')) == null) {
      return AppText.t('أدخل رقماً صحيحاً', 'Enter a valid number');
    }
    if (f.colType == QcCustomColType.date &&
        (text.length < 10 ||
            DateTime.tryParse(text.substring(0, 10)) == null)) {
      return AppText.t('تاريخ غير صالح', 'Invalid date');
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final values = <String, dynamic>{};
    for (final f in widget.state.fields) {
      final text = _valueInputs[f.fieldId!]!.text.trim();
      if (text.isEmpty) continue;
      values[f.remoteId] = switch (f.colType) {
        QcCustomColType.number => num.tryParse(text.replaceAll(',', '')) ?? text,
        QcCustomColType.date => text.substring(0, 10),
        _ => text,
      };
    }
    setState(() => _saving = true);
    try {
      final table = widget.state.table;
      final editing = widget.editing;
      if (editing != null) {
        final rowId = editing.rowId;
        if (rowId == null || table == null) {
          setState(() => _saving = false);
          return;
        }
        await widget.cubit.saveRow(
          editing.copyWith(
            valuesJson: convert.jsonEncode(values),
            note: _note.text.trim(),
          ),
        );
      } else {
        final row = QcCustomTableRow(
          tableId: table!.tableId,
          tableRemoteId: table.remoteId,
          valuesJson: convert.jsonEncode(values),
          note: _note.text.trim(),
          // The facade stamps actor + times from the live session inside its
          // transaction; nothing here is trusted past the guard.
          recordedAt: DateTime.now().toIso8601String(),
          createdAt: '',
          updatedAt: '',
        );
        await widget.cubit.addRow(row);
      }
      final result = widget.cubit.state;
      if (!mounted) return;
      if (result.saved && result.error == null) {
        Navigator.of(context).pop(true); // the pop is the confirmation
        return;
      }
      setState(() => _saving = false);
      if (result.error != null) {
        AppFeedback.error(context, result.error!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.state.fields;
    final table = widget.state.table;
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FormIntro(
            title: table?.title ?? '',
            description: table?.description ?? '',
            fields: fields.length,
            requiredFields: fields.where((f) => f.required).length,
          ),
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              // Two compact columns on a wide window, one on a phone.
              final twoColumns = constraints.maxWidth >= 430;
              final itemWidth = twoColumns
                  ? (constraints.maxWidth - AppSpacing.md) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  for (var i = 0; i < fields.length; i++)
                    SizedBox(
                      width: itemWidth,
                      child: _buildField(fields[i], i),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          AppField(
            label: AppText.t('ملاحظة (اختياري)', 'Note (optional)'),
            controller: _note,
            maxLines: 2,
            enabled: !_saving,
            hint: AppText.t(
              'أي ملاحظات إضافية عن هذه العينة',
              'Any extra notes about this record',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: AppText.t('حفظ', 'Save'),
                  icon: Icon(Icons.check_rounded, size: 18.r),
                  loading: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              AppButton(
                style: AppButtonStyle.secondary,
                label: AppText.t('إلغاء', 'Cancel'),
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildField(QcCustomTableField f, int index) {
    final controller = _valueInputs[f.fieldId!]!;
    final last = index == widget.state.fields.length - 1;
    if (f.colType == QcCustomColType.date) {
      return AppDateField(
        label: f.label,
        controller: controller,
        enabled: !_saving,
        validator: (v) => _validate(f, v),
      );
    }
    final number = f.colType == QcCustomColType.number;
    return AppField(
      label: number
          ? AppText.t('${f.label} (رقم)', '${f.label} (number)')
          : f.label,
      controller: controller,
      enabled: !_saving,
      keyboardType: number
          ? const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            )
          : null,
      inputFormatters: number
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))]
          : null,
      suffix: Icon(
        number ? Icons.tag : Icons.text_fields_rounded,
        size: 18.r,
        color: AppColors.textMuted,
      ),
      hint: number ? '0.00' : null,
      autofocus: !_saving && index == 0,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: (_) {
        if (last) {
          _save();
        } else {
          FocusScope.of(context).nextFocus();
        }
      },
      validator: (v) => _validate(f, v),
      autovalidateMode: AutovalidateMode.onUserInteraction,
    );
  }
}

/// Small header card that frames the form: the table identity + column counts.
class _FormIntro extends StatelessWidget {
  const _FormIntro({
    required this.title,
    required this.description,
    required this.fields,
    required this.requiredFields,
  });

  final String title;
  final String description;
  final int fields;
  final int requiredFields;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40.r,
            height: 40.r,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            child: Icon(
              Icons.edit_note_rounded,
              color: AppColors.primary,
              size: 22.r,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty
                      ? AppText.t('تسجيل جديد', 'New record')
                      : title,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (description.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _MetaChip(
                      icon: Icons.view_column_outlined,
                      label: AppText.t('$fields عمود', '$fields columns'),
                    ),
                    if (requiredFields > 0)
                      _MetaChip(
                        icon: Icons.star_border_rounded,
                        label: AppText.t(
                          '$requiredFields مطلوب',
                          '$requiredFields required',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: AppColors.borderMuted),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.r, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.spMax,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

