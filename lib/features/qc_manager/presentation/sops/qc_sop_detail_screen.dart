import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_sop.dart';
import '../cubit/qc_sop_detail_cubit.dart';
import '../cubit/qc_sops_cubit.dart';
import 'qc_sop_form_screen.dart';
import '../widgets/sop_pill.dart';

/// One procedure: its body, its lifecycle, its revisions, and who has read it.
///
/// The lifecycle buttons are generated from [SopStatus.transitions] rather than
/// hard-coded, so the screen offers exactly the moves the domain permits and a
/// fourth state cannot leave a stale button behind.
class QcSopDetailScreen extends StatelessWidget {
  const QcSopDetailScreen({super.key});

  /// Opens one SOP, built on top of the register cubit already in context.
  ///
  /// The detail cubit takes its repository from that register rather than from
  /// DI, so both halves of the screen are guaranteed to be talking to the same
  /// stack - and so advancing a procedure here refreshes the list behind it.
  static Future<void> open(BuildContext context, int sopId) {
    final sops = context.read<QcSopsCubit>();
    final detail = QcSopDetailCubit(repo: sops.repo, sops: sops, sopId: sopId)
      ..load();
    return Navigator.of(context).push(
      appMaterialPageRoute<void>(
        builder: (_) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: sops),
            BlocProvider.value(value: detail),
          ],
          child: const QcSopDetailScreen(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QcSopDetailCubit, QcSopDetailState>(
      listenWhen: (a, b) =>
          (a.notice != b.notice && b.notice != null) ||
          (a.error != b.error && b.error != null),
      listener: (context, state) {
        final cubit = context.read<QcSopDetailCubit>();
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
          cubit.clearError();
        } else if (state.notice != null) {
          AppFeedback.success(context, state.notice!);
          cubit.clearNotice();
        }
      },
      builder: (context, state) {
        final sop = state.sop;
        return Scaffold(
          appBar: AppTopAppBar(
            title: sop?.title ?? AppText.t('الإجراء', 'Procedure'),
            actions: [
              if (sop != null && sop.isEditable)
                IconButton(
                  tooltip: AppText.t('تعديل', 'Edit'),
                  onPressed: () => QcSopFormScreen.open(
                    context,
                    sop: sop,
                    detail: context.read<QcSopDetailCubit>(),
                  ),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
          body: state.loading && sop == null
              ? const Center(child: CircularProgressIndicator())
              : sop == null
              ? AppEmptyState(
                  icon: Icons.search_off,
                  title: AppText.t(
                    'هذا الإجراء غير موجود',
                    'This SOP no longer exists',
                  ),
                )
              : _Body(state: state, sop: sop),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.sop});

  final QcSopDetailState state;
  final QcSop sop;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            SopPill.status(sop.status),
            const SizedBox(width: AppSpacing.xs),
            SopPill.criticality(sop.criticality),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _LifecycleRow(state: state, sop: sop),
        const SizedBox(height: AppSpacing.md),
        // Simplified (plan §5): title + category + body first. Code and
        // expiry stay visible when set (legacy rows); roles/dept/site and
        // version internals stay in DB, hidden from the plant floor.
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sop.title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16.spMax,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${AppText.t('الفئة', 'Category')}: ${sop.category.isEmpty ? '-' : sop.category}',
                style: TextStyle(
                  fontSize: 12.spMax,
                  color: AppColors.textMuted,
                ),
              ),
              if (sop.code.isNotEmpty)
                Text(
                  '${sop.code}  •  rev ${sop.revNo}',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
              if (sop.expiryDate.isNotEmpty)
                Text(
                  '${AppText.t('ينتهي في', 'Expires')}: ${sop.expiryDate.length >= 10 ? sop.expiryDate.substring(0, 10) : sop.expiryDate}',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: sop.isExpired
                        ? AppColors.danger
                        : AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ),
        if (sop.isPublished) ...[
          const SizedBox(height: AppSpacing.md),
          _AcknowledgeCard(state: state, sop: sop),
        ],
        if (sop.contentText.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t('النص', 'Body'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.spMax,
                  ),
                ),
                const Divider(),
                Text(sop.contentText, style: TextStyle(fontSize: 13.spMax)),
              ],
            ),
          ),
        ],
        if (sop.fileName.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Row(
              children: [
                const Icon(Icons.attach_file),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(sop.fileName)),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _RevisionsCard(state: state, sop: sop),
        const SizedBox(height: AppSpacing.md),
        _ReadsCard(state: state, sop: sop),
      ],
    );
  }
}

