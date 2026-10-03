import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/feedback/app_error_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_breakpoints.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_skeleton.dart';
import '../../../di/service_locator.dart';
import '../core/test_history_logic.dart';
import '../domain/lab_local_repository.dart';
import '../domain/lab_result_repository.dart';
import 'cubit/run_test_cubit.dart';
import 'cubit/test_history_cubit.dart';
import 'cubit/test_history_state.dart';
import 'run_test_tab.dart';

/// Sample-tests history tab (port of Web TestHistoryPanel): search, period /
/// analysis / source / chemical / range-state filters, chips, stats, sortable
/// columns and pagination. Reloads whenever [refreshTick] changes.
class TestHistoryTab extends StatefulWidget {
  final int refreshTick;
  const TestHistoryTab({super.key, this.refreshTick = 0});
  @override
  State<TestHistoryTab> createState() => _TestHistoryTabState();
}

class _TestHistoryTabState extends State<TestHistoryTab> {
  final _query = TextEditingController();
  String _filterMode = 'last24h';
  String _specificDate = '';
  String _recordLimit = '100';
  String _analysisId = '';
  String _sourceType = '';
  String _chemicalId = '';
  String _rangeState = '';
  int _page = 1;
  String _sortKey = 'tested_at';
  int _sortDir = -1;

  static const _recordLimits = ['50', '100', '300', '500', '1000', '5000'];

  @override
  void initState() {
    super.initState();
    context.read<TestHistoryCubit>().load();
  }

