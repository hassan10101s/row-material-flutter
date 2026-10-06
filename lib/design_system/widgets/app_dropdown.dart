import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';

/// One option of [AppDropdown].
class AppDropdownItem<T> {
  const AppDropdownItem({
    required this.value,
    required this.label,
    this.enabled = true,
  });

  final T value;
  final String label;
  final bool enabled;
}

/// A [DropdownButtonFormField] that can never throw
/// `There should be exactly one item with [DropdownButton]'s value`.
///
/// Reference data is edited independently of the rows that point at it: a
/// parameter/analysis a material still references can be deleted or retyped,
/// leaving a dangling id behind. A plain dropdown then crashes the whole
/// editor on open. [AppDropdown] instead:
///
/// * de-duplicates options by value (duplicates crash the same way);
/// * appends a disabled `⚠ deleted (id)` option whenever [value] matches no
///   option, so the stale reference stays visible instead of exploding, and
///   saving surfaces the form's own friendly validation message.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelText,
    this.hintText,
    this.errorText,
    this.isDense = true,
    this.missingLabel,
  });

  final T? value;
  final List<AppDropdownItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? labelText;
  final String? hintText;
  final String? errorText;
  final bool isDense;

  /// Label for the synthetic option shown for a dangling [value].
  final String Function(T missing)? missingLabel;

  static String _defaultMissingLabel(Object? missing) =>
      AppText.t('⚠ عنصر محذوف ($missing)', '⚠ Deleted item ($missing)');

  @override
  Widget build(BuildContext context) {
    // First occurrence wins: duplicate values crash DropdownButton the same
    // way a missing value does.
    final seen = <T>[];
    final deduped = <AppDropdownItem<T>>[];
    for (final item in items) {
      if (seen.contains(item.value)) continue;
      seen.add(item.value);
      deduped.add(item);
    }
    final effective = List<AppDropdownItem<T>>.of(deduped);
    final current = value;
    final missing = missingLabel;
    if (current != null && !seen.contains(current)) {
      effective.add(
        AppDropdownItem<T>(
          value: current,
          label: missing != null
              ? missing(current)
              : _defaultMissingLabel(current),
          enabled: false,
        ),
      );
    }
    return DropdownButtonFormField<T>(
      initialValue: value,
      isDense: isDense,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: isDense,
        labelText: labelText,
        errorText: errorText,
        border: const OutlineInputBorder(),
      ),
      hint: hintText == null
          ? null
          : Text(hintText!, overflow: TextOverflow.ellipsis),
      items: [
        for (final item in effective)
          DropdownMenuItem<T>(
            value: item.value,
            enabled: item.enabled,
            child: Text(item.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
