import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_button.dart';
import '../../core/constants/app_strings.dart';

/// Bulk-action bar for multi-row selection (the Vue register's gold bar).
///
/// Shown only while [selectedCount] > 0 — the owner hides it otherwise.
/// Mirrors the legacy app: a `محدد: N` badge, `Export as a Report (N)` and
/// `Export labels (N)` with per-action busy states, and `إلغاء التحديد`.
/// Busy flags live here (like Vue's `actionBusy`) so stateless screens and
/// both form factors share the exact behavior; errors are reported by the
/// callbacks, which keep the selection on failure and clear it on success.
class SelectionActionBar extends StatefulWidget {
  final int selectedCount;
  final Future<void> Function() onExportReports;
  final Future<void> Function() onExportLabels;
  final VoidCallback onClear;

  const SelectionActionBar({
    super.key,
    required this.selectedCount,
    required this.onExportReports,
    required this.onExportLabels,
    required this.onClear,
  });

  @override
  State<SelectionActionBar> createState() => _SelectionActionBarState();
}

class _SelectionActionBarState extends State<SelectionActionBar> {
  bool _busyReports = false;
  bool _busyLabels = false;

  bool get _busy => _busyReports || _busyLabels;

  Future<void> _run(Future<void> Function() job, bool reports) async {
    if (_busy) return;
    setState(() {
      if (reports) {
        _busyReports = true;
      } else {
        _busyLabels = true;
      }
    });
    try {
      await job();
    } finally {
      if (mounted) {
        setState(() {
          if (reports) {
            _busyReports = false;
          } else {
            _busyLabels = false;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.selectedCount;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.25),
        ),
      ),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${AppText.t('محدد', 'Selected')}: $n',
              style: TextStyle(
                fontSize: 12.spMax,
                fontWeight: FontWeight.w700,
                color: AppColors.textStrong,
              ),
            ),
          ),
          AppButton(
            small: true,
            style: AppButtonStyle.accent,
            icon: Icon(Icons.picture_as_pdf_outlined, size: 16.r),
            label: _busyReports
                ? AppText.t('جاري التصدير...', 'Exporting...')
                : '${AppText.t('تصدير تقرير', 'Export report')} ($n)',
            loading: _busyReports,
            onPressed: _busy
                ? null
                : () => _run(widget.onExportReports, true),
          ),
          AppButton(
            small: true,
            style: AppButtonStyle.secondary,
            icon: Icon(Icons.label_outline, size: 16.r),
            label: _busyLabels
                ? AppText.t('جاري التصدير...', 'Exporting...')
                : '${AppText.t('تصدير ملصقات', 'Export labels')} ($n)',
            loading: _busyLabels,
            onPressed: _busy
                ? null
                : () => _run(widget.onExportLabels, false),
          ),
          AppButton(
            small: true,
            style: AppButtonStyle.secondary,
            icon: Icon(Icons.close, size: 16.r),
            label: AppText.t('إلغاء التحديد', 'Clear selection'),
            onPressed: _busy ? null : widget.onClear,
          ),
        ],
      ),
    );
  }
}