  @override
  void didUpdateWidget(covariant TestHistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      context.read<TestHistoryCubit>().load();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _resetPage() => _page = 1;

  void _setSort(String key) {
    setState(() {
      final next = thNextSort(key, _sortKey, _sortDir);
      _sortKey = next.key;
      _sortDir = next.dir;
    });
  }

  Future<void> _openNewTest() async {
    await showDialog<void>(
      context: context,
      // Windows-like overlay: a large non-fullscreen surface floating over the
      // app; tapping outside (or pressing the close button) returns to the main
      // page. barrierDismissible is true by default.
      builder: (dialogContext) => BlocProvider(
        create: (_) => RunTestCubit(
          config: getIt<LabConfigurationRepository>(),
          results: getIt<LabResultRepository>(),
          local: getIt<LabLocalRepository>(),
        )..load(),
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 48,
            vertical: 32,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 780),
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSoft,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                    border: Border(
                      bottom: BorderSide(color: AppColors.borderMuted),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.science_outlined,
                        size: 20.r,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppText.t('اختبار جديد', 'New Test'),
                        style: TextStyle(
                          fontSize: 16.spMax,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: AppText.t('إغلاق', 'Close'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 920),
                        child: RunTestTab(onTestRun: () {}),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) context.read<TestHistoryCubit>().load();
  }

  void _clearAllFilters() {
    setState(() {
      _filterMode = 'all';
      _specificDate = '';
      _analysisId = '';
      _sourceType = '';
      _chemicalId = '';
      _rangeState = '';
      _query.clear();
      _resetPage();
    });
  }

  void _applyFilters({
    required String filterMode,
    required String specificDate,
    required String analysisId,
    required String sourceType,
    required String chemicalId,
    required String rangeState,
    required String recordLimit,
  }) {
    setState(() {
      _filterMode = filterMode;
      _specificDate = specificDate;
      _analysisId = analysisId;
      _sourceType = sourceType;
      _chemicalId = chemicalId;
      _rangeState = rangeState;
      _recordLimit = recordLimit;
      _resetPage();
    });
  }

  /// All filter controls live in one overlay instead of an always-on block that
  /// used to eat half the screen; the tab keeps a single compact toolbar row.
  Future<void> _openFilterDialog(
    TestHistoryState state,
    List<({String value, String label})> chemOptions,
  ) async {
    var dMode = _filterMode;
    var dDate = _specificDate;
    var dAnalysis = _analysisId;
    var dSource = _sourceType;
    var dChemical = _chemicalId;
    var dRange = _rangeState;
    var dLimit = _recordLimit;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDraft) {
          Future<void> pickDate() async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: dialogContext,
              initialDate: thParseDay(dDate) ?? now,
              firstDate: DateTime(now.year - 20),
              lastDate: DateTime(now.year + 1),
            );
            if (picked == null || !dialogContext.mounted) return;
            setDraft(() => dDate = thTodayISO(picked));
          }

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 48,
              vertical: 32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(20, 8, 8, 6),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSoft,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                      border: Border(
                        bottom: BorderSide(color: AppColors.borderMuted),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.filter_alt_outlined,
                          size: 20.r,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          AppText.t('الفلاتر', 'Filters'),
                          style: TextStyle(
                            fontSize: 16.spMax,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: AppText.t('إغلاق', 'Close'),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: _filterGrid(
                        state,
                        chemOptions,
                        mode: dMode,
                        specificDate: dDate,
                        analysisId: dAnalysis,
                        sourceType: dSource,
                        chemicalId: dChemical,
                        rangeState: dRange,
                        recordLimit: dLimit,
                        onMode: (v) => setDraft(() {
                          dMode = v;
                          if (v != 'specific-date') {
                            dDate = '';
                          } else if (dDate.isEmpty) {
                            dDate = thTodayISO();
                          }
                        }),
                        onDate: pickDate,
                        onAnalysis: (v) => setDraft(() => dAnalysis = v),
                        onSource: (v) => setDraft(() => dSource = v),
                        onChemical: (v) => setDraft(() => dChemical = v),
                        onRange: (v) => setDraft(() => dRange = v),
                        onLimit: (v) => setDraft(() => dLimit = v),
                      ),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSoft,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(4),
                      ),
                      border: Border(
                        top: BorderSide(color: AppColors.borderMuted),
                      ),
                    ),
                    child: Row(
                      children: [
                        AppButton(
                          label: AppText.t('مسح الكل', 'Clear all'),
                          style: AppButtonStyle.ghost,
                          small: true,
                          onPressed: () => setDraft(() {
                            dMode = 'all';
                            dDate = '';
                            dAnalysis = '';
                            dSource = '';
                            dChemical = '';
                            dRange = '';
                          }),
                        ),
                        const Spacer(),
                        AppButton(
                          label: AppText.t('إلغاء', 'Cancel'),
                          style: AppButtonStyle.secondary,
                          small: true,
                          onPressed: () => Navigator.of(dialogContext).pop(),
                        ),
                        const SizedBox(width: 8),
                        AppButton(
                          label: AppText.t('تطبيق', 'Apply'),
                          style: AppButtonStyle.primary,
                          small: true,
                          onPressed: () {
                            _applyFilters(
                              filterMode: dMode,
                              specificDate: dDate,
                              analysisId: dAnalysis,
                              sourceType: dSource,
                              chemicalId: dChemical,
                              rangeState: dRange,
                              recordLimit: dLimit,
                            );
                            Navigator.of(dialogContext).pop();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _sortMark(String key) {
    if (_sortKey != key) return '';
    return _sortDir > 0 ? ' \u25B2' : ' \u25BC';
  }

  List<Map<String, dynamic>> _buildRows(
    List<Map<String, dynamic>> history,
    List<Map<String, dynamic>> log,
  ) {
    var rows = thFilterModeRows(history, _filterMode, _specificDate);
    rows = thSlice(rows, thCoerceRecordLimit(_recordLimit));
    rows = thApplyRowFilters(
      rows,
      analysisId: _analysisId,
      sourceType: _sourceType,
      chemicalId: _chemicalId,
      rangeState: _rangeState,
      query: _query.text,
      chemTestMap: thBuildChemTestMap(log),
    );
    return thSortRows(rows, _sortKey, _sortDir);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TestHistoryCubit>().state;
    if (state.loading && state.rows.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('سجل تحاليل المختبر', 'Test history'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          const AppSkeletonList(rows: 8, lines: 5, height: 460),
        ],
      );
    }

    final chemOptions = thBuildChemicalOptions(state.log);
    final sorted = _buildRows(state.rows, state.log);
    final summary = thBuildSummary(sorted);
    final paged = thPagination(sorted, _page);
    final chips = thBuildChips(
      filterMode: _filterMode,
      specificDate: _specificDate,
      analysisId: _analysisId,
      sourceType: _sourceType,
      chemicalId: _chemicalId,
      rangeState: _rangeState,
      analyses: state.analyses,
      chemicalOptions: chemOptions,
    );

    return AppErrorFeedback<TestHistoryCubit, TestHistoryState>(
      selector: (s) => s.error,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    AppText.t('سجل تحاليل المختبر', 'Test history'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                AppButton(
                  label: 'اختبار جديد',
                  icon: Icon(Icons.add_circle_outline, size: 18.r),
                  onPressed: _openNewTest,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _query,
                          onChanged: (_) => setState(_resetPage),
                          decoration: InputDecoration(
                            prefixIcon: Icon(Icons.search, size: 20.r),
                            suffixIcon: _query.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: AppText.t(
                                      'مسح البحث',
                                      'Clear search',
                                    ),
                                    icon: Icon(Icons.close, size: 18.r),
                                    onPressed: () => setState(() {
                                      _query.clear();
                                      _resetPage();
                                    }),
                                  ),
                            hintText: AppText.t(
                              'بحث في: تحليل / عينة / مصدر / كود دخول / نتيجة / فاحص / حالة...',
                              'Search analysis, sample, source, entry code, result...',
                            ),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _FilterButton(
                        activeCount: chips.length,
                        onPressed: () => _openFilterDialog(state, chemOptions),
                      ),
                      const SizedBox(width: 6),
                      AppButton(
                        label: AppText.t('الكل', 'All'),
                        icon: Icon(Icons.grid_view_outlined, size: 16.r),
                        style: AppButtonStyle.secondary,
                        small: true,
                        onPressed: chips.isEmpty && _query.text.isEmpty
                            ? null
                            : _clearAllFilters,
                      ),
                    ],
                  ),
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                AppText.t('الفلاتر:', 'Filters:'),
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12.spMax,
                                ),
                              ),
                              for (final chip in chips)
                                InputChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    chip.label,
                                    style: TextStyle(fontSize: 12.spMax),
                                  ),
                                  onDeleted: () => setState(() {
                                    final next = thClearChip(
                                      filterMode: _filterMode,
                                      specificDate: _specificDate,
                                      analysisId: _analysisId,
                                      sourceType: _sourceType,
                                      chemicalId: _chemicalId,
                                      rangeState: _rangeState,
                                      query: _query.text,
                                      key: chip.key,
                                    );
                                    _filterMode = next.filterMode;
                                    _specificDate = next.specificDate;
                                    _analysisId = next.analysisId;
                                    _sourceType = next.sourceType;
                                    _chemicalId = next.chemicalId;
                                    _rangeState = next.rangeState;
                                    _resetPage();
                                  }),
                                ),
                              TextButton(
                                onPressed: _clearAllFilters,
                                child: Text(
                                  AppText.t('مسح الكل', 'Clear all'),
                                  style: TextStyle(fontSize: 12.spMax),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          AppText.t(
                            'يتم عرض ${paged.slice.length} من أصل ${sorted.length}',
                            'Showing ${paged.slice.length} of ${sorted.length}',
                          ),
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12.spMax,
                          ),
                        ),
                        if (summary['out'] != 0)
                          _StatBadge(
                            label: AppText.t(
                              'خارج النطاق: ${summary['out']}',
                              'Out of range: ${summary['out']}',
                            ),
                            color: AppColors.danger,
                          ),
                        if (summary['in'] != 0)
                          _StatBadge(
                            label: AppText.t(
                              'ضمن النطاق: ${summary['in']}',
                              'In range: ${summary['in']}',
                            ),
                            color: AppColors.success,
                          ),
                      ],
                    ),
                  ] else
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            AppText.t(
                              'يتم عرض ${paged.slice.length} من أصل ${sorted.length}',
                              'Showing ${paged.slice.length} of ${sorted.length}',
                            ),
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12.spMax,
                            ),
                          ),
                        ),
                        if (summary['out'] != 0)
                          _StatBadge(
                            label: AppText.t(
                              'خارج النطاق: ${summary['out']}',
                              'Out of range: ${summary['out']}',
                            ),
                            color: AppColors.danger,
                          ),
                        if (summary['in'] != 0)
                          _StatBadge(
                            label: AppText.t(
                              'ضمن النطاق: ${summary['in']}',
                              'In range: ${summary['in']}',
                            ),
                            color: AppColors.success,
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      const DataColumn(label: Text('#')),
                      _sortable('التوقيت', 'tested_at'),
                      _sortable('التحليل', 'analysis_name'),
                      _sortable('العينة', 'sample_name'),
                      _sortable('المصدر', 'source_name'),
                      _sortable('كود الدخول', 'entry_code'),
                      _sortable('النتيجة', 'result_text'),
                      const DataColumn(label: Text('النطاق')),
                      _sortable('الحالة', 'range_state'),
                      _sortable('بواسطة', 'tested_by_name'),
                    ],
                    rows: [
                      if (paged.slice.isEmpty)
                        DataRow(
                          cells: [
                            for (var i = 0; i < 10; i++)
                              DataCell(
                                i == 0
                                    ? Text(
                                        state.rows.isEmpty
                                            ? 'لا توجد تحاليل بعد. شغّل تحليلاً من تبويب تشغيل تحليل.'
                                            : 'لا توجد نتائج مطابقة للفلاتر الحالية.',
                                        style: TextStyle(
                                          color: AppColors.textMuted,
                                        ),
                                      )
                                    : const SizedBox(),
                              ),
                          ],
                        )
                      else
                        for (var i = 0; i < paged.slice.length; i++)
                          _row(paged.slice[i], paged.start + i + 1),
                    ],
                  ),
                ),
              ),
            ),
            if (paged.pageCount > 1) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'السابق',
                    onPressed: _page <= 1
                        ? null
                        : () => setState(() => _page--),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  for (var p = 1; p <= paged.pageCount; p++)
                    if (p == 1 ||
                        p == paged.pageCount ||
                        (p - _page).abs() <= 2)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: p == _page
                            ? Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '$p',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.spMax,
                                  ),
                                ),
                              )
                            : TextButton(
                                onPressed: () => setState(() => _page = p),
                                child: Text(
                                  '$p',
                                  style: TextStyle(fontSize: 13.spMax),
                                ),
                              ),
                      ),
                  IconButton(
                    tooltip: 'التالي',
                    onPressed: _page >= paged.pageCount
                        ? null
                        : () => setState(() => _page++),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  DataColumn _sortable(String label, String key) {
    return DataColumn(
      label: InkWell(
        onTap: () => _setSort(key),
        child: Text('$label${_sortMark(key)}'),
      ),
    );
  }

  Widget _filterGrid(
    TestHistoryState state,
    List<({String value, String label})> chemOptions, {
    required String mode,
    required String specificDate,
    required String analysisId,
    required String sourceType,
    required String chemicalId,
    required String rangeState,
    required String recordLimit,
    required ValueChanged<String> onMode,
    required VoidCallback onDate,
    required ValueChanged<String> onAnalysis,
    required ValueChanged<String> onSource,
    required ValueChanged<String> onChemical,
    required ValueChanged<String> onRange,
    required ValueChanged<String> onLimit,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < AppBreakpoints.expanded;
        final children = <Widget>[
          _filterField(
            label: AppText.t('التصفية', 'Period'),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _modeButton(AppText.t('الكل', 'All'), 'all', mode, onMode),
                _modeButton(
                  AppText.t('24 ساعة', '24h'),
                  'last24h',
                  mode,
                  onMode,
                ),
                _modeButton(
                  AppText.t('تاريخ', 'Date'),
                  'specific-date',
                  mode,
                  onMode,
                ),
              ],
            ),
          ),
          if (mode == 'specific-date')
            _filterField(
              label: AppText.t('اختر التاريخ', 'Pick date'),
              child: InkWell(
                onTap: onDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: Icon(Icons.calendar_today, size: 16.r),
                  ),
                  child: Text(specificDate),
                ),
              ),
            ),
          _filterField(
            label: AppText.t('حد السجلات', 'Record limit'),
            child: DropdownButtonFormField<String>(
              initialValue: recordLimit,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final l in _recordLimits)
                  DropdownMenuItem(value: l, child: Text(l)),
              ],
              onChanged: (v) => onLimit(v ?? recordLimit),
            ),
          ),
          _filterField(
            label: AppText.t('التحليل', 'Analysis'),
            child: DropdownButtonFormField<String>(
              initialValue: analysisId,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('كل التحاليل')),
                for (final a in state.analyses)
                  DropdownMenuItem(
                    value: '${a['id']}',
                    child: Text(
                      '${a['name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => onAnalysis(v ?? ''),
            ),
          ),
          _filterField(
            label: AppText.t('النوع', 'Source type'),
            child: DropdownButtonFormField<String>(
              initialValue: sourceType,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: '', child: Text('كل الأنواع')),
                DropdownMenuItem(
                  value: 'raw_material',
                  child: Text('مادة خام'),
                ),
                DropdownMenuItem(value: 'product', child: Text('منتج')),
              ],
              onChanged: (v) => onSource(v ?? ''),
            ),
          ),
          _filterField(
            label: AppText.t('المواد المستهلكة', 'Consumables'),
            child: DropdownButtonFormField<String>(
              initialValue: chemicalId,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('كل المواد')),
                for (final o in chemOptions)
                  DropdownMenuItem(value: o.value, child: Text(o.label)),
              ],
              onChanged: (v) => onChemical(v ?? ''),
            ),
          ),
          _filterField(
            label: AppText.t('الحالة', 'Range state'),
            child: DropdownButtonFormField<String>(
              initialValue: rangeState,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: '', child: Text('كل النتائج')),
                DropdownMenuItem(value: 'out', child: Text('خارج النطاق')),
                DropdownMenuItem(value: 'in', child: Text('ضمن النطاق')),
                DropdownMenuItem(value: 'none', child: Text('بدون نطاق')),
              ],
              onChanged: (v) => onRange(v ?? ''),
            ),
          ),
        ];
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in children)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: c,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _filterField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11.spMax,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }

  Widget _modeButton(
    String label,
    String mode,
    String current,
    ValueChanged<String> onPick,
  ) {
    final selected = current == mode;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onPick(mode),
      ),
    );
  }

  DataRow _row(Map<String, dynamic> r, int index) {
    final out = '${r['range_state'] ?? ''}' == 'out';
    final inn = '${r['range_state'] ?? ''}' == 'in';
    final stateColor = out
        ? AppColors.danger
        : inn
        ? AppColors.success
        : AppColors.textMuted;
    final range = r['min'] == null && r['max'] == null
        ? '-'
        : '${r['min'] ?? ''} – ${r['max'] ?? ''} '
              '${r['range_unit'] ?? r['analysis_unit'] ?? '%'}';
    return DataRow(
      color: out
          ? WidgetStatePropertyAll(AppColors.danger.withValues(alpha: 0.06))
          : inn
          ? WidgetStatePropertyAll(AppColors.success.withValues(alpha: 0.06))
          : null,
      cells: [
        DataCell(Text('$index')),
        DataCell(Text(thFmtDateTime(r['tested_at']))),
        DataCell(Text('${r['analysis_name'] ?? '-'}')),
        DataCell(Text('${r['sample_name'] ?? '-'}')),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${r['source_name'] ?? '-'}'),
              if ('${r['source_type'] ?? ''}' != '')
                Text(
                  ' (${r['source_type'] == 'product' ? 'منتج' : 'خام'})',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.spMax,
                  ),
                ),
            ],
          ),
        ),
        DataCell(
          Text('${r['entry_code'] ?? '-'}', textDirection: TextDirection.ltr),
        ),
        DataCell(
          Text(
            '${r['result_text'] ?? '-'}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: out ? AppColors.danger : null,
            ),
          ),
        ),
        DataCell(Text(range, overflow: TextOverflow.ellipsis)),
        DataCell(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: stateColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              thRangeLabel('${r['range_state'] ?? 'none'}'),
              style: TextStyle(
                color: stateColor,
                fontSize: 11.spMax,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        DataCell(Text('${r['tested_by_name'] ?? '-'}')),
      ],
    );
  }
}

class _FilterButton extends StatelessWidget {
  final int activeCount;
  final VoidCallback onPressed;

  const _FilterButton({required this.activeCount, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final active = activeCount > 0;
    return AppButton(
      label: active
          ? AppText.t('فلترة ($activeCount)', 'Filter ($activeCount)')
          : AppText.t('فلترة', 'Filter'),
      icon: Icon(Icons.filter_alt_outlined, size: 16.r),
      style: active ? AppButtonStyle.primary : AppButtonStyle.secondary,
      small: true,
      onPressed: onPressed,
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatBadge({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11.spMax,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
