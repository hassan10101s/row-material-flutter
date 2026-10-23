import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/responsive/form_factor.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_adaptive_list.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_search_field.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../di/service_locator.dart';
import '../../domain/routine_repository.dart';
import 'routine_history_cubit.dart';
import 'routine_sheet_screen.dart';

/// The general log of everything completed on the routine lists: one flat
/// row per completed item (time, list, item, person, note), a table on
/// desktop and cards on phones. Every open of the screen is a fresh session
/// defaulting to **today's** range — each day starts empty, the same way the
/// daily lists reset — and widening the range is one chip away.
class RoutineHistoryScreen extends StatefulWidget {
  const RoutineHistoryScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BlocProvider(
          create: (_) =>
              RoutineHistoryCubit(repo: getIt<RoutineListsRepository>())..load(),
          child: const RoutineHistoryScreen(),
        ),
      ),
    );
  }

  @override
  State<RoutineHistoryScreen> createState() => _RoutineHistoryScreenState();
}

enum _Range { today, month, all }

class _RoutineHistoryScreenState extends State<RoutineHistoryScreen> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _person = TextEditingController();
  final _item = TextEditingController();
  int? _templateId;
  _Range _range = _Range.all;

  List<RoutineList> _lists = const [];

  static String get _today => todayIso().substring(0, 10);

  @override
  void initState() {
    super.initState();
    _setRange(_Range.today, reload: false);
    _loadLists();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _person.dispose();
    _item.dispose();
    super.dispose();
  }

  Future<void> _loadLists() async {
    try {
      final lists = await getIt<RoutineListsRepository>().listRoutineLists();
      if (mounted) setState(() => _lists = lists);
    } on Object {
      // Filter dropdown stays on "all lists".
    }
  }

  void _setRange(_Range range, {bool reload = true}) {
    setState(() => _range = range);
    switch (range) {
      case _Range.today:
        _from.text = _today;
        _to.text = _today;
      case _Range.month:
        final now = DateTime.now();
        final first = DateTime(now.year, now.month, 1);
        _from.text =
            '${first.year.toString().padLeft(4, '0')}-'
            '${first.month.toString().padLeft(2, '0')}-'
            '${first.day.toString().padLeft(2, '0')}';
        _to.text = _today;
      case _Range.all:
        _from.clear();
        _to.clear();
    }
    if (reload) _search();
  }

  void _search() {
    context.read<RoutineHistoryCubit>().applyFilters(
      RoutineHistoryFilters(
        templateId: _templateId,
        from: _from.text.trim().isEmpty ? null : _from.text.trim(),
        to: _to.text.trim().isEmpty ? null : _to.text.trim(),
        person: _person.text.trim(),
        itemQuery: _item.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopAppBar(title: AppText.t('السجل', 'History')),
      body: SafeArea(
        child: BlocConsumer<RoutineHistoryCubit, RoutineHistoryState>(
          listenWhen: (prev, curr) =>
              curr.error != null && curr.error != prev.error,
          listener: (context, state) {
            AppFeedback.error(context, state.error!);
            context.read<RoutineHistoryCubit>().clearError();
          },
          builder: (context, state) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: _FiltersBar(
                  lists: _lists,
                  templateId: _templateId,
                  onTemplate: (v) => setState(() {
                    _templateId = v;
                    _search();
                  }),
                  from: _from,
                  to: _to,
                  onDate: _search,
                  person: _person,
                  onPerson: _search,
                  item: _item,
                  onItem: _search,
                  range: _range,
                  onRange: (r) => _setRange(r),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    state.log.isEmpty
                        ? AppText.t('لا تسجيلات', 'No records')
                        : '${AppText.t('عدد التسجيلات', 'Records')}: ${state.log.length}',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1020),
                    child: AppAdaptiveDataView(
                      headers: ['الوقت', 'القائمة', 'البند', 'الشخص', 'ملاحظة'],
                      columnFlex: const [3, 3, 4, 2, 4],
                      loading: state.loading && state.log.isEmpty,
                      cardsOnly: FormFactor.current.isMobile,
                      rows: [
                        for (final log in state.log)
                          AppDataRow(
                            cells: _doneCells(context, log),
                            onTap: log.inspectionId == null
                                ? null
                                : () => RoutineSheetScreen.open(
                                    context,
                                    inspectionId: log.inspectionId!,
                                  ),
                          ),
                      ],
                      onRowTap: state.log.isEmpty
                          ? null
                          : (i) {
                              final inspectionId = state.log[i].inspectionId;
                              if (inspectionId != null) {
                                RoutineSheetScreen.open(
                                  context,
                                  inspectionId: inspectionId,
                                );
                              }
                            },
                      empty: AppEmptyState(
                        icon: Icons.task_alt,
                        title: AppText.t(
                          'لا إنجازات في هذه الفترة بعد',
                          'No completions in this range yet',
                        ),
                        subtitle: _range == _Range.today
                            ? AppText.t(
                                'استخدم «الشهر الحالي» أو «كل الفترات» لعرض السجل كاملاً',
                                'Use "This month" or "All" to see the full trail',
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _doneCells(BuildContext context, RoutineDoneLog log) {
    final today = _today;
    final isToday = log.at.length >= 10 && log.at.substring(0, 10) == today;
    return [
      Text(
        log.stamp,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13.spMax,
          fontWeight: FontWeight.w700,
          color: isToday ? AppColors.success : AppColors.textStrong,
        ),
      ),
      Text(
        log.templateName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.spMax, color: AppColors.textStrong),
      ),
      Text(
        log.itemLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.spMax),
      ),
      Text(
        log.byName.trim().isEmpty ? '—' : log.byName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
      ),
      Text(
        log.note.trim().isEmpty ? '—' : log.note,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
      ),
    ];
  }
}

/// One compact filter row: the range chips (the default session view), the
/// list dropdown and the manual date / person / item refinements. Every
/// change re-queries immediately — no "search" button to forget.
class _FiltersBar extends StatelessWidget {
  const _FiltersBar({
    required this.lists,
    required this.templateId,
    required this.onTemplate,
    required this.from,
    required this.to,
    required this.onDate,
    required this.person,
    required this.onPerson,
    required this.item,
    required this.onItem,
    required this.range,
    required this.onRange,
  });

  final List<RoutineList> lists;
  final int? templateId;
  final ValueChanged<int?> onTemplate;
  final TextEditingController from;
  final TextEditingController to;
  final VoidCallback onDate;
  final TextEditingController person;
  final VoidCallback onPerson;
  final TextEditingController item;
  final VoidCallback onItem;
  final _Range range;
  final ValueChanged<_Range> onRange;

  @override
  Widget build(BuildContext context) {
    final wide = !FormFactor.current.isMobile;

    final rangeChips = Wrap(
      spacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          AppText.t('النطاق:', 'Range:'),
          style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
        ),
        _RangeChip(
          label: AppText.t('اليوم', 'Today'),
          selected: range == _Range.today,
          onTap: () => onRange(_Range.today),
        ),
        _RangeChip(
          label: AppText.t('الشهر الحالي', 'This month'),
          selected: range == _Range.month,
          onTap: () => onRange(_Range.month),
        ),
        _RangeChip(
          label: AppText.t('كل الفترات', 'All'),
          selected: range == _Range.all,
          onTap: () => onRange(_Range.all),
        ),
      ],
    );

    final listDropdown = AppDropdown<int?>(
      value: templateId,
      items: [
        AppDropdownItem<int?>(
          value: null,
          label: AppText.t('كل القوائم', 'All'),
        ),
        for (final l in lists)
          AppDropdownItem<int?>(
            value: l.template.templateId,
            label: l.template.name,
          ),
      ],
      onChanged: onTemplate,
    );

    final dates = Row(
      children: [
        Expanded(
          child: AppDateField(
            label: AppText.t('من', 'From'),
            controller: from,
            onChanged: (_) => onDate(),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: AppDateField(
            label: AppText.t('إلى', 'To'),
            controller: to,
            onChanged: (_) => onDate(),
          ),
        ),
      ],
    );

    final textFilters = Row(
      children: [
        Expanded(
          child: DebouncedSearchField(
            hint: AppText.t('الشخص (اسم أو كود)', 'Person (name or id)'),
            onChanged: (_) => onPerson(),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: DebouncedSearchField(
            hint: AppText.t('البند', 'Item'),
            onChanged: (_) => onItem(),
          ),
        ),
      ],
    );

    final refresh = AppButton(
      small: true,
      style: AppButtonStyle.secondary,
      label: AppText.t('تحديث', 'Refresh'),
      icon: Icon(Icons.refresh, size: 18.r),
      onPressed: onDate,
    );

    if (wide) {
      return AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: rangeChips),
                AppButton(
                  small: true,
                  style: AppButtonStyle.secondary,
                  label: AppText.t(
                    'قائمة السجل الكامل',
                    'Full sheet history',
                  ),
                  icon: Icon(Icons.calendar_view_day, size: 18.r),
                  onPressed: () => _showSheetsWindow(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                SizedBox(
                  width: 180,
                  child: listDropdown,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: dates,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: textFilters,
                ),
                const SizedBox(width: AppSpacing.sm),
                refresh,
              ],
            ),
          ],
        ),
      );
    }
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: rangeChips),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                small: true,
                style: AppButtonStyle.secondary,
                label: AppText.t('سجل القوائم', 'Sheets'),
                icon: Icon(Icons.calendar_view_day, size: 18.r),
                onPressed: () => _showSheetsWindow(context),
              ),
              const SizedBox(width: AppSpacing.sm),
              refresh,
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          listDropdown,
          const SizedBox(height: AppSpacing.sm),
          dates,
          const SizedBox(height: AppSpacing.sm),
          textFilters,
        ],
      ),
    );
  }
}

