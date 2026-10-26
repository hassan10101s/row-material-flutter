import 'package:flutter/material.dart';

import '../tokens/app_spacing.dart';

/// Shared select field, including selects whose options contain rich widgets.
/// Uses the same input theme as text/date/quantity fields and bounded menus.
class AppSelectField<T> extends StatelessWidget {
  const AppSelectField({
    super.key,
    this.initialValue,
    required this.items,
    required this.onChanged,
    this.decoration = const InputDecoration(),
    this.hint,
    this.validator,
    this.onSaved,
    this.autovalidateMode,
    this.isDense = true,
    this.isExpanded = true,
    this.menuMaxHeight = 320,
    this.selectedItemBuilder,
    this.style,
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final Widget? hint;
  final FormFieldValidator<T>? validator;
  final FormFieldSetter<T>? onSaved;
  final AutovalidateMode? autovalidateMode;
  final bool isDense;
  final bool isExpanded;
  final double menuMaxHeight;
  final DropdownButtonBuilder? selectedItemBuilder;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    initialValue: initialValue,
    items: items,
    onChanged: onChanged,
    decoration: decoration,
    hint: hint,
    validator: validator,
    onSaved: onSaved,
    autovalidateMode: autovalidateMode,
    isDense: isDense,
    isExpanded: isExpanded,
    menuMaxHeight: menuMaxHeight,
    borderRadius: BorderRadius.circular(AppRadii.sm),
    dropdownColor: Theme.of(context).colorScheme.surface,
    selectedItemBuilder: selectedItemBuilder,
    style: style ?? Theme.of(context).textTheme.bodyMedium,
  );
}
