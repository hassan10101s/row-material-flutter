import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../../core/lab_result_format.dart';
import '../cubit/run_test_cubit.dart';
import '../cubit/test_history_cubit.dart';
import '../run_test/run_test_tab.dart';
import '../../domain/lab_local_repository.dart';
import '../../domain/lab_result_repository.dart';

/// Editor for one `lab_sample_tests` row.
///
/// Editing reuses the *same* sheet as a new run ([RunTestTab] in edit mode):
/// the analysis and source are history and stay fixed, the sample stays
/// editable, and the fillable fields (list → dropdown, fixed value →
/// read-only, linked → text field) behave exactly like the add form. Saving
/// goes through [LabResultRepository.updateSampleTest] — the analysis, source
/// and entry code are never rewritten.
class TestHistoryDetailScreen extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool fullScreen;
  const TestHistoryDetailScreen({
    super.key,
    required this.row,
    this.fullScreen = false,
  });

  /// Opens the editor for [row]: a dialog window on desktop, a full-screen
  /// route on phones. Returns true when the row was saved or deleted.
  static Future<bool> open(
    BuildContext context,
    Map<String, dynamic> row,
  ) async {
    final isDesktop = FormFactor.current.isDesktop;
    if (isDesktop) {
      final edited = await showAppWindow<bool>(
        context,
        title: AppText.t('تعديل التحليل', 'Edit test'),
        icon: Icons.science_outlined,
        maxWidth: 1040,
        height: 780,
        scrollBody: false,
        child: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: TestHistoryDetailScreen(row: row),
            ),
          ),
        ),
      );
      return edited ?? false;
    }
    final edited = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TestHistoryDetailScreen(row: row, fullScreen: true),
      ),
    );
    return edited ?? false;
  }

  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {'id': user.id, 'uid': user.uid};
  }

  Future<void> _delete(BuildContext context) async {
    final id = int.tryParse('${row['id'] ?? ''}');
    if (id == null) return;
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('حذف سجل التحليل', 'Delete test record'),
      message: AppText.t(
        'سيتم حذف هذا السجل من قائمة تحاليل المعمل ومزامنة الحذف.',
        'This test record will be removed and the deletion will be synchronized.',
      ),
      danger: true,
      confirmLabel: AppText.t('حذف السجل', 'Delete record'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await getIt<LabResultRepository>().deleteSampleTest(
        id,
        user: _currentUserMap,
      );
      if (!context.mounted) return;
      AppFeedback.success(
        context,
        AppText.t('تم حذف السجل', 'Record deleted.'),
      );
      try {
        context.read<TestHistoryCubit>().load();
      } catch (_) {}
      Navigator.of(context).pop(true);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Write affordances follow the same gate the repository enforces
    // (`labResultsUpdate`): without it the screen is strictly read-only, so a
    // viewer/lab member can inspect a record but never reach the write path.
    final canEdit = getIt<AuthGate>().canWrite(Permission.labResultsUpdate);
    final content = canEdit ? _editor(context) : _readOnly(context);
    if (fullScreen) {
      return Scaffold(
        appBar: AppTopAppBar(
          title: AppText.t('بيانات التحليل', 'Test details'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.pageMobile),
            child: content,
          ),
        ),
      );
    }
    return content;
  }

  /// The run sheet in edit mode. Same fields as "New test", analysis/source
  /// fixed, with Delete/Close beside Save.
  Widget _editor(BuildContext context) {
    return BlocProvider(
      create: (_) => RunTestCubit(
        config: getIt<LabConfigurationRepository>(),
        results: getIt<LabResultRepository>(),
        local: getIt<LabLocalRepository>(),
        editRow: row,
      )..load(),
      child: RunTestTab(
        onTestRun: () {},
        editRow: row,
        onDelete: () => _delete(context),
      ),
    );
  }

  Widget _readOnly(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${row['analysis_name'] ?? '-'}',
                style: TextStyle(
                  fontSize: 16.spMax,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _info(
                AppText.t('المصدر', 'Source'),
                '${row['source_name'] ?? '-'}',
              ),
              _info(
                AppText.t('العينة', 'Sample'),
                '${row['sample_name'] ?? '-'}',
              ),
              _info(
                AppText.t('النتيجة', 'Result'),
                formatLabResult(row['result_text']),
              ),
              _info(
                AppText.t('كود الدخول', 'Entry code'),
                '${row['entry_code'] ?? '-'}',
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            AppText.t(
              'العرض فقط — تعديل نتائج المعمل يتطلب صلاحية.',
              'Read-only — editing lab results requires permission.',
            ),
            style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          style: AppButtonStyle.secondary,
          label: AppText.t('إغلاق', 'Close'),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }

  Widget _info(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90.w,
          child: Text(
            label,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
        ),
        Expanded(
          child: Text(value, style: TextStyle(fontSize: 13.spMax)),
        ),
      ],
    ),
  );
}
