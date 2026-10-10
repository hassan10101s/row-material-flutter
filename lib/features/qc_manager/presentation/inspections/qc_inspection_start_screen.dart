import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/auth/permissions.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../di/service_locator.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_entity_autocomplete.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_inspection.dart';
import '../../domain/qc_template.dart';
import '../cubit/qc_inspections_cubit.dart';
import 'qc_inspection_sheet_screen.dart';

/// Starts a new checklist execution.
///
/// Simplified form: only 3 fields are visible:
///   1. Checklist picker (required)
///   2. Lot / shipment number (optional, auto-generated if empty)
///   3. Quick note (optional)
class QcInspectionStartScreen extends StatefulWidget {
  const QcInspectionStartScreen({super.key});

  static Future<void> open(BuildContext context) {
    final cubit = context.read<QcInspectionsCubit>();
    if (cubit.state.startTemplates.isEmpty) {
      cubit.loadStartOptions();
    }
    return Navigator.of(context).push(
      appMaterialPageRoute<void>(
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: const QcInspectionStartScreen(),
        ),
      ),
    );
  }

  static bool get canStart => getIt<AuthGate>().canWrite(Permission.qcWrite);

  @override
  State<QcInspectionStartScreen> createState() =>
      _QcInspectionStartScreenState();
}

class _QcInspectionStartScreenState extends State<QcInspectionStartScreen> {
  final _lot = TextEditingController();
  final _remarks = TextEditingController();
  int? _templateId;
  bool _handled = false;

  @override
  void dispose() {
    _lot.dispose();
    _remarks.dispose();
    super.dispose();
  }

  QcTemplate? _selected(List<QcTemplate> templates) {
    for (final t in templates) {
      if (t.templateId == _templateId) return t;
    }
    return null;
  }

  void _start(BuildContext context, List<QcTemplate> templates) {
    final template = _selected(templates);
    if (template == null) {
      AppFeedback.error(
          context, AppText.t('اختر قائمة فحص', 'Pick a checklist'));
      return;
    }
    final user = getIt<AuthGate>().currentUser;
    if (user == null) {
      AppFeedback.error(
          context, AppText.t('انتهت الجلسة', 'Session expired'));
      return;
    }
    final now = DateTime.now();
    final lotRaw = _lot.text.trim();
    final lot = lotRaw.isNotEmpty
        ? lotRaw
        : 'LOT-${now.year}'
            '${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}'
            '-${now.hour.toString().padLeft(2, '0')}'
            '${now.minute.toString().padLeft(2, '0')}';
    final stamp = nowIso();
    context.read<QcInspectionsCubit>().startInspection(
      QcInspection(
        templateId: template.templateId ?? 0,
        templateVersion: template.version,
        refType: QcRefType.lot,
        refId: '',
        lotNo: lot,
        batchNo: '',
        poNo: '',
        dept: template.dept,
        site: template.site,
        status: QcInspectionStatus.inProgress,
        resultOverall: QcOverallResult.pending,
        inspectionDate: todayIso(),
        startAt: stamp,
        inspectorId: user.uid ?? '',
        inspectorName: user.displayName,
        remarks: _remarks.text.trim(),
        createdAt: stamp,
        updatedAt: stamp,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QcInspectionsCubit, QcInspectionsState>(
      listenWhen: (a, b) => a.startedId != b.startedId && b.startedId != null,
      listener: (context, state) {
        if (_handled) return;
        final id = state.startedId;
        if (id == null) return;
        _handled = true;
        final navigator = Navigator.of(context);
        navigator.pop();
        QcInspectionSheetScreen.open(navigator.context, inspectionId: id);
      },
      builder: (context, state) {
        final templates = state.startTemplates;
        final selected = _selected(templates);
        return Scaffold(
          appBar: AppTopAppBar(
              title: AppText.t('فحص جديد', 'New inspection')),
          body: templates.isEmpty
              ? AppEmptyState(
                  icon: Icons.checklist_outlined,
                  title: AppText.t(
                    'لا توجد قوائم فحص منشورة',
                    'No published checklists',
                  ),
                  subtitle: AppText.t(
                    'انشر قائمة فحص أولاً لبدء فحص',
                    'Publish a checklist before starting an inspection',
                  ),
                  action: FilledButton.tonal(
                    onPressed: () => context
                        .read<QcInspectionsCubit>()
                        .loadStartOptions(),
                    child: Text(AppText.t('إعادة المحاولة', 'Retry')),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    // ── 1. Checklist ─────────────────────────────────────────
                    _label(AppText.t('قائمة الفحص *', 'Checklist *')),
                    AppEntityAutocomplete(
                      options: [
                        for (final t in templates)
                          {
                            'id': t.templateId,
                            'code': t.code,
                            'name': t.name,
                          },
                      ],
                      selectedId: _templateId,
                      hint: AppText.t('ابحث باسم القائمة…', 'Search checklists…'),
                      prefixIcon: Icons.checklist_outlined,
                      displayOf: (t) => '${t['code']} — ${t['name']}',
                      filter: (t, q) => entityMatches(t, q, [
                        (r) => '${r['code'] ?? ''}',
                        (r) => '${r['name'] ?? ''}',
                      ]),
                      onSelected: (v) =>
                          setState(() => _templateId = (v as num).toInt()),
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        AppText.t(
                          'الإصدار ${selected.version}',
                          'Revision ${selected.version}',
                        ),
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12.spMax,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),

                    // ── 2. Lot number (optional, auto-generated) ─────────────
                    _label(AppText.t(
                      'رقم الشحنة / اللوط  (اختياري)',
                      'Shipment / Lot number  (optional)',
                    )),
                    AppField(
                      label: AppText.t(
                        'يُولَّد تلقائياً إذا تُرك فارغاً',
                        'Auto-generated if left empty',
                      ),
                      controller: _lot,
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    // ── 3. Quick note (optional) ─────────────────────────────
                    _label(AppText.t(
                      'ملاحظة سريعة  (اختياري)',
                      'Quick note  (optional)',
                    )),
                    AppField(
                      label: AppText.t('اكتب أي ملاحظة…', 'Any note…'),
                      controller: _remarks,
                      maxLines: 2,
                    ),
                    const SizedBox(height: AppSpacing.xl),

                    // ── Start button ─────────────────────────────────────────
                    FilledButton.icon(
                      onPressed: state.saving
                          ? null
                          : () => _start(context, templates),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        textStyle: TextStyle(
                          fontSize: 16.spMax,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      icon: state.saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 22),
                      label: Text(AppText.t('ابدأ الفحص', 'Start inspection')),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          text,
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
      );
}
