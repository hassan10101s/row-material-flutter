import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../analysis_editor.dart';
import '../../cubit/analyses_cubit.dart';
import '../../cubit/analyses_state.dart';
import '../widgets/analyses_list.dart';

/// Mobile analyses: searchable infinite cards + full-screen editor.
class MobileAnalysesTab extends StatefulWidget {
  const MobileAnalysesTab({super.key});

  @override
  State<MobileAnalysesTab> createState() => _MobileAnalysesTabState();
}

class _MobileAnalysesTabState extends State<MobileAnalysesTab> {
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
      context.read<AnalysesCubit>().setQuery(_searchCtrl.text.trim());
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
    Map<String, dynamic>? analysis,
  ]) async {
    final cubit = context.read<AnalysesCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        // Captured here, not read inside the route: a pushed route builds
        // under the root navigator, above this provider.
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: _AnalysisEditorRoute(analysis: analysis),
        ),
      ),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> analysis,
  ) async {
    final cubit = context.read<AnalysesCubit>();
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('حذف التحليل', 'Delete analysis'),
      message: '${AppText.t('حذف', 'Delete')} "${analysis['name']}"؟',
      danger: true,
      confirmLabel: AppStrings.delete,
      cancelLabel: AppStrings.cancel,
    );
    if (confirmed != true) return;
    try {
      await cubit.delete((analysis['id'] as num).toInt());
      if (!context.mounted) return;
      AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<AnalysesCubit>();
    final state = context.watch<AnalysesCubit>().state;
    final countLabel = state.hasMore
        ? '${state.rows.length}+'
        : '${state.rows.length}';
    return AppErrorFeedback<AnalysesCubit, AnalysesState>(
      selector: (s) => s.error,
      // Add floats like the raw-material register (heroTag null: sibling
      // lab tabs share one IndexedStack).
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: AppText.t('إضافة تحليل', 'Add analysis'),
          onPressed: () => _openEditor(context),
          child: Icon(Icons.add, size: 24.r),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              title: AppText.t('التحاليل', 'Analyses'),
              subtitle: '$countLabel ${AppText.t('تحليل', 'analyses')}',
              icon: Icons.biotech_outlined,
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
                          filePrefix: 'analyses',
                          title: AnalysesTable.exportTitle(),
                          headers: AnalysesTable.exportHeaders(),
                          rows: AnalysesTable.exportRows(state.rows),
                        ),
                  icon: const Icon(Icons.table_view_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t('بحث بالاسم', 'Search by name...'),
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
    AnalysesCubit cubit,
    AnalysesState state,
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
              icon: Icons.biotech_outlined,
              title: state.query.isEmpty
                  ? AppText.t('لا توجد تحليلات', 'No analyses')
                  : AppText.t('لا توجد نتائج مطابقة', 'No matching analyses.'),
              subtitle: state.query.isEmpty
                  ? AppText.t(
                      'أضف أول تحليل للبدء.',
                      'Add your first analysis.',
                    )
                  : null,
              action: state.query.isEmpty
                  ? null
                  : AppButton(
                      label: AppText.t('مسح البحث', 'Clear search'),
                      style: AppButtonStyle.secondary,
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
            '${state.rows.length} ${AppText.t('تحليل', 'analyses')} • ${AppText.t('نهاية القائمة', 'End of list')}',
        itemBuilder: (context, index) {
          final r = state.rows[index];
          return AnalysisCard(
            name: '${r['name']}',
            unit: '${r['unit'] ?? '%'}',
            reference: '${r['reference_parameter_name'] ?? '—'}',
            formula:
                '${(r['formula'] is Map ? (r['formula'] as Map)['expression'] : '') ?? ''}',
            itemsCount: (r['items'] as List?)?.length ?? 0,
            fields: (r['dynamic_fields'] as List?)?.join(', ') ?? '',
            onEdit: () => _openEditor(context, r),
            onDelete: () => _delete(context, r),
          );
        },
      ),
    );
  }
}

/// Full-screen editor route: same form, phone chrome.
class _AnalysisEditorRoute extends StatefulWidget {
  const _AnalysisEditorRoute({this.analysis});
  final Map<String, dynamic>? analysis;

  @override
  State<_AnalysisEditorRoute> createState() => _AnalysisEditorRouteState();
}

class _AnalysisEditorRouteState extends State<_AnalysisEditorRoute> {
  final _key = GlobalKey<AnalysisEditorState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.analysis == null
              ? AppText.t('إضافة تحليل', 'Add analysis')
              : AppText.t('تعديل تحليل', 'Edit analysis'),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: AnalysisEditor(key: _key, analysis: widget.analysis),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.pageMobile),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: AppButton(
                        label: AppText.t('إلغاء', 'Cancel'),
                        style: AppButtonStyle.secondary,
                        expanded: true,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      // Rebuilt per-frame via the key lookup below: the save
                      // button enables as soon as the form state exists.
                      child: AppButton(
                        label: AppText.t('حفظ', 'Save'),
                        expanded: true,
                        onPressed: () => _key.currentState?.save(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
