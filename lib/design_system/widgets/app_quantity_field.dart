import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_field.dart';

/// Single source of truth for every quantity input in the program.
///
/// A quantity never accepts text: the soft keyboard is numeric AND an input
/// formatter strips any non-numeric character (letters, symbols) even when
/// pasted or typed from a hardware keyboard — `keyboardType` alone only
/// changes the on-screen keyboard and never blocks text.
///
/// Allowed characters are digits plus `.` / `,` as decimal separators, which
/// matches [Validators.numeric] (it strips commas before `double.tryParse`)
/// and every `double.tryParse` save path in the app.
///
/// Any quantity field anywhere (inspection quantity / rejected quantity,
/// inventory stock / minimum / adjustments, consumed-chemical amounts) must
/// use [AppQuantityField] — or at least [AppQuantityField.formatter] for raw
/// `TextField`s with custom decorations — instead of a bare `AppField` with
/// only a numeric keyboard.
class AppQuantityField extends StatelessWidget {
  /// Formatter shared by [AppQuantityField] and raw quantity `TextField`s.
  static final TextInputFormatter formatter = FilteringTextInputFormatter.allow(
    RegExp(r'[0-9.,]'),
  );

  /// Numeric soft keyboard shared by [AppQuantityField] and raw quantity
  /// `TextField`s.
  static const TextInputType keyboard = TextInputType.numberWithOptions(
    decimal: true,
  );

  const AppQuantityField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.error,
    this.hint,
    this.suffix,
    this.suffixText,
    this.validator,
    this.autovalidateMode,
    this.focusNode,
    this.textInputAction,
    this.onFieldSubmitted,
    this.enabled = true,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final String? error;
  final String? hint;
  final Widget? suffix;
  final String? suffixText;
  final String? Function(String? value)? validator;
  final AutovalidateMode? autovalidateMode;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final callerValidator = validator;
    return AppField(
      label: label,
      controller: controller,
      initialValue: initialValue,
      onChanged: onChanged,
      error: error,
      hint: hint,
      keyboardType: keyboard,
      inputFormatters: [formatter],
      suffix: suffix,
      suffixText: suffixText,
      // Empty stays valid (optional quantities); any non-empty value must
      // parse as a number.
      validator: callerValidator == null
          ? Validators.numeric
          : Validators.compose([callerValidator, Validators.numeric]),
      autovalidateMode: autovalidateMode,
      focusNode: focusNode,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      enabled: enabled,
      autofocus: autofocus,
    );
  }
}
