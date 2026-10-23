import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_autocomplete_overlay.dart';

/// A type-to-search picker over an in-memory list, used everywhere the app
/// lets the user choose an existing entity (materials, products, analyses,
/// inventory).
///
/// This generalises the one hand-rolled `RawAutocomplete` that used to live in
/// `inspection_form_screen.dart`, so the search behaviour is defined once
/// instead of being copy-pasted into every entity picker:
///
///  * An empty query offers the whole list, so the control doubles as the
///    dropdown it replaced.
///  * Typing narrows by [filter]; a query with no hits shows [emptyLabel] as a
///    helper under the field, because this SDK's `RawAutocomplete` closes the
///    popup entirely the moment a query stops matching.
///  * Once [selected] is set the field becomes read-only and shows the chosen
///    option's display string, so a committed value cannot be half-edited.
///  * The trailing caret re-opens the list for the current query.
///
/// The field keeps looking like the app's `AppField` on purpose: the entity
/// concept (label above, "xxxx" and code in the option tiles) belongs to the
/// caller, not to this generic control.
class AppAutocomplete<T extends Object> extends StatefulWidget {
  /// Candidates; expected fully loaded, matching the app's in-memory repos.
  final List<T> options;

  /// The currently committed choice, or null while the user is picking.
  final T? selected;

  /// How an option renders as text, both in the field once committed and as
  /// the option list so the committed text and the list can be compared.
  final String Function(T option) displayString;

  /// Whether [option] matches the trimmed, lowercased query.
  final bool Function(T option, String query) filter;

  /// Called when the user commits an option from the list.
  final ValueChanged<T> onSelected;

  /// Placeholder shown when the field is empty.
  final String? hint;

  /// Leading icon inside the field.
  final IconData? prefixIcon;

  /// Text shown in place of the option list when nothing matches.
  final String? emptyLabel;

  /// Human-readable label for the suffix caret, e.g. a localization string.
  final String? dropdownLabel;

  /// Injected controller and focus node, mirroring the form-side lifecycle of
  /// the field they replace. Defaults to internally owned instances so the
  /// control is self-contained.
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Renders a single option row; defaults to a [ListTile].
  final Widget Function(BuildContext, T, AutocompleteOnSelected<T>)?
  optionBuilder;

  const AppAutocomplete({
    super.key,
    required this.options,
    required this.selected,
    required this.displayString,
    required this.filter,
    required this.onSelected,
    this.hint,
    this.prefixIcon,
    this.emptyLabel,
    this.dropdownLabel,
    this.controller,
    this.focusNode,
    this.optionBuilder,
  });

  /// Localized fallback when the caller passes no [emptyLabel].
  static String defaultEmptyLabel() =>
      AppText.t('لا توجد نتائج مطابقة', 'No matching option');

  /// Localized fallback when the caller passes no [dropdownLabel].
  static String defaultDropdownLabel() =>
      AppText.t('عرض الخيارات', 'Show options');

  @override
  State<AppAutocomplete<T>> createState() => _AppAutocompleteState<T>();
}

