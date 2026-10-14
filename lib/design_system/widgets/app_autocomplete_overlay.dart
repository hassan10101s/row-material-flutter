import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Single source of truth for every autocomplete dropdown in the app.
///
/// The reference look is the sample-taker history field (آخذ العينة): the
/// overlay takes the full width of its field instead of a fixed narrow box,
/// so long Arabic names never squeeze. Any `Autocomplete` /
/// `RawAutocomplete` in the program must render through this file —
/// [AppAutocomplete] and [AppHistoryAutocomplete] already do — instead of
/// hand-rolling its own overlay or relying on the framework default.
class AppAutocompleteOverlay extends StatelessWidget {
  const AppAutocompleteOverlay({
    super.key,
    required this.fieldWidth,
    required this.itemCount,
    required this.itemBuilder,
    this.maxHeight = 280,
  });

  /// Width measured from the field itself (`LayoutBuilder` at the call site,
  /// falling back to [fallbackWidth] when constraints are unbounded).
  final double fieldWidth;

  /// Visible rows, already filtered by the caller.
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Cap for the popup height; the list scrolls past it.
  final double maxHeight;

  /// Fallback when the field cannot measure itself (unbounded constraints).
  static const double fallbackWidth = 280;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        color: AppColors.surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxHeight,
            maxWidth: fieldWidth,
          ),
          child: ListView.separated(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: itemCount,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: itemBuilder,
          ),
        ),
      ),
    );
  }
}

/// Full inheritance for raw `Autocomplete` call sites: measures its own
/// field and renders the shared overlay, so callers keep only their
/// filtering + field chrome and never hand-roll an options view.
///
/// Keeping the `LayoutBuilder` inside the design system (rather than at each
/// call site) also keeps feature files free of width reads.
class AppFullWidthAutocomplete<T extends Object> extends StatelessWidget {
  const AppFullWidthAutocomplete({
    super.key,
    required this.initialValue,
    required this.displayStringForOption,
    required this.optionsBuilder,
    required this.onSelected,
    required this.fieldViewBuilder,
    this.subtitleOf,
    this.maxHeight = 280,
  });

  final TextEditingValue initialValue;
  final String Function(T option) displayStringForOption;
  final Iterable<T> Function(TextEditingValue value) optionsBuilder;
  final ValueChanged<T> onSelected;
  final AutocompleteFieldViewBuilder fieldViewBuilder;
  final String Function(T option)? subtitleOf;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : AppAutocompleteOverlay.fallbackWidth;
        return Autocomplete<T>(
          initialValue: initialValue,
          displayStringForOption: displayStringForOption,
          optionsBuilder: optionsBuilder,
          onSelected: onSelected,
          optionsViewBuilder: autocompleteOverlayView<T>(
            fieldWidth: width,
            titleOf: displayStringForOption,
            subtitleOf: subtitleOf,
            maxHeight: maxHeight,
          ),
          fieldViewBuilder: fieldViewBuilder,
        );
      },
    );
  }
}

/// Convenience options-view for plain title/subtitle rows rendered inside
/// [AppAutocompleteOverlay]. Returns the `optionsViewBuilder` closure an
/// `Autocomplete` call site can pass directly, so raw usages inherit the
/// design-system look + full-field width with one line.
AutocompleteOptionsViewBuilder<T> autocompleteOverlayView<T extends Object>({
  required double fieldWidth,
  required String Function(T option) titleOf,
  String Function(T option)? subtitleOf,
  double maxHeight = 280,
  TextDirection? subtitleDirection,
}) {
  return (context, onSelected, options) {
    final items = options.toList();
    return AppAutocompleteOverlay(
      fieldWidth: fieldWidth,
      maxHeight: maxHeight,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final option = items[index];
        final subtitle = subtitleOf?.call(option) ?? '';
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(
            titleOf(option),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.spMax),
          ),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: subtitleDirection,
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
          onTap: () => onSelected(option),
        );
      },
    );
  };
}
