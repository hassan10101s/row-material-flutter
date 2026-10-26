import 'app_text_field.dart';
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
    this.controller,
    this.label,
    this.hint,
    this.prefixIcon = Icons.search,
    this.debounce = const Duration(milliseconds: 350),
    this.initialValue,
    this.autofocus = false,
    this.focusNode,
  });

  /// Fired once the user pauses typing for [debounce].
  final ValueChanged<String> onChanged;

  /// Optional caller-owned controller, so a page can read/clear the query
  /// (e.g. an empty-state "clear search" button) while the field keeps the
  /// same compact styling. When absent the field allocates its own.
  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final IconData prefixIcon;
  final Duration debounce;
  final String? initialValue;
  final bool autofocus;

  /// Caller-owned focus handle so page-level shortcuts (Ctrl+F) can move
  /// focus into the field. The caller disposes it, like its controllers.
  final FocusNode? focusNode;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  TextEditingController? _internalController;

  TextEditingController get _effectiveController =>
      widget.controller ??
      (_internalController ??= TextEditingController(
        text: widget.initialValue,
      ));

  @override
  void didUpdateWidget(covariant DebouncedSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _effectiveController.removeListener(_syncHasText);
      _internalController?.dispose();
      _internalController = null;
      _hasText = _effectiveController.text.isNotEmpty;
      _effectiveController.addListener(_syncHasText);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _effectiveController.removeListener(_syncHasText);
    _internalController?.dispose();
    super.dispose();
  }

  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = _effectiveController.text.isNotEmpty;
    _effectiveController.addListener(_syncHasText);
  }

  void _syncHasText() {
    if (!mounted) return;
    final has = _effectiveController.text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  void _onTextChanged(String value) {
    _syncHasText(); // immediate clear-suffix response
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, () {
      if (mounted) widget.onChanged(value);
    });
  }

  Timer? _debounceTimer;

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      controller: _effectiveController,
      focusNode: widget.focusNode,
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
                  _debounceTimer?.cancel();
                  _effectiveController.clear();
                  widget.onChanged('');
                },
                icon: const Icon(Icons.clear, size: 18),
              )
            : null,
      ),
    );
  }
}
