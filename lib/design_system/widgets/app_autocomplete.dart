import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

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
  final String emptyLabel;

  /// Human-readable label for the suffix caret, e.g. a localization string.
  final String dropdownLabel;

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
    this.emptyLabel = 'No matching option',
    this.dropdownLabel = 'Show options',
    this.controller,
    this.focusNode,
    this.optionBuilder,
  });

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

  @override
  void initState() {
    super.initState();
    // A picker opened with an existing committed choice must show it from the
    // very first frame, not only after the parent changes the selection.
    _resolveFieldText();
  }

  @override
  void didUpdateWidget(AppAutocomplete<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A committed choice is owned by the parent; keep the field in step when
    // it changes from outside (e.g. a "change X" action clears the selection).
    if (oldWidget.selected != widget.selected) {
      _resolveFieldText();
    }
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
    _focusNode.requestFocus();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final committed = widget.selected != null;
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
        final field = RawAutocomplete<T>(
          textEditingController: _controller,
          focusNode: _focusNode,
          displayStringForOption: widget.displayString,
          optionsBuilder: (builderValue) {
            // A committed value is a fact, not a query: typing into it would
            // silently edit what the user already confirmed.
            if (committed) return <T>[];
            final q = builderValue.text.trim().toLowerCase();
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
                  tooltip: widget.dropdownLabel,
                  onPressed: committed ? null : () => _openOptions(),
                  icon: Icon(
                    Icons.arrow_drop_down,
                    size: 24.r,
                    color: committed ? AppColors.textMuted : AppColors.primary,
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
                  borderSide: BorderSide(color: AppColors.primary, width: 1.6),
                ),
              ),
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                clipBehavior: Clip.antiAlias,
                color: AppColors.surface,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 280,
                    maxWidth: 420,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final option in options)
                        widget.optionBuilder?.call(
                              context,
                              option,
                              onSelected,
                            ) ??
                            ListTile(
                              dense: true,
                              title: Text(
                                widget.displayString(option),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => onSelected(option),
                            ),
                    ],
                  ),
                ),
              ),
            );
          },
          onSelected: widget.onSelected,
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
                widget.emptyLabel,
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
