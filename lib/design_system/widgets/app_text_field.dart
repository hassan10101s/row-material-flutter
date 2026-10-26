import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The counterpart of `AppField` for inline labels. Labels, helper text and
/// adornments are slots; the theme owns every field's geometry and states.
/// Keeps TextField's editing contract for formula, search and inline inputs.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.style,
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.maxLines = 1,
    this.minLines,
    this.enabled,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextStyle? style;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final bool autofocus;
  final bool readOnly;
  final bool obscureText;
  final int? maxLines;
  final int? minLines;
  final bool? enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final GestureTapCallback? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    focusNode: focusNode,
    decoration: decoration,
    keyboardType: keyboardType,
    textInputAction: textInputAction,
    style: style ?? Theme.of(context).textTheme.bodyMedium,
    textAlign: textAlign,
    textDirection: textDirection,
    autofocus: autofocus,
    readOnly: readOnly,
    obscureText: obscureText,
    maxLines: maxLines,
    minLines: minLines,
    enabled: enabled,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    onEditingComplete: onEditingComplete,
    onTap: onTap,
    inputFormatters: inputFormatters,
    textCapitalization: textCapitalization,
  );
}
