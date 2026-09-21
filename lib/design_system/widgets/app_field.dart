import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../feedback/app_feedback.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Labeled form field with error display (mirrors .field / .field-error).
/// Owns an internal [TextEditingController] when none is provided so a
/// controller-less field (e.g. a search box) does not allocate a new
/// controller on every rebuild.
class AppField extends StatefulWidget {
  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final String? error;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final int maxLines;
  final Widget? suffix;
  final String? suffixText;

  AppField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.error,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.maxLines = 1,
    this.suffix,
    this.suffixText,
  }) {
    assert(controller != null || initialValue != null || onChanged != null);
  }

  @override
  State<AppField> createState() => _AppFieldState();
}

class _AppFieldState extends State<AppField> {
  TextEditingController? _internalController;

  TextEditingController get _effectiveController =>
      widget.controller ??
      (_internalController ??=
          TextEditingController(text: widget.initialValue));

  @override
  void didUpdateWidget(covariant AppField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _internalController?.dispose();
      _internalController = null;
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveController = _effectiveController;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax)),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: effectiveController,
          onChanged: widget.onChanged,
          obscureText: widget.obscure,
          keyboardType: widget.keyboardType,
          maxLines: widget.maxLines,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint,
            errorText: widget.error,
            suffixIcon: widget.suffix,
            suffixText: widget.suffixText,
            contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            filled: true,
            fillColor: AppColors.surface,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              borderSide: BorderSide(
                  color: widget.error != null ? AppColors.danger : AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              borderSide: BorderSide(color: AppColors.primary, width: 1.6),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              borderSide: BorderSide(color: AppColors.danger),
            ),
          ),
        ),
      ],
    );
  }
}

/// Convenience validate+show helpers used by screens.
class Validators {
  static void require(BuildContext context, String? value, String message) {
    if (value == null || value.trim().isEmpty) {
      AppFeedback.error(context, message);
    }
  }
}