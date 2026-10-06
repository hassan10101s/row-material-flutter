import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_entity_autocomplete.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_inspection.dart';
import '../domain/qc_template.dart';
import 'cubit/qc_inspections_cubit.dart';
import 'widgets/qc_pill.dart';
import 'qc_inspection_sheet_screen.dart';

/// Starts a new checklist execution.
///
/// Deliberately a form over the register's cubit rather than a cubit of its
/// own: the sheet it creates has to appear in the list underneath it, and a
/// second cubit would mean the same save-and-reload logic in two places.
///
/// On success it pops and hands the new id to [QcInspectionSheetScreen], so the
/// inspector lands on the sheet they just started instead of hunting for it.
class QcInspectionStartScreen extends StatefulWidget {
  const QcInspectionStartScreen({super.key});

  static Future<void> open(BuildContext context) {
    final cubit = context.read<QcInspectionsCubit>();
    // Loaded on demand rather than with the register: the checklist list is
    // only needed once someone actually opens this form.
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

  /// Whether this session may start an inspection at all.
  ///
  /// The repository refuses the write regardless; this only avoids offering a
  /// button that cannot do anything.
  static bool get canStart => getIt<AuthGate>().canWrite(Permission.qcWrite);

  @override
  State<QcInspectionStartScreen> createState() =>
      _QcInspectionStartScreenState();
}

class _QcInspectionStartScreenState extends State<QcInspectionStartScreen> {
  final _lot = TextEditingController();
  final _refId = TextEditingController();
  final _batch = TextEditingController();
  final _po = TextEditingController();
  final _remarks = TextEditingController();
  int? _templateId;
  String _refType = QcRefType.lot;
  bool _handled = false;

  @override
  void dispose() {
    _lot.dispose();
    _refId.dispose();
    _batch.dispose();
    _po.dispose();
    _remarks.dispose();
    super.dispose();
  }

  QcTemplate? _selected(List<QcTemplate> templates) {
    for (final t in templates) {
      if (t.templateId == _templateId) return t;
    }
    return null;
  }

  void _warn(BuildContext context, String message) {
    AppFeedback.error(context, message);
  }

  /// Builds the header row and hands it to the register.
  ///
  /// The form is *not* popped here: it stays up behind the repository call so
  /// the listener below can catch the result, and so a refusal leaves the typed
  /// values on screen to correct.
  void _start(BuildContext context, List<QcTemplate> templates) {
    final template = _selected(templates);
    if (template == null) {
      _warn(context, AppText.t('اختر قائمة فحص', 'Pick a checklist'));
      return;
    }
    if (_refType == QcRefType.lot && _lot.text.trim().isEmpty) {
      _warn(context, AppText.t('أدخل رقم اللوط', 'Enter a lot number'));
      return;
    }
    if (_refType != QcRefType.lot && _refId.text.trim().isEmpty) {
      _warn(
        context,
        AppText.t(
          'أدخل رقم ${QcPill.refTypeLabel(_refType)}',
          'Enter the ${QcPill.refTypeLabel(_refType)} number',
        ),
      );
      return;
    }
    // Stamped from the session rather than asked for: the person performing the
    // inspection is whoever is signed in, and a sheet whose inspector can be
    // mistyped is not a traceability record.
    final user = getIt<AuthGate>().currentUser;
    if (user == null) {
      _warn(context, AppText.t('انتهت الجلسة', 'Session expired'));
      return;
    }
    final stamp = nowIso();
    context.read<QcInspectionsCubit>().startInspection(
      QcInspection(
        templateId: template.templateId ?? 0,
        // Captured at start so publishing a revision later cannot change what
        // this sheet meant.
        templateVersion: template.version,
        refType: _refType,
        refId: _refId.text.trim(),
        lotNo: _lot.text.trim(),
        batchNo: _batch.text.trim(),
        poNo: _po.text.trim(),
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
        // Pop the form first, then push the sheet: popping last would take the
        // sheet down with the form that opened it.
        navigator.pop();
        QcInspectionSheetScreen.open(navigator.context, inspectionId: id);
      },
      builder: (context, state) {
        final templates = state.startTemplates;
        final selected = _selected(templates);
        return Scaffold(
          appBar: AppTopAppBar(title: AppText.t('فحص جديد', 'New inspection')),
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
                    onPressed: () =>
                        context.read<QcInspectionsCubit>().loadStartOptions(),
                    child: Text(AppText.t('إعادة المحاولة', 'Retry')),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    _label(AppText.t('قائمة الفحص', 'Checklist')),
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
                      hint: AppText.t(
                        'ابحث برقم أو اسم القائمة…',
                        'Search checklists…',
                      ),
                      prefixIcon: Icons.checklist_outlined,
                      displayOf: (t) => '${t['code']} — ${t['name']}',
                      filter: (t, q) => entityMatches(t, q, [
                        (r) => '${r['code'] ?? ''}',
                        (r) => '${r['name'] ?? ''}',
                      ]),
                      onSelected: (v) => setState(
                          () => _templateId = (v as num).toInt()),
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: AppSpacing.sm),
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
                    const SizedBox(height: AppSpacing.md),
                    _label(AppText.t('نوع المرجع', 'Reference type')),
                    DropdownButtonFormField<String>(
                      initialValue: _refType,
                      isExpanded: true,
                      items: [
                        for (final type in QcRefType.all)
                          DropdownMenuItem(
                            value: type,
                            child: Text(QcPill.refTypeLabel(type)),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _refType = v ?? QcRefType.other),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (_refType == QcRefType.lot)
                      AppField(
                        label: AppText.t('رقم اللوط', 'Lot number'),
                        controller: _lot,
                      )
                    else
                      AppField(
                        label: AppText.t(
                          'رقم ${QcPill.refTypeLabel(_refType)}',
                          '${QcPill.refTypeLabel(_refType)} number',
                        ),
                        controller: _refId,
                      ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: AppText.t('رقم الدفعة', 'Batch number'),
                      controller: _batch,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: AppText.t('أمر الشراء', 'Purchase order'),
                      controller: _po,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: AppText.t('ملاحظات', 'Remarks'),
                      controller: _remarks,
                      maxLines: 3,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton.icon(
                      onPressed: state.saving
                          ? null
                          : () => _start(context, templates),
                      icon: state.saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(AppText.t('بدء الفحص', 'Start')),
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