/// The moves this SOP can legally make, from the domain table.
class _LifecycleRow extends StatelessWidget {
  const _LifecycleRow({required this.state, required this.sop});

  final QcSopDetailState state;
  final QcSop sop;

  static const _labels = <String, String>{
    SopStatus.pending: 'إرسال للموافقة',
    SopStatus.approved: 'اعتماد',
    SopStatus.published: 'نشر',
    SopStatus.obsolete: 'إلغاء',
    SopStatus.archived: 'أرشفة',
    SopStatus.draft: 'إرجاع لمسودة',
  };

  static const _english = <String, String>{
    SopStatus.pending: 'Submit for approval',
    SopStatus.approved: 'Approve',
    SopStatus.published: 'Publish',
    SopStatus.obsolete: 'Obsolete',
    SopStatus.archived: 'Archive',
    SopStatus.draft: 'Return to draft',
  };

  @override
  Widget build(BuildContext context) {
    final moves = state.nextStatuses;
    final cubit = context.read<QcSopDetailCubit>();
    if (moves.isEmpty) {
      return Text(
        AppText.t('لا توجد خطوات تالية', 'No further steps from here'),
        style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
      );
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        // Every legal move is the same shape: an audited status change. Cutting
        // a *revision* is a separate action and lives with the history, because
        // it is a different operation with a different reason attached.
        for (final move in moves)
          OutlinedButton(
            onPressed: state.saving ? null : () => cubit.advance(move),
            child: Text(AppText.t(_labels[move]!, _english[move]!)),
          ),
      ],
    );
  }
}

/// Read acknowledgement for the current revision.
class _AcknowledgeCard extends StatelessWidget {
  const _AcknowledgeCard({required this.state, required this.sop});

  final QcSopDetailState state;
  final QcSop sop;

  @override
  Widget build(BuildContext context) {
    final revNo = state.latestRevision?.revNo ?? sop.revNo;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.how_to_reg_outlined,
                color: sop.needsAck ? AppColors.warning : AppColors.success,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  AppText.t(
                    'إشعار القراءة - مراجعة $revNo',
                    'Read acknowledgement - rev $revNo',
                  ),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.spMax,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(
              'تسجيل القراءة يثبت أنك اطلعت على هذه المراجعة.',
              'Recording a read states that you have reviewed this revision.',
            ),
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          _AckButton(state: state, sop: sop),
        ],
      ),
    );
  }
}

class _AckButton extends StatelessWidget {
  const _AckButton({required this.state, required this.sop});

