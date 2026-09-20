import 'package:flutter/material.dart';

import '../feedback/app_feedback.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Labeled form field with error display (mirrors .field / .field-error).
class AppField extends StatelessWidget {
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
    assert(controller != null || initialValue != null);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveController = controller ?? TextEditingController(text: initialValue);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: effectiveController,
          onChanged: onChanged,
          obscureText: obscure,
          keyboardType: keyboardType,
          maxLines: maxLines,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            errorText: error,
            suffixIcon: suffix,
            suffixText: suffixText,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            filled: true,
            fillColor: AppColors.surface,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              borderSide: BorderSide(color: error != null ? AppColors.danger : AppColors.border),
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