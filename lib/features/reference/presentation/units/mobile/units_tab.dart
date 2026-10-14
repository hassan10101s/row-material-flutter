import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../cubit/units_cubit.dart';
import '../../cubit/units_state.dart';
import '../desktop/units_tab.dart' show DesktopUnitsTab;
import '../units_editor.dart';

/// Mobile units settings: searchable infinite cards + full-screen editor.
class MobileUnitsTab extends StatefulWidget {
  const MobileUnitsTab({super.key});

  @override
  State<MobileUnitsTab> createState() => _MobileUnitsTabState();
}

class _MobileUnitsTabState extends State<MobileUnitsTab> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      context.read<UnitsCubit>().setQuery(_searchCtrl.text.trim());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? unit,
  ]) async {
    final cubit = context.read<UnitsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => _UnitEditorRoute(onSubmit: cubit.upsert, unit: unit),
      ),
    );
    if (saved != true || !context.mounted) return;
    await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> unit) async {
    final cubit = context.read<UnitsCubit>();
    final symbol = '${unit['symbol'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الوحدة', 'Delete unit'),
      name: symbol,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await cubit.delete(symbol);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<UnitsCubit>();
    final state = context.watch<UnitsCubit>().state;
    final countLabel = state.hasMore
        ? '${state.rows.length}+'
        : '${state.rows.length}';
    return AppErrorFeedback<UnitsCubit, UnitsState>(
      selector: (s) => s.error,
      // Add floats like the raw-material register (heroTag null: sibling
      // tabs share one IndexedStack).
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: AppText.t('وحدة جديدة', 'New Unit'),
          onPressed: () => _openEditor(context),
          child: Icon(Icons.add, size: 24.r),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              title: AppText.t('إعدادات الوحدات', 'Units Settings'),
              subtitle: '$countLabel ${AppText.t('وحدة', 'units')}',
              icon: Icons.straighten_outlined,
              actions: [
                IconButton(
                  tooltip: AppText.t('تصدير جدول', 'Export table'),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: state.rows.isEmpty
                      ? null
                      : () => TableHtmlExport.export(
                          context,
                          filePrefix: 'units',
                          title: DesktopUnitsTab.exportTitle(),
                          headers: DesktopUnitsTab.exportHeaders(),
                          rows: DesktopUnitsTab.exportRows(
                            state.rows,
                            state.usage,
                          ),
                        ),
                  icon: const Icon(Icons.table_view_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t(
                'بحث بالرمز أو الاسم',
                'Search symbol or name...',
              ),
              controller: _searchCtrl,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
            Expanded(child: _buildBody(context, cubit, state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, UnitsCubit cubit, UnitsState state) {
    if (state.loading && state.rows.isEmpty) {
      return const AppSkeletonList(rows: 6, lines: 3, height: 380);
    }
    if (state.rows.isEmpty) {
      if (state.error != null) {
        return RefreshIndicator(
          onRefresh: () => cubit.refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              AppErrorState(
                title: AppText.t('تعذّر التحميل', 'Could not load'),
                subtitle: state.error,
                onRetry: () => cubit.refresh(),
              ),
            ],
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: () => cubit.refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AppEmptyState(
              icon: Icons.straighten_outlined,
              title: state.query.isEmpty
                  ? AppText.t('لا توجد وحدات.', 'No units found.')
                  : AppText.t('لا توجد نتائج مطابقة', 'No matching units.'),
              subtitle: state.query.isEmpty
                  ? AppText.t(
                      'أضف وحدات مثل % و mg/kg و ppm.',
                      'Add units like %, mg/kg, ppm.',
                    )
                  : null,
              action: state.query.isEmpty
                  ? null
                  : AppButton(
                      style: AppButtonStyle.secondary,
                      label: AppText.t('مسح البحث', 'Clear search'),
                      onPressed: () {
                        _searchCtrl.clear();
                        cubit.setQuery('');
                      },
                    ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => cubit.refresh(),
      child: AppInfiniteList(
        itemCount: state.rows.length,
        hasMore: state.hasMore,
        loadingMore: state.loadingMore,
        errorMore: state.errorMore,
        onLoadMore: () => cubit.loadMore(),
        onRetry: () => cubit.loadMore(),
        totalLabel:
            '${state.rows.length} ${AppText.t('وحدة', 'units')} • ${AppText.t('نهاية القائمة', 'End of list')}',
        itemBuilder: (context, index) {
          final u = state.rows[index];
          return _UnitCard(
            symbol: '${u['symbol'] ?? ''}',
            name: '${u['name'] ?? '-'}',
            dimension: '${u['dimension'] ?? '-'}',
            usage: state.usage['${u['symbol'] ?? ''}'] ?? 0,
            onEdit: () => _openEditor(context, u),
            onDelete: () => _delete(context, u),
          );
        },
      ),
    );
  }
}

/// One unit as a card. The dimension line is omitted rather than shown as a
/// bare dash when unset, so an ungrouped unit does not read as a placeholder
/// the user should fill in.
class _UnitCard extends StatelessWidget {
  const _UnitCard({
    required this.symbol,
    required this.name,
    required this.dimension,
    this.usage = 0,
    required this.onEdit,
    required this.onDelete,
  });

  final String symbol;
  final String name;
  final String dimension;
  final int usage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      enableHover: false,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  symbol,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
                if (name.isNotEmpty && name != '-')
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                if (dimension.isNotEmpty && dimension != '-')
                  Text(
                    dimension,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                Text(
                  AppText.t('مستخدمة في $usage', 'Used in $usage'),
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: usage > 0 ? AppColors.success : AppColors.textMuted,
                    fontWeight: FontWeight.w600,
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
    );
  }
}

/// The editor as a full-screen route.
class _UnitEditorRoute extends StatelessWidget {
  const _UnitEditorRoute({required this.onSubmit, this.unit});

  final Future<void> Function(String symbol, {String name, String dimension})
  onSubmit;

  final Map<String, dynamic>? unit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(unitsEditorTitle(unit == null))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: UnitsEditor(
            onSubmit: onSubmit,
            unit: unit,
            actions: (_, state) => UnitsEditorActions(state: state),
          ),
        ),
      ),
    );
  }
}
