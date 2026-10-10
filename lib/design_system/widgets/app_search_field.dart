import 'dart:async';

import 'package:flutter/material.dart';

/// A search field that debounces keystrokes before notifying.
///
/// Ledger searches hit SQLite (`LIMIT/OFFSET` list + count) on every query
/// change; without debouncing, fast typing on a phone fires a DB round-trip
/// per character and rebuilds the whole register per character. The delay
/// collapses a burst of keystrokes into a single query.
class DebouncedSearchField extends StatefulWidget {
  const DebouncedSearchField({
    super.key,
    required this.onChanged,
    this.label,
    this.hint,
    this.prefixIcon = Icons.search,
    this.debounce = const Duration(milliseconds: 350),
    this.initialValue,
    this.autofocus = false,
  });

  /// Fired once the user pauses typing for [debounce].
  final ValueChanged<String> onChanged;
  final String? label;
  final String? hint;
  final IconData prefixIcon;
  final Duration debounce;
  final String? initialValue;
  final bool autofocus;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  Timer? _timer;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onLocalChanged);
  }

  void _onLocalChanged() {
    final has = _controller.text.isNotEmpty;
    if (has != _hasText && mounted) setState(() => _hasText = has);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _timer?.cancel();
    _timer = Timer(widget.debounce, () {
      if (mounted) widget.onChanged(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: _onTextChanged,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
        prefixIcon: Icon(widget.prefixIcon),
        suffixIcon: _hasText
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _controller.clear();
                  widget.onChanged('');
                },
                icon: const Icon(Icons.clear, size: 18),
              )
            : null,
      ),
    );
  }
}
