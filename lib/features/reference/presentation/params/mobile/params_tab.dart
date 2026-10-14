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
import '../../cubit/params_cubit.dart';
import '../../cubit/params_state.dart';
import '../desktop/params_tab.dart' show DesktopParamsTab;
import '../params_editor.dart';

/// Mobile parameter management: searchable infinite cards, full-screen editor.
class MobileParamsTab extends StatefulWidget {
  const MobileParamsTab({super.key, required this.parameterType});

  final String parameterType;

  @override
  State<MobileParamsTab> createState() => _MobileParamsTabState();
}

class _MobileParamsTabState extends State<MobileParamsTab> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  bool get _isChemical => widget.parameterType == 'chemical';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      context.read<ParamsCubit>().setQuery(_searchCtrl.text.trim());
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
    Map<String, dynamic>? param,
  ]) async {
    final cubit = context.read<ParamsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => _ParamEditorRoute(
          parameterType: widget.parameterType,
          param: param,
          onSubmit: cubit.upsert,
          unitOptions: cubit.state.units,
        ),
      ),
    );
    if (saved != true || !context.mounted) return;
    await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> param) async {
    final cubit = context.read<ParamsCubit>();
    final name = '${param['parameter_name'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف البارامتر', 'Delete parameter'),
      name: name,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await cubit.delete(name);
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
    final cubit = context.read<ParamsCubit>();
    final state = context.watch<ParamsCubit>().state;
    final countLabel = state.hasMore
        ? '${state.rows.length}+'
        : '${state.rows.length}';
    return AppErrorFeedback<ParamsCubit, ParamsState>(
      selector: (s) => s.error,
      // Add floats like the raw-material register (heroTag null: sibling
      // tabs share one IndexedStack).
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: AppText.t('بارامتر جديد', 'New Parameter'),
          onPressed: () => _openEditor(context),
          child: Icon(Icons.add, size: 24.r),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              title: _isChemical
                  ? AppText.t('التحليل الكيميائي', 'Chemical Analysis')
                  : AppText.t('الفحص الظاهري', 'Physical Aspects'),
              subtitle: '$countLabel ${AppText.t('بارامتر', 'parameters')}',
              icon: Icons.tag_outlined,
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
                          filePrefix: 'params',
                          title: _isChemical
                              ? AppText.t(
                                  'التحليل الكيميائي',
                                  'Parameter Chemical Analysis',
                                )
                              : AppText.t('الفحص الظاهري', 'Physical Aspects'),
                          headers: DesktopParamsTab.exportHeaders(),
                          rows: DesktopParamsTab.exportRows(state.rows),
                        ),
                  icon: const Icon(Icons.table_view_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t(
                'بحث بالاسم أو الوحدة',
                'Search name or unit...',
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

  Widget _buildBody(
    BuildContext context,
    ParamsCubit cubit,
    ParamsState state,
  ) {
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
              icon: Icons.tag_outlined,
              title: state.query.isEmpty
                  ? (_isChemical
                        ? AppText.t(
                            'لا توجد بارامترات كيميائية.',
                            'No chemical parameters.',
                          )
                        : AppText.t(
                            'لا توجد بارامترات ظاهرية.',
                            'No physical parameters.',
                          ))
                  : AppText.t(
                      'لا توجد نتائج مطابقة',
                      'No matching parameters.',
                    ),
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
            '${state.rows.length} ${AppText.t('بارامتر', 'parameters')} • ${AppText.t('نهاية القائمة', 'End of list')}',
        itemBuilder: (context, index) {
          final p = state.rows[index];
          return _ParamCard(
            name: '${p['parameter_name'] ?? ''}',
            unit: '${p['unit'] ?? ''}',
            onEdit: () => _openEditor(context, p),
            onDelete: () => _delete(context, p),
          );
        },
      ),
    );
  }
}

/// One parameter and its canonical unit as a card.
class _ParamCard extends StatelessWidget {
  const _ParamCard({
    required this.name,
    required this.unit,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String? unit;
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
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
                if (unit != null && unit!.isNotEmpty)
                  Text(
                    unit!,
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
    );
  }
}

/// The editor as a full-screen route.
class _ParamEditorRoute extends StatelessWidget {
  const _ParamEditorRoute({
    required this.parameterType,
    required this.onSubmit,
    this.unitOptions,
    this.param,
  });

  final String parameterType;
  final Future<void> Function(String name, String unit) onSubmit;

  /// Known unit symbols, offered as a shortcut for chemical rows.
  final List<Map<String, dynamic>>? unitOptions;
  final Map<String, dynamic>? param;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(paramEditorTitle(parameterType, param == null)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ParamEditor(
            parameterType: parameterType,
            onSubmit: onSubmit,
            param: param,
            unitOptions: parameterType == 'chemical' ? unitOptions : null,
            actions: (_, state) => ParamEditorActions(state: state),
          ),
        ),
      ),
    );
  }
}
