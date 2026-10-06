import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';

/// Date input that supports both typing an ISO date and choosing it visually.
///
/// The stored value remains `YYYY-MM-DD`, while the calendar button works on
/// desktop, tablet and mobile without requiring users to type a date format.
class AppDateField extends StatelessWidget {
  const AppDateField({
    super.key,
    required this.label,
    required this.controller,
    this.onChanged,
    this.validator,
    this.errorText,
    this.firstDate,
    this.lastDate,
    this.enabled = true,
    this.isDense = true,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final String? errorText;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool enabled;
  final bool isDense;

  @override
  Widget build(BuildContext context) {
    final now = DateUtils.dateOnly(DateTime.now());
    final minimum = DateUtils.dateOnly(firstDate ?? DateTime(1900));
    final maximum = DateUtils.dateOnly(lastDate ?? DateTime(2100));
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.datetime,
      validator: validator,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'YYYY-MM-DD',
        errorText: errorText,
        isDense: isDense,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: AppText.t('اختيار التاريخ', 'Choose date'),
          onPressed: enabled
              ? () async {
                  final text = controller.text.trim();
                  final parsed = DateTime.tryParse(
                    text.length >= 10 ? text.substring(0, 10) : text,
                  );
                  final initial = DateUtils.dateOnly(parsed ?? now);
                  final boundedInitial = initial.isBefore(minimum)
                      ? minimum
                      : initial.isAfter(maximum)
                      ? maximum
                      : initial;
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: boundedInitial,
                    firstDate: minimum,
                    lastDate: maximum,
                  );
                  if (picked == null) return;
                  final value = DateUtils.dateOnly(picked)
                      .toIso8601String()
                      .substring(0, 10);
                  controller.value = TextEditingValue(
                    text: value,
                    selection: TextSelection.collapsed(offset: value.length),
                  );
                  onChanged?.call(value);
                }
              : null,
          icon: const Icon(Icons.calendar_month_outlined),
        ),
      ),
    );
  }
}
