import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// One unit picker for the whole program, inheriting from `lab_units`.
///
/// [symbols] are the registry symbols (the Units table); every unit field in
/// the app — parameters, analyses, inventory, constants, product ranges,
/// checklist items, KPI targets — offers this same list. A symbol typed here
/// that is not in the list is still accepted: the repositories register it
/// into `lab_units` on save, so the Units table always holds every program
/// unit and the next picker offers it too.
class AppUnitField extends StatefulWidget {
  const AppUnitField({
    super.key,
    required this.controller,
    required this.symbols,
    this.label,
    this.onChanged,
    this.enabled = true,
    this.allowedUnits,
  });

  final TextEditingController controller;
  final List<String> symbols;
  final String? label;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  /// When provided, the suggestion chips offer only these units (e.g. the
  /// units fitting an inventory category). Free typing is still possible —
  /// the repository rejects a mismatching unit on save.
  final List<String>? allowedUnits;

  @override
  State<AppUnitField> createState() => _AppUnitFieldState();

  /// Symbols from `lab_units` rows, tolerating the map shape the cubits hold.
  static List<String> symbolsOf(List<Map<String, dynamic>> rows) => [
        for (final r in rows)
          if ('${r['symbol'] ?? ''}'.trim().isNotEmpty &&
              (r['is_active'] as num?)?.toInt() != 0)
            '${r['symbol']}'.trim(),
      ];
}

class _AppUnitFieldState extends State<AppUnitField> {
  bool _expanded = false;
  String _query = '';

  List<String> get _known {
    final allowed = widget.allowedUnits
        ?.map((s) => s.trim().toLowerCase())
        .toSet();
    final out = [
      for (final s in widget.symbols.map((s) => s.trim()).toSet())
        if (allowed == null || allowed.contains(s.toLowerCase())) s,
    ];
    // An allowed unit missing from the registry is still offered: the
    // repository registers it on save.
    if (allowed != null) {
      for (final a in widget.allowedUnits!) {
        final t = a.trim();
        if (t.isNotEmpty &&
            !out.any((s) => s.toLowerCase() == t.toLowerCase())) {
          out.add(t);
        }
      }
    }
    out.sort();
    return out;
  }

  List<String> get _matches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _known;
    return _known.where((s) => s.toLowerCase().contains(q)).toList();
  }

  bool get _isNew {
    final typed = widget.controller.text.trim();
    return typed.isNotEmpty &&
        !_known.any((s) => s.toLowerCase() == typed.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          enabled: widget.enabled,
          decoration: InputDecoration(
            labelText: widget.label ?? AppText.t('الوحدة', 'Unit'),
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              tooltip: AppText.t('اختيار وحدة', 'Pick a unit'),
              onPressed: widget.enabled
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              icon: Icon(
                _expanded
                    ? Icons.arrow_drop_up
                    : Icons.arrow_drop_down,
              ),
            ),
          ),
          onChanged: (v) {
            setState(() => _query = v);
            widget.onChanged?.call(v);
          },
        ),
        if (_isNew)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              AppText.t(
                'وحدة جديدة — ستُضاف لجدول الوحدات عند الحفظ',
                'New unit — will join the units table on save',
              ),
              style: TextStyle(
                fontSize: 11.spMax,
                color: AppColors.info,
              ),
            ),
          ),
        if (_expanded && widget.enabled) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final s in _matches)
                ActionChip(
                  label: Text(
                    s,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    widget.controller.text = s;
                    widget.onChanged?.call(s);
                    setState(() {
                      _query = s;
                      _expanded = false;
                    });
                  },
                ),
              if (_matches.isEmpty)
                Text(
                  AppText.t('لا توجد وحدة مطابقة', 'No matching unit'),
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}
