import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../app/auth_gate.dart';
import '../../../../../di/service_locator.dart';
import '../../../domain/inspection_repository.dart';

/// Result of comparing a result against its reference bound.
class CheckResult {
  final bool? pass;
  final String note;
  const CheckResult({required this.pass, required this.note});
}

/// Simple bound evaluation against reference text like `1-2`, `>5`, `<5`.
CheckResult checkResultPass({
  required String reference,
  required String value,
  required bool numeric,
}) {
  final vText = value.trim();
  if (!numeric || vText.isEmpty) return const CheckResult(pass: null, note: '');
  final v = double.tryParse(vText.replaceAll(',', '.'));
  if (v == null) return const CheckResult(pass: null, note: '');
  final nums = RegExp(
    r'\d+\.?\d*',
  ).allMatches(reference).map((m) => double.parse(m.group(0)!)).toList();
  bool? pass;
  if (nums.length >= 2) {
    final lower = nums[0] < nums[1] ? nums[0] : nums[1];
    final upper = nums[0] < nums[1] ? nums[1] : nums[0];
    pass = v >= lower && v <= upper;
  } else if (nums.length == 1) {
    final n = nums[0];
    if (reference.contains('<')) {
      pass = v <= n;
    } else if (reference.contains('>')) {
      pass = v >= n;
    } else {
      pass = (v - n).abs() < 1e-9;
    }
  }
  return CheckResult(pass: pass, note: reference);
}

/// Info field label + value.
class InfoItem extends StatelessWidget {
  final String label;
  final String value;
  const InfoItem({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    // Lives inside a `Wrap`: without its own width cap a long value
    // (supplier, batch, taker names) stretches the Wrap child and clips
    // half the text on 400dp phones. Values wrap to 3 lines max.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.spMax),
          ),
        ],
      ),
    );
  }
}

/// Decision update form (status + conditional fields), shared chrome-free
/// by the desktop dialog and the mobile full-screen route.
///
/// [windowed] true wraps the fields in the pre-split [AppWindow] (desktop,
/// pixel-identical); false renders the fields with an in-content 52h
/// action bar (mobile route). One state, one save, one spinner.
class DecisionForm extends StatefulWidget {
  final int inspectionId;
  final Map<String, dynamic> inspection;
  final bool windowed;
  const DecisionForm({
    super.key,
    required this.inspectionId,
    required this.inspection,
    this.windowed = true,
  });

  @override
  State<DecisionForm> createState() => DecisionFormState();
}

class DecisionFormState extends State<DecisionForm> {
  final _repo = getIt<InspectionRepository>();
  late String _status = '${widget.inspection['decision_status'] ?? 'APPROVED'}';
  late final TextEditingController _reason = TextEditingController(
    text: '${widget.inspection['decision_reason'] ?? ''}',
  );
  late final TextEditingController _followUp = TextEditingController(
    text: '${widget.inspection['follow_up_note'] ?? ''}',
  );
  late final TextEditingController _rejected = TextEditingController(
    text: '${widget.inspection['rejected_quantity'] ?? ''}',
  );
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    _followUp.dispose();
    _rejected.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final user = getIt<AuthGate>().currentUser;
      if (user == null) {
        if (mounted) Navigator.of(context).pop(false);
        return;
      }
      await _repo.updateStatus(
        widget.inspectionId,
        {
          'decision_status': _status,
          'decision_reason': _reason.text.trim(),
          'follow_up_note': _followUp.text.trim(),
          'rejected_quantity': _rejected.text.trim(),
        },
        UserContext(
          id: user.id,
          uid: user.uid,
          fullName: user.fullName,
          role: user.role,
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A legacy `decision_status` in the row used to crash this dialog on open
    // (`There should be exactly one item...`); [AppDropdown] shows it as a
    // disabled row until a valid decision is picked.
    final fields = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppDropdown<String>(
          value: _status,
          labelText: AppText.t('القرار', 'Decision'),
          items: [
            AppDropdownItem(
              value: 'APPROVED',
              label: AppText.t('قبول نهائي', 'Approved'),
            ),
            AppDropdownItem(
              value: 'CONDITIONAL_APPROVAL',
              label: AppText.t('قبول مشروط', 'Conditional'),
            ),
            AppDropdownItem(
              value: 'PARTIAL_REJECTION',
              label: AppText.t('رفض جزئي', 'Partial rejection'),
            ),
            AppDropdownItem(
              value: 'FULL_REJECTION',
              label: AppText.t('رفض كامل', 'Full rejection'),
            ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _status = v);
          },
        ),
        if (_status == 'CONDITIONAL_APPROVAL') ...[
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _followUp,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: AppText.t('ملاحظة المتابعة', 'Follow-up note'),
              isDense: true,
            ),
          ),
        ],
        if (_status == 'PARTIAL_REJECTION') ...[
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _rejected,
            decoration: InputDecoration(
              labelText: AppText.t('الكمية المرفوضة', 'Rejected quantity'),
              isDense: true,
            ),
          ),
        ],
        if (_status == 'PARTIAL_REJECTION' ||
            _status == 'FULL_REJECTION') ...[
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _reason,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: AppText.t('سبب القرار', 'Decision reason'),
              isDense: true,
            ),
          ),
        ],
      ],
    );
    if (!widget.windowed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          fields,
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: AppSpacing.mobileCtaHeight.h,
                  child: OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Text(AppText.t('إلغاء', 'Cancel')),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: AppSpacing.mobileCtaHeight.h,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? SizedBox(
                            width: 18.r,
                            height: 18.r,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(AppStrings.save),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return AppWindow(
      title: AppText.t('تحديث القرار', 'Update decision'),
      icon: Icons.rule_outlined,
      size: AppWindowSize.sm,
      maxWidth: 460,
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
      child: fields,
    );
  }
}