class _AppAutocompleteState<T extends Object>
    extends State<AppAutocomplete<T>> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  late final bool _ownsController = widget.controller == null;
  late final bool _ownsFocusNode = widget.focusNode == null;

  /// Width of the field itself, measured by the `LayoutBuilder` below so the
  /// overlay takes the full field width (sample-taker reference look).
  double _fieldWidth = AppAutocompleteOverlay.fallbackWidth;

  /// True while the user re-opened the list of a committed value. The stored
  /// choice is not cleared: the field just stops being read-only and offers the
  /// whole list again, and loses focus without a pick restores the committed
  /// text. Without this the caret was dead once a value was committed, so a
  /// picker whose first value is auto-selected (the lab sample picker) could
  /// never be changed without first clearing it.
  bool _reopening = false;

  @override
  void initState() {
    super.initState();
    // A picker opened with an existing committed choice must show it from the
    // very first frame, not only after the parent changes the selection.
    _resolveFieldText();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(AppAutocomplete<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A committed choice is owned by the parent; keep the field in step when
    // it changes from outside (e.g. a "change X" action clears the selection).
    if (oldWidget.selected != widget.selected) {
      _reopening = false;
      _resolveFieldText();
    }
  }

  /// Closing the list without picking must not leave the field blank: restore
  /// the committed display string.
  void _handleFocusChange() {
    if (_focusNode.hasFocus || !_reopening) return;
    setState(() => _reopening = false);
    _resolveFieldText();
  }

  void _resolveFieldText() {
    final desired = widget.selected == null
        ? ''
        : widget.displayString(widget.selected!);
    if (_controller.text != desired) {
      _controller.text = desired;
      _controller.selection = TextSelection.collapsed(offset: desired.length);
    }
  }

  void _openOptions() {
    // Re-opening a committed value offers the whole list again instead of
    // treating the committed text as an unchangeable query. The focus has to
    // happen after the rebuild that makes the field editable: doing it in the
    // same frame would be evaluated by the old (committed) options builder,
    // which returns nothing.
    if (widget.selected != null && !_reopening) {
      setState(() => _reopening = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_reopening) return;
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
        _focusNode.requestFocus();
      });
      return;
    }
    _focusNode.requestFocus();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (_ownsController) _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final committed = widget.selected != null && !_reopening;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        // RawAutocomplete only surfaces the overlay while options are
        // non-empty (`_canShowOptionsView`), so a query with no hits would
        // silently collapse it. Surface that as a helper under the field
        // instead of a popup the framework will not open.
        final query = value.text.trim().toLowerCase();
        final noMatch =
            !committed &&
            query.isNotEmpty &&
            widget.options
                .where((option) => widget.filter(option, query))
                .isEmpty;
        final field = LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth.isFinite) {
              _fieldWidth = constraints.maxWidth;
            }
            return RawAutocomplete<T>(
              textEditingController: _controller,
              focusNode: _focusNode,
              displayStringForOption: widget.displayString,
              optionsBuilder: (builderValue) {
                // A committed value is a fact, not a query: typing into it would
                // silently edit what the user already confirmed.
                if (committed) return <T>[];
                final q = builderValue.text.trim().toLowerCase();
                // While re-opening, the field still carries the committed
                // display string: that is not a query, so offer everything
                // until the user actually types something else.
                final committedText = widget.selected == null
                    ? ''
                    : widget.displayString(widget.selected!);
                if (_reopening && builderValue.text == committedText) {
                  return widget.options;
                }
                if (q.isEmpty) {
                  return widget.options;
                }
                return widget.options
                    .where((option) => widget.filter(option, q))
                    .toList(growable: false);
              },
              fieldViewBuilder: (context, controller, focusNode, _) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  readOnly: committed,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.hint,
                    prefixIcon: widget.prefixIcon != null
                        ? Icon(widget.prefixIcon, size: 20.r)
                        : null,
                    suffixIcon: IconButton(
                      tooltip:
                          widget.dropdownLabel ??
                          AppAutocomplete.defaultDropdownLabel(),
                      onPressed: _openOptions,
                      icon: Icon(
                        Icons.arrow_drop_down,
                        size: 24.r,
                        color: AppColors.primary,
                      ),
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12.w,
                      vertical: 10.h,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      borderSide: BorderSide(
                        color: AppColors.primary,
                        width: 1.6,
                      ),
                    ),
                  ),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                // Shared design-system overlay: full field width, one look
                // everywhere (see app_autocomplete_overlay.dart).
                final items = options.toList();
                final custom = widget.optionBuilder;
                if (custom != null) {
                  return AppAutocompleteOverlay(
                    fieldWidth: _fieldWidth,
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        custom(context, items[index], onSelected),
                  );
                }
                return autocompleteOverlayView<T>(
                  fieldWidth: _fieldWidth,
                  titleOf: widget.displayString,
                )(context, onSelected, items);
              },
              onSelected: (option) {
                if (_reopening) {
                  setState(() => _reopening = false);
                }
                widget.onSelected(option);
              },
            );
          },
        );

        if (!noMatch) {
          return field;
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            field,
            Padding(
              padding: EdgeInsets.only(top: 4.h, left: 4.w),
              child: Text(
                widget.emptyLabel ?? AppAutocomplete.defaultEmptyLabel(),
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