/// The per-sheet scorecards (list × period, progress, who) live behind one
/// entry, since the visible surface is the flat per-item log.
void _showSheetsWindow(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const _SheetsScreen(),
    ),
  );
}

/// Full sheet history: every list × period page with its scorecard and the
/// people who recorded on it. Tapping one opens the sheet read-only.
class _SheetsScreen extends StatefulWidget {
  const _SheetsScreen();

  @override
  State<_SheetsScreen> createState() => _SheetsScreenState();
}

class _SheetsScreenState extends State<_SheetsScreen> {
  List<RoutineHistoryEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final entries = await getIt<RoutineListsRepository>().sheetHistory(
        const RoutineHistoryFilters(),
      );
      if (mounted) setState(() => _entries = entries);
    } on Object {
      if (mounted) setState(() => _entries = const []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('سجل القوائم الكامل', 'Full sheet history'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.pageMobile),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loading)
                  const AppSkeletonList(rows: 5, lines: 2, height: 96)
                else if (_entries.isEmpty)
                  AppEmptyState(
                    icon: Icons.history,
                    title: AppText.t('لا توجد سجلات', 'No sheets'),
                  )
                else
                  for (final entry in _entries) ...[
                    _SheetCard(entry: entry),
                    const SizedBox(height: AppSpacing.sm),
                  ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetCard extends StatelessWidget {
  const _SheetCard({required this.entry});

  final RoutineHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final day = entry.inspection.inspectionDate.length >= 10
        ? entry.inspection.inspectionDate.substring(0, 10)
        : entry.inspection.inspectionDate;
    final progress = entry.totalCount == 0
        ? 0.0
        : (entry.doneCount / entry.totalCount).clamp(0.0, 1.0);
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: InkWell(
        onTap: () => RoutineSheetScreen.open(
          context,
          inspectionId: entry.inspection.inspectionId!,
        ),
        borderRadius: BorderRadius.circular(12.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.templateName,
                    style: TextStyle(
                      fontSize: 14.spMax,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  day,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6.r),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: AppColors.primary.withValues(
                        alpha: 0.12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '${entry.doneCount}/${entry.totalCount}',
                  style: TextStyle(
                    fontSize: 13.spMax,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (entry.people.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final p in entry.people)
                    Text(
                      p,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.12)
              : AppColors.surfaceSoft.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.borderMuted,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.spMax,
            fontWeight: FontWeight.w700,
            color: selected ? AppColors.primary : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}
