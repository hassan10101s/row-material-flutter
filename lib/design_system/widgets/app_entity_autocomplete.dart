import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_autocomplete.dart';

/// Searchable single-select over `Map<String, dynamic>` rows.
///
/// Thin adapter over the canonical [AppAutocomplete]: the caller keeps working
/// with ids (like every `DropdownButtonFormField<int>` this replaces) while
/// the user gets type-to-filter + empty-query-shows-all + clear affordance.
///
/// Why this exists: `run_test_tab`, QC start screens and material editors all
/// picked entities from unbounded lists with non-filterable dropdowns. A full
/// `DropdownMenuItem` list clips/overflows at scale and cannot be scanned;
/// this control filters in memory (repos are already in-memory) and shows a
/// two-line tile for rich rows (inspection records).
class AppEntityAutocomplete extends StatelessWidget {
  /// Candidate rows (fully loaded, in-memory).
  final List<Map<String, dynamic>> options;

  /// Currently selected id, or null while picking. Compared as strings so
  /// `int`/`String` id mismatches never strand the selection.
  final Object? selectedId;

  /// Reads the row id (default `row['id']`).
  final Object? Function(Map<String, dynamic> row) idOf;

  /// One-line label for the committed field value.
  final String Function(Map<String, dynamic> row) displayOf;

  /// Optional second line inside the option tile (supplier/vehicle/etc).
  final String Function(Map<String, dynamic> row)? subtitleOf;

  /// Whether [row] matches the trimmed, lowercased query.
  final bool Function(Map<String, dynamic> row, String query) filter;

  /// Called with the picked row id (parsed back to int when possible).
  final ValueChanged<dynamic> onSelected;

  /// Called when the user clears a committed choice (null = no clear button).
  final VoidCallback? onCleared;

  final String? label;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final String emptyLabel;
  final IconData? prefixIcon;
  final bool enabled;

  const AppEntityAutocomplete({
    super.key,
    required this.options,
    required this.selectedId,
    required this.displayOf,
    required this.filter,
    required this.onSelected,
    this.idOf = _defaultIdOf,
    this.subtitleOf,
    this.onCleared,
    this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.emptyLabel = 'لا توجد نتائج مطابقة',
    this.prefixIcon,
    this.enabled = true,
  });

  static Object? _defaultIdOf(Map<String, dynamic> row) => row['id'];

  Map<String, dynamic>? get _selected {
    if (selectedId == null) return null;
    final want = '${selectedId!}';
    for (final row in options) {
      if ('${idOf(row)}' == want) return row;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AbsorbPointer(
                absorbing: !enabled,
                child: Opacity(
                  opacity: enabled ? 1.0 : 0.55,
                  child: AppAutocomplete<Map<String, dynamic>>(
                    options: options,
                    selected: selected,
                    displayString: displayOf,
                    filter: filter,
                    emptyLabel: emptyLabel,
                    hint: hint,
                    prefixIcon: prefixIcon,
                    onSelected: (row) {
                      final id = idOf(row);
                      final asInt = int.tryParse('$id');
                      onSelected(asInt ?? id);
                    },
                    optionBuilder: (context, option, onPick) {
                      final subtitle = subtitleOf?.call(option) ?? '';
                      return ListTile(
                        dense: true,
                        title: Text(
                          displayOf(option),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: subtitle.isEmpty
                            ? null
                            : Text(
                                subtitle,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 11.spMax,
                                ),
                              ),
                        onTap: () => onPick(option),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (selected != null && onCleared != null) ...[
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                tooltip: 'مسح الاختيار',
                icon: const Icon(Icons.clear),
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onCleared : null,
              ),
            ],
          ],
        ),
        if (errorText != null) ...[
          Padding(
            padding: EdgeInsets.only(top: 4.h, left: 4.w),
            child: Text(
              errorText!,
              style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
            ),
          ),
        ] else if (helperText != null) ...[
          Padding(
            padding: EdgeInsets.only(top: 4.h, left: 4.w),
            child: Text(
              helperText!,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
          ),
        ],
      ],
    );
  }
}

/// Case-insensitive substring match over the given string getters.
/// Shared default so every picker filters the same way.
bool entityMatches(
  Map<String, dynamic> row,
  String query,
  List<String Function(Map<String, dynamic>)> getters,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  for (final get in getters) {
    if (get(row).toLowerCase().contains(q)) return true;
  }
  return false;
}
