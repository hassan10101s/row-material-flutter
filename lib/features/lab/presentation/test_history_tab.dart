import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../di/service_locator.dart';
import '../core/test_history_logic.dart';
import '../data/lab_repo.dart';
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

  void _setFilterMode(String mode) {
    setState(() {
      _filterMode = mode;
      _resetPage();
      if (mode != 'specific-date') {
        _specificDate = '';
      } else if (_specificDate.isEmpty) {
        _specificDate = thTodayISO();
      }
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: thParseDay(_specificDate) ?? now,
      firstDate: DateTime(now.year - 20),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _specificDate = thTodayISO(picked);
      _resetPage();
    });
  }

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
        create: (_) => RunTestCubit(repo: getIt<LabRepo>())..load(),
        child: Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
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
                        top: Radius.circular(4)),
                    border: Border(
                        bottom: BorderSide(color: AppColors.borderMuted)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.science_outlined,
                          size: 20.r, color: AppColors.primary),
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

  String _sortMark(String key) {
    if (_sortKey != key) return '';
    return _sortDir > 0 ? ' \u25B2' : ' \u25BC';
  }

  List<Map<String, dynamic>> _buildRows(
      List<Map<String, dynamic>> history,
      List<Map<String, dynamic>> log) {
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
    if (state.loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('سجل تحاليل المختبر', 'Test history'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (state.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('سجل تحاليل المختبر', 'Test history'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          Text(state.error!, style: TextStyle(color: AppColors.danger)),
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

    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(AppText.t('سجل تحاليل المختبر', 'Test history'),
                  style: Theme.of(context).textTheme.titleLarge),
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
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _query,
                onChanged: (_) => setState(_resetPage),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 20.r),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح البحث',
                          icon: Icon(Icons.close, size: 18.r),
                          onPressed: () => setState(() {
                            _query.clear();
                            _resetPage();
                          }),
                        ),
                  hintText: 'بحث في: تحليل / عينة / مصدر / كود دخول / نتيجة / فاحص / حالة...',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _filterGrid(state, chemOptions),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('الفلاتر:',
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 12.spMax)),
                        for (final chip in chips)
                          InputChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(chip.label, style: TextStyle(fontSize: 12.spMax)),
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
                        if (chips.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() {
                              _filterMode = 'all';
                              _specificDate = '';
                              _analysisId = '';
                              _sourceType = '';
                              _chemicalId = '';
                              _rangeState = '';
                              _query.clear();
                              _resetPage();
                            }),
                            child: Text('مسح الكل', style: TextStyle(fontSize: 12.spMax)),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    'يتم عرض ${paged.slice.length} من أصل ${sorted.length}',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                  ),
                  if (summary['out'] != 0)
                    _StatBadge(label: 'خارج النطاق: ${summary['out']}', color: AppColors.danger),
                  if (summary['in'] != 0)
                    _StatBadge(label: 'ضمن النطاق: ${summary['in']}', color: AppColors.success),
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
                    DataRow(cells: [
                      for (var i = 0; i < 10; i++)
                        DataCell(
                          i == 0
                              ? Text(
                                  state.rows.isEmpty
                                      ? 'لا توجد تحاليل بعد. شغّل تحليلاً من تبويب تشغيل تحليل.'
                                      : 'لا توجد نتائج مطابقة للفلاتر الحالية.',
                                  style: TextStyle(color: AppColors.textMuted),
                                )
                              : const SizedBox(),
                        ),
                    ])
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
                onPressed: _page <= 1 ? null : () => setState(() => _page--),
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
                            child: Text('$p',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13.spMax)),
                          )
                        : TextButton(
                            onPressed: () => setState(() => _page = p),
                            child: Text('$p', style: TextStyle(fontSize: 13.spMax)),
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
    List<({String value, String label})> chemOptions,
  ) {
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 900;
      final children = <Widget>[
        _filterField(
          label: 'التصفية',
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _modeButton('الكل', 'all'),
              _modeButton('24 ساعة', 'last24h'),
              _modeButton('تاريخ', 'specific-date'),
            ],
          ),
        ),
        if (_filterMode == 'specific-date')
          _filterField(
            label: 'اختر التاريخ',
            child: InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: Icon(Icons.calendar_today, size: 16.r),
                ),
                child: Text(_specificDate),
              ),
            ),
          ),
        _filterField(
          label: 'حد السجلات',
          child: DropdownButtonFormField<String>(
            initialValue: _recordLimit,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final l in _recordLimits)
                DropdownMenuItem(value: l, child: Text(l)),
            ],
            onChanged: (v) => setState(() {
              _recordLimit = v ?? _recordLimit;
              _resetPage();
            }),
          ),
        ),
        _filterField(
          label: 'التحليل',
          child: DropdownButtonFormField<String>(
            initialValue: _analysisId,
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
                  child: Text('${a['name']}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() {
              _analysisId = v ?? '';
              _resetPage();
            }),
          ),
        ),
        _filterField(
          label: 'النوع',
          child: DropdownButtonFormField<String>(
            initialValue: _sourceType,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: '', child: Text('كل الأنواع')),
              DropdownMenuItem(value: 'raw_material', child: Text('مادة خام')),
              DropdownMenuItem(value: 'product', child: Text('منتج')),
            ],
            onChanged: (v) => setState(() {
              _sourceType = v ?? '';
              _resetPage();
            }),
          ),
        ),
        _filterField(
          label: 'المواد المستهلكة',
          child: DropdownButtonFormField<String>(
            initialValue: _chemicalId,
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
            onChanged: (v) => setState(() {
              _chemicalId = v ?? '';
              _resetPage();
            }),
          ),
        ),
        _filterField(
          label: 'الحالة',
          child: DropdownButtonFormField<String>(
            initialValue: _rangeState,
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
            onChanged: (v) => setState(() {
              _rangeState = v ?? '';
              _resetPage();
            }),
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
            Expanded(child: Padding(padding: const EdgeInsets.only(left: AppSpacing.sm), child: c)),
        ],
      );
    });
  }

  Widget _filterField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.spMax,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        child,
      ],
    );
  }

  Widget _modeButton(String label, String mode) {
    final selected = _filterMode == mode;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _setFilterMode(mode),
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
    final range =
        r['min'] == null && r['max'] == null
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
        DataCell(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${r['source_name'] ?? '-'}'),
            if ('${r['source_type'] ?? ''}' != '')
              Text(
                ' (${r['source_type'] == 'product' ? 'منتج' : 'خام'})',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 11.spMax),
              ),
          ],
        )),
        DataCell(Text('${r['entry_code'] ?? '-'}',
            textDirection: TextDirection.ltr)),
        DataCell(Text('${r['result_text'] ?? '-'}',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: out ? AppColors.danger : null))),
        DataCell(Text(range, overflow: TextOverflow.ellipsis)),
        DataCell(Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: stateColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(thRangeLabel('${r['range_state'] ?? 'none'}'),
              style: TextStyle(
                  color: stateColor,
                  fontSize: 11.spMax,
                  fontWeight: FontWeight.w600)),
        )),
        DataCell(Text('${r['tested_by_name'] ?? '-'}')),
      ],
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
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 11.spMax,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}