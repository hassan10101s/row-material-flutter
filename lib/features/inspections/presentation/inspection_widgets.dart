import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../app/auth_gate.dart';
import '../../../di/service_locator.dart';
import '../data/inspection_repo.dart';

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
  final nums = RegExp(r'\d+\.?\d*')
      .allMatches(reference)
      .map((m) => double.parse(m.group(0)!))
      .toList();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
        const SizedBox(height: AppSpacing.xxs),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      ],
    );
  }
}

/// Decision update dialog (status + conditional fields).
class DecisionDialog extends StatefulWidget {
  final int inspectionId;
  final Map<String, dynamic> inspection;
  const DecisionDialog({
    super.key,
    required this.inspectionId,
    required this.inspection,
  });

  @override
  State<DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<DecisionDialog> {
  final _repo = getIt<InspectionRepo>();
  late String _status =
      '${widget.inspection['decision_status'] ?? 'APPROVED'}';
  late final TextEditingController _reason =
      TextEditingController(text: '${widget.inspection['decision_reason'] ?? ''}');
  late final TextEditingController _followUp =
      TextEditingController(text: '${widget.inspection['follow_up_note'] ?? ''}');
  late final TextEditingController _rejected =
      TextEditingController(text: '${widget.inspection['rejected_quantity'] ?? ''}');
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
        UserContext(id: user.id, fullName: user.fullName, role: user.role),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تحديث القرار | Update decision'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _status,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'القرار | Decision', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'APPROVED', child: Text('قبول نهائي | Approved')),
                  DropdownMenuItem(
                      value: 'CONDITIONAL_APPROVAL', child: Text('قبول مشروط | Conditional')),
                  DropdownMenuItem(
                      value: 'PARTIAL_REJECTION', child: Text('رفض جزئي | Partial rejection')),
                  DropdownMenuItem(
                      value: 'FULL_REJECTION', child: Text('رفض كامل | Full rejection')),
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
                  decoration: const InputDecoration(
                    labelText: 'ملاحظة المتابعة | Follow-up note',
                    isDense: true,
                  ),
                ),
              ],
              if (_status == 'PARTIAL_REJECTION') ...[
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _rejected,
                  decoration: const InputDecoration(
                    labelText: 'الكمية المرفوضة | Rejected quantity',
                    isDense: true,
                  ),
                ),
              ],
              if (_status == 'PARTIAL_REJECTION' || _status == 'FULL_REJECTION') ...[
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _reason,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'سبب القرار | Decision reason',
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}