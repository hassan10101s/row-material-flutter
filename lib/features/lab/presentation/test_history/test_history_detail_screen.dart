import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_format.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../cubit/test_history_cubit.dart';
import '../../domain/lab_result_repository.dart';

/// Detail + edit screen for one `lab_sample_tests` row.
///
/// Read-only header (analysis / source / time / tester / range state) on top,
/// then the fillable fields — sample name, result, entry code and every
/// dynamic value — each editable and saved back through
/// [LabResultRepository.updateSampleTest].
class TestHistoryDetailScreen extends StatefulWidget {
  final Map<String, dynamic> row;
  final bool fullScreen;
  const TestHistoryDetailScreen({
    super.key,
    required this.row,
    this.fullScreen = false,
  });

  /// Opens the detail for [row]: a dialog window on desktop, a full-screen
  /// route on phones. Returns true when the row was edited.
  static Future<bool> open(BuildContext context, Map<String, dynamic> row) async {
    final isDesktop =
        MediaQuery.sizeOf(context).width >= 800;
    if (isDesktop) {
      final edited = await showAppWindow<bool>(
        context,
        title: AppText.t('بيانات التحليل', 'Test details'),
        icon: Icons.science_outlined,
        maxWidth: 640,
        height: 720,
        child: TestHistoryDetailScreen(row: row),
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

  @override
  State<TestHistoryDetailScreen> createState() =>
      _TestHistoryDetailScreenState();
}

class _TestHistoryDetailScreenState extends State<TestHistoryDetailScreen> {
  late final TextEditingController _sample;
  late final TextEditingController _result;
  late final TextEditingController _entryCode;
  late final Map<String, TextEditingController> _dynamics;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _sample = TextEditingController(text: '${widget.row['sample_name'] ?? ''}');
    _result = TextEditingController(text: '${widget.row['result_text'] ?? ''}');
    _entryCode = TextEditingController(text: '${widget.row['entry_code'] ?? ''}');
    final raw = widget.row['dynamic_values'];
    final map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : jsonLoads('${widget.row['dynamic_values_json'] ?? ''}');
    _dynamics = {
      for (final e in map.entries)
        '${e.key}': TextEditingController(text: '${e.value ?? ''}'),
    };
  }

  @override
  void dispose() {
    _sample.dispose();
    _result.dispose();
    _entryCode.dispose();
    for (final c in _dynamics.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {'id': user.id};
  }

  Future<void> _save() async {
    final id = int.tryParse('${widget.row['id'] ?? ''}');
    if (id == null) return;
    if (_sample.text.trim().isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('اسم العينة مطلوب', 'Sample name is required.'),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = getIt<LabResultRepository>();
      await repo.updateSampleTest(
        id,
        sampleName: _sample.text.trim(),
        resultText: _result.text.trim(),
        entryCode: _entryCode.text.trim(),
        dynamicValues: {
          for (final e in _dynamics.entries) e.key: e.value.text.trim(),
        },
        user: _currentUserMap,
      );
      if (!mounted) return;
      AppFeedback.success(
        context,
        AppText.t('تم حفظ التعديلات', 'Changes saved.'),
      );
      try {
        // ignore: use_build_context_synchronously
        context.read<TestHistoryCubit>().load();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
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
    final body = SingleChildScrollView(
      padding: EdgeInsets.all(
        widget.fullScreen ? AppSpacing.pageMobile : AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${r['analysis_name'] ?? '-'}',
                        style: TextStyle(
                          fontSize: 16.spMax,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: stateColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${r['range_state'] ?? '-'}',
                        style: TextStyle(
                          color: stateColor,
                          fontSize: 11.spMax,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _info(
                  AppText.t('المصدر', 'Source'),
                  '${r['source_name'] ?? '-'}'
                  '${'${r['source_type'] ?? ''}'.isEmpty ? '' : ' (${r['source_type'] == 'product' ? 'منتج' : 'خام'})'}',
                ),
                _info(
                  AppText.t('التوقيت', 'Time'),
                  '${r['tested_at'] ?? '-'}',
                ),
                _info(
                  AppText.t('بواسطة', 'By'),
                  '${r['tested_by_name'] ?? '-'}',
                ),
                _info(AppText.t('النطاق', 'Range'), range),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  AppText.t('الخانات القابلة للتعبئة', 'Editable fields'),
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppField(
                  label: AppText.t('اسم العينة', 'Sample name'),
                  controller: _sample,
                  enabled: !_saving,
                ),
                const SizedBox(height: AppSpacing.md),
                AppField(
                  label:
                      '${AppText.t('النتيجة', 'Result')} (${r['analysis_unit'] ?? '%'})',
                  controller: _result,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppField(
                  label: AppText.t('كود الدخول', 'Entry code'),
                  controller: _entryCode,
                  enabled: !_saving,
                ),
                if (_dynamics.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    AppText.t('القيم الإضافية', 'Extra values'),
                    style: TextStyle(
                      fontSize: 13.spMax,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final e in _dynamics.entries) ...[
                    AppField(
                      label: e.key,
                      controller: e.value,
                      enabled: !_saving,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (widget.fullScreen) ...[
            // Phones: stacked full-width CTAs (52h touch target); a Row
            // with "حفظ التعديلات" + "إغلاق" squeezes both on 360dp.
            SizedBox(
              width: double.infinity,
              height: AppSpacing.mobileCtaHeight.h,
              child: AppButton(
                label: AppText.t('حفظ التعديلات', 'Save changes'),
                icon: Icon(Icons.check, size: 18.r),
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              height: AppSpacing.mobileCtaHeight.h,
              child: AppButton(
                style: AppButtonStyle.secondary,
                label: AppText.t('إغلاق', 'Close'),
                onPressed:
                    _saving ? null : () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ] else
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: AppText.t('حفظ التعديلات', 'Save changes'),
                    icon: Icon(Icons.check, size: 18.r),
                    loading: _saving,
                    onPressed: _saving ? null : _save,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                AppButton(
                  style: AppButtonStyle.secondary,
                  label: AppText.t('إغلاق', 'Close'),
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(false),
                ),
              ],
            ),
        ],
      ),
    );
    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppTopAppBar(
          title: AppText.t('بيانات التحليل', 'Test details'),
        ),
        body: SafeArea(child: body),
      );
    }
    return body;
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
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(fontSize: 13.spMax),
              ),
            ),
          ],
        ),
      );
}
