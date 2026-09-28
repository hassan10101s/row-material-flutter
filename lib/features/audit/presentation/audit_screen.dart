import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import 'audit_controller.dart';

/// Read-only audit trail (plan §14-P9.2).
///
/// Filters: entity type, action, date range. Paged. Gated by `audit.read`.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key, required this.controller});

  final AuditController controller;

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  @override
  void initState() {
    super.initState();
    // First page as soon as the screen is on screen; the state itself is
    // rendered by the ListenableBuilder below.
    widget.controller.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
          appBar: AppTopBarFallback(
            title: AppText.t('سجل التدقيق', 'Audit trail'),
            onRefresh: controller.load,
          ),
          body: !controller.canRead
              ? AppEmptyState(
                  icon: Icons.lock_outline,
                  title: AppText.t('غير مصرح', 'Not permitted'),
                  subtitle: AppText.t(
                    'سجل التدقيق يتطلب صلاحية مراجعة السجلات',
                    'Reading the audit trail requires the audit.read permission',
                  ),
                )
              : Column(
                  children: [
                    _Filters(controller: controller),
                    Expanded(child: _Body(controller: controller)),
                    _Pager(controller: controller),
                  ],
                ),
        );
      },
    );
  }
}

/// Minimal app bar: the shell owns the real one, and a screen must still have a
/// title when it is pushed directly (tests, deep links).
class AppTopBarFallback extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBarFallback({super.key, required this.title, this.onRefresh});

  final String title;
  final Future<void> Function()? onRefresh;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      actions: [
        if (onRefresh != null)
          IconButton(
            tooltip: AppText.t('تحديث', 'Refresh'),
            onPressed: () => onRefresh!(),
            icon: const Icon(Icons.refresh),
          ),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.controller});

  final AuditController controller;

  Future<void> _pickDate(BuildContext context, {required bool isFrom}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDate: now,
    );
    if (picked == null) return;
    // The filter is inclusive on both ends: "from 12/03" must include the whole
    // of the 12th, and "to 12/03" the whole of that day too.
    final filter = isFrom
        ? controller.filter.copyWith(from: DateTime(picked.year, picked.month, picked.day))
        : controller.filter.copyWith(
            to: DateTime(picked.year, picked.month, picked.day, 23, 59, 59));
    await controller.applyFilter(filter);
  }

  @override
  Widget build(BuildContext context) {
    final filter = controller.filter;
    return AppCard(
      margin: const EdgeInsets.all(AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Dropdown(
            label: AppText.t('نوع الكيان', 'Entity'),
            value: filter.entityType,
            items: controller.page.entityTypes,
            allLabel: AppText.t('الكل', 'All'),
            onChanged: (v) => controller.applyFilter(
              v == null
                  ? controller.filter.copyWith(clearEntityType: true)
                  : controller.filter.copyWith(entityType: v),
            ),
          ),
          _Dropdown(
            label: AppText.t('الإجراء', 'Action'),
            value: filter.action,
            items: controller.page.actions,
            allLabel: AppText.t('الكل', 'All'),
            onChanged: (v) => controller.applyFilter(
              v == null
                  ? controller.filter.copyWith(clearAction: true)
                  : controller.filter.copyWith(action: v),
            ),
          ),
          AppButton(
            small: true,
            label: filter.from == null
                ? AppText.t('من تاريخ', 'From date')
                : _date(filter.from!),
            icon: const Icon(Icons.date_range_outlined, size: 16),
            onPressed: () => _pickDate(context, isFrom: true),
          ),
          AppButton(
            small: true,
            label: filter.to == null
                ? AppText.t('إلى تاريخ', 'To date')
                : _date(filter.to!),
            icon: const Icon(Icons.event_outlined, size: 16),
            onPressed: () => _pickDate(context, isFrom: false),
          ),
          if (!filter.isEmpty)
            AppButton(
              small: true,
              style: AppButtonStyle.ghost,
              label: AppText.t('مسح', 'Clear'),
              onPressed: controller.clearFilters,
            ),
        ],
      ),
    );
  }

  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.allLabel,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> items;
  final String allLabel;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          isExpanded: true,
          hint: Text(allLabel, style: TextStyle(fontSize: 12.spMax)),
          items: [
            DropdownMenuItem<String>(value: null, child: Text(allLabel)),
            for (final item in items)
              DropdownMenuItem<String>(value: item, child: Text(item)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({required this.controller});

  final AuditController controller;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  String? _shownError;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final error = widget.controller.error;
    if (error == null) {
      _shownError = null;
      return;
    }
    if (error == _shownError) return;
    _shownError = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppFeedback.error(context, error);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.loading && controller.page.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.error != null) {
      return AppEmptyState(
        icon: Icons.error_outline,
        title: AppText.t('تعذّر تحميل السجل', 'Could not load the trail'),
      );
    }
    if (controller.page.entries.isEmpty) {
      return AppEmptyState(
        icon: Icons.history,
        title: AppText.t('لا توجد سجلات', 'No entries'),
        subtitle: AppText.t(
          'لا توجد سجلات مطابقة للمرشحات الحالية',
          'No entry matches the current filters',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      itemCount: controller.page.entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.xs),
      itemBuilder: (context, index) => _Row(entry: controller.page.entries[index]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry});

  final Map<String, Object?> entry;

  @override
  Widget build(BuildContext context) {
    final action = '${entry['action'] ?? ''}';
    final entityType = '${entry['entity_type'] ?? ''}';
    return AppCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  action,
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.spMax),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${entry['occurred_at'] ?? ''}',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
              ),
            ],
          ),
          Text(
            '$entityType · ${entry['entity_id'] ?? ''}',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '${AppText.t('بواسطة', 'by')} ${entry['user_name'] ?? entry['user_id'] ?? '-'}'
            ' · ${entry['device_id'] ?? '-'}',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
            overflow: TextOverflow.ellipsis,
          ),
          if (entry['details_json'] != null && '${entry['details_json']}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${entry['details_json']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.spMax, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({required this.controller});

  final AuditController controller;

  @override
  Widget build(BuildContext context) {
    final total = controller.page.total;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          AppButton(
            small: true,
            style: AppButtonStyle.ghost,
            label: AppText.t('السابق', 'Previous'),
            onPressed: controller.hasPrevious ? controller.previousPage : null,
          ),
          Text(
            '${AppText.t('صفحة', 'Page')} ${controller.pageNumber} / ${controller.pageCount}'
            ' · $total',
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
          ),
          AppButton(
            small: true,
            style: AppButtonStyle.ghost,
            label: AppText.t('التالي', 'Next'),
            onPressed: controller.hasNext ? controller.nextPage : null,
          ),
        ],
      ),
    );
  }
}