  final QcSopDetailState state;
  final QcSop sop;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcSopDetailCubit>();
    final who = TextEditingController();
    final name = TextEditingController();
    return FilledButton.tonal(
      onPressed: state.saving
          ? null
          : () async {
              // The reader is asked for here rather than read from a session
              // service this widget does not own: the screen stays testable and
              // the audit row still carries whatever was typed.
              // Adaptive chrome: same AppWindow on desktop, bottom sheet
              // on phones (a 440px dialog + keyboard never fit two fields).
              final submitted = await showAppOverlay<bool>(
                context,
                title: AppText.t('تسجيل القراءة', 'Acknowledge read'),
                icon: Icons.mark_email_read_outlined,
                size: AppWindowSize.sm,
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(AppText.t('إلغاء', 'Cancel')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(AppText.t('تأكيد', 'Confirm')),
                  ),
                ],
                builder: (context, close) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: InputDecoration(
                        labelText: AppText.t('الاسم', 'Name'),
                      ),
                    ),
                    TextField(
                      controller: who,
                      decoration: InputDecoration(
                        labelText: AppText.t('المعرّف', 'User id'),
                      ),
                    ),
                  ],
                ),
              );
              if (submitted != true) return;
              await cubit.acknowledge(
                userId: who.text.trim(),
                userName: name.text.trim(),
              );
            },
      child: Text(AppText.t('تسجيل القراءة', 'Acknowledge read')),
    );
  }
}

class _RevisionsCard extends StatelessWidget {
  const _RevisionsCard({required this.state, required this.sop});

  final QcSopDetailState state;
  final QcSop sop;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcSopDetailCubit>();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('سجل المراجعات', 'Revision history'),
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.spMax),
          ),
          const Divider(),
          if (state.revisions.isEmpty)
            Text(
              AppText.t('لا توجد مراجعات', 'No revisions yet'),
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            )
          else
            for (final rev in state.revisions)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SopPill(
                      'rev ${rev.revNo}',
                      rev.isPublishedRev ? AppColors.info : AppColors.textMuted,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rev.changeReason,
                            style: TextStyle(fontSize: 12.spMax),
                          ),
                          Text(
                            [
                              if (rev.editedByName.isNotEmpty) rev.editedByName,
                              if (rev.editedAt.isNotEmpty)
                                rev.editedAt.substring(0, 16),
                            ].join(' - '),
                            style: TextStyle(
                              fontSize: 11.spMax,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          if (sop.isPublished || sop.status == SopStatus.approved) ...[
            const Divider(),
            OutlinedButton.icon(
              onPressed: state.saving
                  ? null
                  : () async {
                      final reason = TextEditingController();
                      final ok = await showAppOverlay<bool>(
                        context,
                        title: AppText.t('مراجعة جديدة', 'New revision'),
                        icon: Icons.note_add_outlined,
                        size: AppWindowSize.sm,
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(context).pop(false),
                            child: Text(AppText.t('إلغاء', 'Cancel')),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.of(context).pop(true),
                            child: Text(AppText.t('حفظ', 'Save')),
                          ),
                        ],
                        builder: (context, close) => TextField(
                          controller: reason,
                          decoration: InputDecoration(
                            labelText: AppText.t(
                              'سبب التغيير',
                              'Change summary',
                            ),
                          ),
                        ),
                      );
                      if (ok != true) return;
                      await cubit.publishRevision(changeSummary: reason.text);
                    },
              icon: const Icon(Icons.note_add_outlined, size: 18),
              label: Text(AppText.t('إصدار مراجعة', 'Cut a revision')),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReadsCard extends StatelessWidget {
  const _ReadsCard({required this.state, required this.sop});

  final QcSopDetailState state;
  final QcSop sop;

  @override
  Widget build(BuildContext context) {
    if (!sop.needsAck && state.reads.isEmpty) return const SizedBox.shrink();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('من قرأ هذا الإجراء', 'Who has read this'),
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.spMax),
          ),
          const Divider(),
          if (state.reads.isEmpty)
            Text(
              AppText.t(
                'لم يسجل أحد القراءة بعد',
                'Nobody has acknowledged it yet',
              ),
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            )
          else
            for (final read in state.reads)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, size: 16),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        read.userName.isNotEmpty ? read.userName : read.userId,
                        style: TextStyle(fontSize: 12.spMax),
                      ),
                    ),
                    Text(
                      'rev ${read.revNo}'
                      '${read.readAt.isEmpty ? '' : '  ${read.readAt.substring(0, 10)}'}',
                      style: TextStyle(
                        fontSize: 11.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}


