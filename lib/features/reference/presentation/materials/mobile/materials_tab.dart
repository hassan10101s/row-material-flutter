import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
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
import '../../../../lab/domain/lab_result_repository.dart';
import '../../../domain/reference_repository.dart';
import '../../cubit/reference_cubit.dart';
import '../../cubit/reference_state.dart';
import '../desktop/materials_tab.dart' show DesktopMaterialsTab;
import '../../../../../design_system/export/table_html_export.dart';
import 'material_editor.dart';

/// Mobile reference materials list.
///
/// Infinite-scroll over server-paged rows (`ReferenceCubit.loadMore`), with
/// pull-to-refresh, sticky search and `AppCard` tiles. Delete goes through
/// the shared confirmation dialog — the desktop inline "Confirm?" row does
/// not fit beside a title on a 400dp grid.
class MobileMaterialsTab extends StatefulWidget {
  const MobileMaterialsTab({
    super.key,
    required this.refRepo,
    required this.labConfig,
  });

  final ReferenceRepository refRepo;
  final LabConfigurationRepository labConfig;

  @override
  State<MobileMaterialsTab> createState() => _MobileMaterialsTabState();
}

class _MobileMaterialsTabState extends State<MobileMaterialsTab> {
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
      context.read<ReferenceCubit>().setQuery(_searchCtrl.text.trim());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openEditor([int? materialId]) async {
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => MobileMaterialEditor(
          refRepo: widget.refRepo,
          labConfig: widget.labConfig,
          materialId: materialId,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await context.read<ReferenceCubit>().load();
    if (mounted) {
      AppFeedback.success(context, AppText.t('تم الحفظ', 'Saved'));
    }
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> material,
  ) async {
    final id = (material['id'] as num).toInt();
    final name = '${material['material_name'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف المادة', 'Delete material'),
      name: name,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await context.read<ReferenceCubit>().delete(id);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ReferenceCubit>();
    final state = context.watch<ReferenceCubit>().state;
    final rows = state.materials;
    final countLabel = state.hasMore ? '${rows.length}+' : '${rows.length}';
    return AppErrorFeedback<ReferenceCubit, ReferenceState>(
      selector: (s) => s.error,
      // Add floats like the raw-material register (heroTag null: sibling
      // tabs share one IndexedStack).
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: AppText.t('إضافة مادة', 'Add New Material'),
          onPressed: () => _openEditor(),
          child: Icon(Icons.add, size: 24.r),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              title: AppText.t('المواد المرجعية', 'Reference Materials'),
              subtitle: '$countLabel ${AppText.t('مادة', 'materials')}',
              icon: Icons.science_outlined,
              actions: [
                IconButton(
                  tooltip: AppText.t('تصدير جدول', 'Export table'),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: rows.isEmpty
                      ? null
                      : () => TableHtmlExport.export(
                          context,
                          filePrefix: 'materials',
                          title: DesktopMaterialsTab.exportTitle(),
                          headers: DesktopMaterialsTab.exportHeaders(),
                          rows: DesktopMaterialsTab.exportRows(rows),
                        ),
                  icon: const Icon(Icons.table_view_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t(
                'بحث بالاسم أو الكود',
                'Search by name or code...',
              ),
              controller: _searchCtrl,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (state.loading && rows.isNotEmpty) const AppRefreshBar(),
            Expanded(child: _buildBody(context, cubit, state, rows)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ReferenceCubit cubit,
    ReferenceState state,
    List<Map<String, dynamic>> rows,
  ) {
    if (state.loading && rows.isEmpty) {
      return const AppSkeletonList(rows: 6, lines: 3, height: 380);
    }
    if (rows.isEmpty) {
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
              icon: Icons.book_outlined,
              title: state.query.isEmpty
                  ? AppText.t('لا توجد مواد', 'No materials found.')
                  : AppText.t('لا توجد نتائج مطابقة', 'No matching materials.'),
              subtitle: state.query.isEmpty
                  ? AppText.t(
                      'أضف مادة جديدة أو استوردها من Reference.xlsx.',
                      'Add a new material or import from Reference.xlsx.',
                    )
                  : AppText.t('جرّب مسح البحث.', 'Try clearing the search.'),
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
        itemCount: rows.length,
        hasMore: state.hasMore,
        loadingMore: state.loadingMore,
        errorMore: state.errorMore,
        onLoadMore: () => cubit.loadMore(),
        onRetry: () => cubit.loadMore(),
        totalLabel:
            '${rows.length} ${AppText.t('مادة', 'materials')} • ${AppText.t('نهاية القائمة', 'End of list')}',
        itemBuilder: (context, i) => _tile(rows[i]),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> m) {
    final name = '${m['material_name'] ?? ''}';
    final code = '${m['material_code'] ?? ''}';
    final inactive = (m['active'] as num?)?.toInt() == 0;
    final id = (m['id'] as num).toInt();
    return AppCard(
      enableHover: false,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 40.r,
            height: 40.r,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Icon(
              Icons.science_outlined,
              size: 20.r,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
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
                    color: inactive
                        ? AppColors.textMuted
                        : AppColors.textStrong,
                  ),
                ),
                if (code.isNotEmpty)
                  Text(
                    code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                if (inactive)
                  Text(
                    '(${AppText.t('محذوف', 'Deleted')})',
                    style: TextStyle(
                      color: AppColors.danger,
                      fontSize: 12.spMax,
                    ),
                  ),
              ],
            ),
          ),
          // Inactive rows stay read-only, as they do on desktop.
          if (!inactive) ...[
            IconButton(
              tooltip: AppStrings.edit,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => _openEditor(id),
              icon: Icon(Icons.edit_outlined, size: 20.r),
            ),
            IconButton(
              tooltip: AppStrings.delete,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => _delete(context, m),
              icon: Icon(
                Icons.delete_outline,
                size: 20.r,
                color: AppColors.danger,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
