import 'package:flutter/services.dart';

String normalizeDecimalInput(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var text = value.trim().replaceAll('٫', '.').replaceAll(',', '.');
  for (var i = 0; i < 10; i++) {
    text = text.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
  }
  return text;
}

/// Rejects invalid edits as a whole, so pasting "12kg5" cannot become 125.
class DecimalInputFormatter extends TextInputFormatter {
  DecimalInputFormatter({this.signed = false});
  final bool signed;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = normalizeDecimalInput(newValue.text);
    final pattern = signed ? r'^-?\d*(?:\.\d*)?$' : r'^\d*(?:\.\d*)?$';
    if (!RegExp(pattern).hasMatch(text)) return oldValue;
    final number = double.tryParse(text);
    if (number != null && !number.isFinite) return oldValue;
    return newValue.copyWith(
      text: text,
      selection: TextSelection(
        baseOffset: newValue.selection.baseOffset.clamp(0, text.length),
        extentOffset: newValue.selection.extentOffset.clamp(0, text.length),
      ),
      composing: TextRange.empty,
    );
  }
}
