import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Free-text field with history autocomplete (Vue parity).
///
/// The caller owns [controller] (validation, save and prefill keep working
/// unchanged); suggestions come from [options] (`{name, lastDate, uses}`
/// rows, most recent first, already de-duplicated). Typing a brand-new
/// value is always allowed — picking only fills the field.
///
/// Two-way bridge with `Autocomplete`'s internal controller, guarded
/// against echo loops: user typing flows inward→outward, programmatic
/// writes (edit-prefill, clear) flow outward→inward.
class AppHistoryAutocomplete extends StatefulWidget {
  /// The form's controller. Owned by the caller (never disposed here).
  final TextEditingController controller;

  /// History rows: `{name: String, lastDate: String, uses: int}`.
  final List<Map<String, dynamic>> options;

  final String label;
  final String? hint;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  const AppHistoryAutocomplete({
    super.key,
    required this.controller,
    required this.options,
    required this.label,
    this.hint,
    this.textInputAction = TextInputAction.next,
    this.onChanged,
    this.enabled = true,
  });

  @override
  State<AppHistoryAutocomplete> createState() =>
      _AppHistoryAutocompleteState();
}

class _AppHistoryAutocompleteState extends State<AppHistoryAutocomplete> {
  TextEditingController? _internal;
  bool _bridge = false;
  double _fieldWidth = 280;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onExternal);
  }

  @override
  void didUpdateWidget(covariant AppHistoryAutocomplete oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onExternal);
      widget.controller.addListener(_onExternal);
      _pushToInternal(widget.controller.text);
    }
  }

  @override
  void dispose() {
    _internal?.removeListener(_onInternal);
    widget.controller.removeListener(_onExternal);
    super.dispose();
  }

  void _attach(TextEditingController internal) {
    if (identical(_internal, internal)) return;
    _internal?.removeListener(_onInternal);
    _internal = internal;
    internal.addListener(_onInternal);
    // Fresh field (first build / rebuild): reflect the form value.
    if (internal.text != widget.controller.text) {
      _pushToInternal(widget.controller.text);
    }
  }

  void _onInternal() {
    if (_bridge) return;
    final text = _internal?.text ?? '';
    if (widget.controller.text == text) return;
    _bridge = true;
    widget.controller.text = text;
    _bridge = false;
    widget.onChanged?.call(text);
  }

  void _onExternal() {
    if (_bridge) return;
    _pushToInternal(widget.controller.text);
  }

  void _pushToInternal(String text) {
    final internal = _internal;
    if (internal == null || internal.text == text) return;
    _bridge = true;
    internal.text = text;
    _bridge = false;
  }

  Map<String, Map<String, dynamic>> get _byName => {
        for (final row in widget.options)
          '${row['name'] ?? ''}': row,
      };

  Iterable<String> _suggest(TextEditingValue value) {
    final seen = <String>{};
    final out = <String>[];
    final query = value.text.trim().toLowerCase();
    for (final row in widget.options) {
      final name = '${row['name'] ?? ''}'.trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      if (query.isEmpty || name.toLowerCase().contains(query)) {
        out.add(name);
      }
      if (out.length >= 8) break;
    }
    return out;
  }

  String _subtitle(String name) {
    final row = _byName[name];
    if (row == null) return '';
    final date = '${row['lastDate'] ?? ''}'.trim();
    final short = date.length >= 10 ? date.substring(0, 10) : date;
    final uses = (row['uses'] as num?)?.toInt() ?? 0;
    final last = short.isEmpty
        ? ''
        : '${AppText.t('آخر تعامل', 'Last used')}: $short';
    final count = uses > 1 ? ' • $uses ${AppText.t('مرات', 'times')}' : '';
    return '$last$count'.trim();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth.isFinite) {
              _fieldWidth = constraints.maxWidth;
            }
            return Autocomplete<String>(
              initialValue:
                  TextEditingValue(text: widget.controller.text),
              displayStringForOption: (option) => option,
              optionsBuilder: _suggest,
              onSelected: (selection) {
                // Autocomplete already set its field; mirror outward.
                _onInternal();
              },
              fieldViewBuilder:
                  (context, textController, focusNode, onSubmitted) {
                _attach(textController);
                return TextField(
                  controller: textController,
                  focusNode: focusNode,
                  enabled: widget.enabled,
                  textInputAction: widget.textInputAction,
                  onSubmitted: (_) => onSubmitted(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.hint,
                    border: const OutlineInputBorder(),
                    suffixIcon: widget.options.isEmpty
                        ? null
                        : Icon(
                            Icons.history,
                            size: 18.r,
                            color: AppColors.textMuted,
                          ),
                  ),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                final items = options.toList();
                return Align(
                  alignment: AlignmentDirectional.topStart,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.surface,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: 220.h,
                        maxWidth: _fieldWidth,
                      ),
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final name = items[index];
                          final subtitle = _subtitle(name);
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            title: Text(
                              name,
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
                                    textDirection: TextDirection.ltr,
                                    style: TextStyle(
                                      fontSize: 11.spMax,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                            onTap: () => onSelected(name),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
        if (widget.options.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            AppText.t(
              '${widget.options.length} من السجل — اكتب للبحث أو أدخل جديداً',
              '${widget.options.length} from history — type to search or enter a new one',
            ),
            style: TextStyle(
              fontSize: 11.spMax,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}
