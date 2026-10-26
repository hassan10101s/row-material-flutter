import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../domain/routine_repository.dart';
import 'routine_sheet_cubit.dart';

/// One routine sheet: tap a box to check it (stamps who/when), tap again to
/// uncheck while the period is current. Past sheets are read-only history.
class RoutineSheetScreen extends StatelessWidget {
  const RoutineSheetScreen({super.key, required this.inspectionId});

  final int inspectionId;

  static Future<void> open(BuildContext context, {required int inspectionId}) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BlocProvider(
          create: (_) => RoutineSheetCubit(
            repo: getIt<RoutineListsRepository>(),
            inspectionId: inspectionId,
          )..load(),
          child: RoutineSheetScreen(inspectionId: inspectionId),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopAppBar(title: AppText.t('القائمة', 'Checklist')),
      body: SafeArea(
        child: BlocConsumer<RoutineSheetCubit, RoutineSheetState>(
          listenWhen: (prev, curr) =>
              (curr.error != null && curr.error != prev.error) ||
              (curr.notice != null && curr.notice != prev.notice),
          listener: (context, state) {
            if (state.error != null) {
              AppFeedback.error(context, state.error!);
              context.read<RoutineSheetCubit>().clearError();
            }
            if (state.notice != null) {
              AppFeedback.success(context, state.notice!);
              context.read<RoutineSheetCubit>().clearNotice();
            }
          },
          builder: (context, state) {
            if (state.loading && state.sheet == null) {
              return const Padding(
                padding: EdgeInsets.all(AppSpacing.page),
                child: AppSkeletonList(rows: 6, lines: 2, height: 64),
              );
            }
            final sheet = state.sheet;
            if (sheet == null) {
              return AppErrorState(
                title: AppText.t('تعذر فتح القائمة', 'Could not open the list'),
                onRetry: () => context.read<RoutineSheetCubit>().refresh(),
              );
            }
            return RefreshIndicator(
              onRefresh: () => context.read<RoutineSheetCubit>().refresh(),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SheetHeader(sheet: sheet),
                    const SizedBox(height: AppSpacing.md),
                    if (!sheet.current)
                      _LockedBanner(sheet: sheet)
                    else
                      for (final row in sheet.rows) ...[
                        _CheckRow(
                          sheet: sheet,
                          row: row,
                          busy: state.toggling.contains(row.item.itemId),
                          logging: state.logging.contains(row.item.itemId),
                          onToggle: (note) => context
                              .read<RoutineSheetCubit>()
                              .toggle(row.item.itemId!, note: note),
                          onDone: () => context
                              .read<RoutineSheetCubit>()
                              .recordDone(row.item.itemId!),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                    if (!sheet.current)
                      for (final row in sheet.rows) ...[
                        _CheckRow(
                          sheet: sheet,
                          row: row,
                          busy: false,
                          onToggle: (_) {},
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.sheet});

  final RoutineSheet sheet;

  @override
  Widget build(BuildContext context) {
    final progress = sheet.rows.isEmpty
        ? 0.0
        : (sheet.doneCount / sheet.rows.length).clamp(0.0, 1.0);
    final day = sheet.inspection.inspectionDate.length >= 10
        ? sheet.inspection.inspectionDate.substring(0, 10)
        : sheet.inspection.inspectionDate;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sheet.template.name,
            style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            sheet.template.recurrence == 'monthly'
                ? AppText.t(
                    'شهر ${day.length >= 7 ? day.substring(0, 7) : day}',
                    'Month ${day.length >= 7 ? day.substring(0, 7) : day}',
                  )
                : AppText.t('يوم $day', 'Day $day'),
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
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
                    backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${sheet.doneCount}/${sheet.rows.length}',
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w700,
                  color: sheet.isComplete
                      ? AppColors.success
                      : AppColors.textStrong,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LockedBanner extends StatelessWidget {
  const _LockedBanner({required this.sheet});

  final RoutineSheet sheet;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 20.r, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              AppText.t(
                'الفترة انتهت — هذا السجل للعرض فقط',
                'Period is over — this sheet is read-only',
              ),
              style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.sheet,
    required this.row,
    required this.busy,
    this.logging = false,
    required this.onToggle,
    this.onDone,
  });

  final RoutineSheet sheet;
  final RoutineRow row;
  final bool busy;
  final bool logging;
  final void Function(String note) onToggle;
  final VoidCallback? onDone;

  Future<void> _noteThenToggle(BuildContext context) async {
    final note = await showRoutineNoteDialog(
      context,
      initial: row.response.notes,
    );
    if (note == null || !context.mounted) return;
    onToggle(note);
  }

  /// Every logged completion of this task (hour + user each), read-only.
  Future<void> _showLogHistory(BuildContext context) async {
    final sheetId = sheet.inspection.inspectionId!;
    final itemId = row.item.itemId!;
    final repo = context.read<RoutineSheetCubit>().repo;
    final logs = await repo.taskLogs(sheetId, itemId: itemId);
    if (logs.isEmpty || !context.mounted) return;
    await showAppDialog<void>(
      context,
      builder: (ctx) => AppDialog(
        icon: Icons.task_alt,
        title: AppText.t(
          'سجل إنجاز: ${row.item.label}',
          'Done log: ${row.item.label}',
        ),
        actions: [
          AppButton(
            style: AppButtonStyle.secondary,
            small: true,
            label: AppText.t('إغلاق', 'Close'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
        child: SizedBox(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final log in logs)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.task_alt, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${log.stamp} · ${log.loggedByName}',
                                  style: TextStyle(
                                    fontSize: 13.spMax,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (log.note.trim().isNotEmpty)
                                  Text(
                                    log.note,
                                    style: TextStyle(
                                      fontSize: 12.spMax,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recorded = row.recorded;
    final editable = sheet.current && !busy;
    final byName = row.response.answeredByName.trim();
    final at = row.response.measuredAt.trim();
    final time = at.length >= 16 ? at.substring(11, 16) : at;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: InkWell(
        onTap: !editable ? null : () => onToggle(row.response.notes),
        onLongPress: !editable ? null : () => _noteThenToggle(context),
        borderRadius: BorderRadius.circular(10.r),
        child: Row(
          children: [
            Checkbox(
              value: recorded,
              onChanged: !editable ? null : (_) => onToggle(row.response.notes),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.item.label,
                    style: TextStyle(
                      fontSize: 14.spMax,
                      fontWeight: FontWeight.w600,
                      decoration: recorded ? TextDecoration.lineThrough : null,
                      color: recorded
                          ? AppColors.textMuted
                          : AppColors.textStrong,
                    ),
                  ),
                  if (recorded && (byName.isNotEmpty || time.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '✓ ${byName.isEmpty ? '—' : byName}'
                        '${time.isEmpty ? '' : ' · $time'}',
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (row.response.notes.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        row.response.notes,
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  if (row.hasTaskLogs)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${AppText.t('مرات الإنجاز', 'Times done')}: '
                        '${row.taskLogCount}'
                        '${row.lastTaskLogStamp.isEmpty ? '' : ' · ${AppText.t('آخر', 'last')} ${row.lastTaskLogStamp}'
                                  '${row.lastTaskLogByName.isEmpty ? '' : ' — ${row.lastTaskLogByName}'}'}',
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (busy || logging)
              SizedBox(
                width: 20.r,
                height: 20.r,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              if (row.hasTaskLogs)
                IconButton(
                  tooltip: AppText.t('سجل الإنجاز', 'Done log'),
                  icon: Icon(
                    Icons.history_rounded,
                    size: 20.r,
                    color: AppColors.textMuted,
                  ),
                  onPressed: () => _showLogHistory(context),
                ),
              if (editable) ...[
                IconButton(
                  tooltip: AppText.t('ملاحظة', 'Note'),
                  icon: Icon(
                    row.response.notes.trim().isNotEmpty
                        ? Icons.note_alt
                        : Icons.note_add_outlined,
                    size: 20.r,
                    color: AppColors.textMuted,
                  ),
                  onPressed: () => _noteThenToggle(context),
                ),
                IconButton(
                  tooltip: AppText.t('تم إنجاز الآن', 'Done now'),
                  icon: Icon(
                    Icons.task_alt,
                    size: 20.r,
                    color: recorded ? AppColors.success : AppColors.primary,
                  ),
                  onPressed: onDone == null ? null : () => onDone!(),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Optional note attached to a check. Empty + save = check without a note;
/// cancel (null) = do not check at all.
Future<String?> showRoutineNoteDialog(
  BuildContext context, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showAppDialog<String>(
    context,
    builder: (context) => AppDialog(
      icon: Icons.note_alt_outlined,
      title: AppText.t('ملاحظة على البند', 'Item note'),
      actions: [
        AppButton(
          style: AppButtonStyle.secondary,
          small: true,
          label: AppText.t('إلغاء', 'Cancel'),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        AppButton(
          small: true,
          label: AppText.t('تم', 'Done'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
        ),
      ],
      child: AppField(
        label: AppText.t('ملاحظة (اختياري)', 'Note (optional)'),
        controller: controller,
        maxLines: 3,
        autofocus: true,
      ),
    ),
  );
  controller.dispose();
  return result;
}
