import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../feedback/app_feedback.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Labeled form field with error display (mirrors .field / .field-error).
/// Owns an internal [TextEditingController] when none is provided so a
/// controller-less field (e.g. a search box) does not allocate a new
/// controller on every rebuild.
///
/// Form integration: pass [validator] inside a [Form] to get inline errors +
/// `AutovalidateMode` instead of the legacy single-toast `Validators.require`
/// flow. Without a [Form] ancestor the [error] prop still works as before.
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
  final String? Function(String? value)? validator;
  final AutovalidateMode? autovalidateMode;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final bool autofocus;
  final TextCapitalization textCapitalization;

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
    this.validator,
    this.autovalidateMode,
    this.focusNode,
    this.textInputAction,
    this.onFieldSubmitted,
    this.inputFormatters,
    this.enabled = true,
    this.autofocus = false,
    this.textCapitalization = TextCapitalization.none,
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
    final repoError = widget.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax)),
        const SizedBox(height: AppSpacing.xs),
        TextFormField(
          controller: effectiveController,
          onChanged: widget.onChanged,
          obscureText: widget.obscure,
          keyboardType: widget.keyboardType,
          maxLines: widget.maxLines,
          focusNode: widget.focusNode,
          textInputAction: widget.textInputAction,
          onFieldSubmitted: widget.onFieldSubmitted,
          inputFormatters: widget.inputFormatters,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          textCapitalization: widget.textCapitalization,
          autovalidateMode: widget.autovalidateMode,
          validator: (value) {
            // Manual server-side error wins when present; otherwise run the
            // Form validator so both flows share one error slot.
            if (repoError != null) return repoError;
            return widget.validator?.call(value);
          },
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint,
            errorText: widget.validator == null ? repoError : null,
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

  /// Pure Form validators (return error string, null when valid).
  static String? required(String? value, [String message = 'هذا الحقل مطلوب']) {
    if (value == null || value.trim().isEmpty) return message;
    return null;
  }

  static String? Function(String?) minLength(int min,
      [String? message]) {
    return (value) {
      if (value == null || value.trim().length < min) {
        return message ?? 'الحد الأدنى $min أحرف';
      }
      return null;
    };
  }

  static String? numeric(String? value, [String message = 'رقم غير صالح']) {
    if (value == null || value.trim().isEmpty) return null;
    final normalized = value.trim().replaceAll(',', '');
    if (double.tryParse(normalized) == null) return message;
    return null;
  }

  /// Compose several validators: first error wins.
  static String? Function(String?) compose(
      List<String? Function(String?)> validators) {
    return (value) {
      for (final v in validators) {
        final error = v(value);
        if (error != null) return error;
      }
      return null;
    };
  }
}