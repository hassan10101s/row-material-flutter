import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../di/service_locator.dart';
import '../../data/lab_repo.dart';
import '../../domain/lab_local_repository.dart';
import 'equipment_dialogs.dart';

/// Lab equipment registry: master list + per-device event log
/// (calibration / maintenance / repair).
///
/// One responsive page for both experiences: side-by-side master/detail
/// on wide windows, list + pushed detail route on phones.
class EquipmentTab extends StatefulWidget {
  const EquipmentTab({super.key});

  @override
  State<EquipmentTab> createState() => _EquipmentTabState();
}

class _EquipmentTabState extends State<EquipmentTab> {
  final _repo = getIt<LabLocalRepository>();
  final _query = TextEditingController();
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;
  int? _selectedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _repo.listEquipment();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        if (_selectedId != null &&
            !_rows.any((r) => (r['id'] as num).toInt() == _selectedId)) {
          _selectedId = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return [
      for (final r in _rows)
        if ('${r['name'] ?? ''}'.toLowerCase().contains(q) ||
            '${r['code'] ?? ''}'.toLowerCase().contains(q) ||
            '${r['manufacturer'] ?? ''}'.toLowerCase().contains(q))
          r,
    ];
  }

  Future<void> _add() async {
    final saved = await showEquipmentForm(context);
    if (saved && mounted) _load();
  }

  void _open(Map<String, dynamic> row, bool wide) {
    final id = (row['id'] as num).toInt();
    if (wide) {
      setState(() => _selectedId = id);
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _EquipmentDetailRoute(equipmentId: id),
      ),
    ).then((_) {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSkeletonList(rows: 6, lines: 3, height: 380),
        ],
      );
    }
    if (_error != null && _rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              small: true,
              label: AppText.t('إعادة المحاولة', 'Retry'),
              onPressed: _load,
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AppBreakpoints.medium;
        final list = _MasterList(
          rows: _filtered,
          selectedId: _selectedId,
          query: _query,
          onQuery: () => setState(() {}),
          onClearQuery: () => setState(_query.clear),
          onAdd: _add,
          onOpen: (row) => _open(row, wide),
          wide: wide,
        );
        if (!wide) return list;
        final selected = _selectedId == null
            ? null
            : _rows
                .where((r) => (r['id'] as num).toInt() == _selectedId)
                .firstOrNull;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: list,
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: selected == null
                  ? AppEmptyState(
                      icon: Icons.precision_manufacturing_outlined,
                      title: AppText.t(
                        'اختر جهازاً لعرض بياناته وسجله',
                        'Select equipment to view its details and log',
                      ),
                    )
                  : _EquipmentDetail(
                      key: ValueKey('equipment-${selected['id']}'),
                      equipmentId: (selected['id'] as num).toInt(),
                      onChanged: _load,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Master list: title + add + search + cards.
class _MasterList extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final int? selectedId;
  final TextEditingController query;
  final VoidCallback onQuery;
  final VoidCallback onClearQuery;
  final VoidCallback onAdd;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final bool wide;

  const _MasterList({
    required this.rows,
    required this.selectedId,
    required this.query,
    required this.onQuery,
    required this.onClearQuery,
    required this.onAdd,
    required this.onOpen,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    final title = Text(
      AppText.t('معدات المعمل', 'Lab equipment'),
      style: Theme.of(context).textTheme.titleLarge,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide)
          Row(
            children: [
              title,
              const Spacer(),
              AppButton(
                small: true,
                label: AppText.t('إضافة جهاز', 'Add equipment'),
                icon: Icon(Icons.add, size: 16.r),
                onPressed: onAdd,
              ),
            ],
          )
        else ...[
          title,
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: AppText.t('إضافة جهاز', 'Add equipment'),
              icon: Icon(Icons.add, size: 20.r),
              onPressed: onAdd,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: query,
          onChanged: (_) => onQuery(),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search, size: 20.r),
            suffixIcon: query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: AppText.t('مسح البحث', 'Clear search'),
                    icon: Icon(Icons.close, size: 18.r),
                    onPressed: onClearQuery,
                  ),
            hintText: AppText.t(
              'بحث بالاسم أو الكود أو الشركة...',
              'Search by name, code or manufacturer...',
            ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (rows.isEmpty)
          AppEmptyState(
            icon: Icons.precision_manufacturing_outlined,
            title: AppText.t('لا توجد معدات بعد', 'No equipment yet'),
            subtitle: AppText.t(
              'سجّل أول جهاز بزر إضافة جهاز.',
              'Register the first device with Add equipment.',
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, i) {
              final r = rows[i];
              final selected =
                  selectedId == (r['id'] as num).toInt();
              return _EquipmentCard(
                row: r,
                selected: wide && selected,
                onTap: () => onOpen(r),
              );
            },
          ),
      ],
    );
  }
}

class _EquipmentCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool selected;
  final VoidCallback onTap;

  const _EquipmentCard({
    required this.row,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final calibration = '${row['last_calibration_date'] ?? ''}'.trim();
    final eventsCount = (row['events_count'] as num?)?.toInt() ?? 0;
    return AppCard(
      onTap: onTap,
      color: selected ? AppColors.primary.withValues(alpha: 0.06) : null,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${row['name'] ?? '-'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${row['code'] ?? ''}',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          if ('${row['manufacturer'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Icon(
                  Icons.factory_outlined,
                  size: 15.r,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${row['manufacturer']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(
                Icons.event_available_outlined,
                size: 15.r,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  calibration.isEmpty
                      ? AppText.t(
                          'بلا معايرة مسجلة',
                          'No calibration recorded',
                        )
                      : '${AppText.t('آخر معايرة', 'Last calibration')}: $calibration',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.textMuted.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$eventsCount ${AppText.t('أحداث', 'events')}',
                  style: TextStyle(
                    fontSize: 11.spMax,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_left,
                size: 22.r,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pushed detail route for phones.
class _EquipmentDetailRoute extends StatelessWidget {
  final int equipmentId;
  const _EquipmentDetailRoute({required this.equipmentId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('بيانات الجهاز', 'Equipment details'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.pageMobile),
          child: _EquipmentDetail(
            equipmentId: equipmentId,
            pushed: true,
          ),
        ),
      ),
    );
  }
}

/// Detail: header card + editable event log.
///
/// [pushed] is true only when shown as its own route (phones): after a
/// delete the route pops. Embedded on desktop it must never pop — that
/// would close the whole Lab page.
class _EquipmentDetail extends StatefulWidget {
  final int equipmentId;
  final VoidCallback? onChanged;
  final bool pushed;

  const _EquipmentDetail({
    super.key,
    required this.equipmentId,
    this.onChanged,
    this.pushed = false,
  });

  @override
  State<_EquipmentDetail> createState() => _EquipmentDetailState();
}

class _EquipmentDetailState extends State<_EquipmentDetail> {
  final _repo = getIt<LabLocalRepository>();
  Map<String, dynamic>? _equipment;
  List<Map<String, dynamic>> _events = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final equipment = await _repo.getEquipment(widget.equipmentId);
      final events = await _repo.listEquipmentEvents(widget.equipmentId);
      if (!mounted) return;
      setState(() {
        _equipment = equipment;
        _events = events;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  Future<void> _refresh() async {
    await _load();
    widget.onChanged?.call();
  }

  Future<void> _editEquipment() async {
    if (_equipment == null) return;
    final saved = await showEquipmentForm(context, _equipment);
    if (saved && mounted) _refresh();
  }

  Future<void> _deleteEquipment() async {
    if (_equipment == null) return;
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.delete_outline,
      title: AppText.t('حذف الجهاز؟', 'Delete equipment?'),
      message: AppText.t(
        'سيتم حذف الجهاز وسجل أحداثه بالكامل.',
        'The device and its entire event log will be deleted.',
      ),
      confirmLabel: AppText.t('حذف', 'Delete'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (!confirmed || !mounted) return;
    try {
      await _repo.deleteEquipment(widget.equipmentId);
      if (!mounted) return;
      AppFeedback.success(
        context,
        AppText.t('تم حذف الجهاز', 'Equipment deleted.'),
      );
      widget.onChanged?.call();
      if (widget.pushed && mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  Future<void> _addEvent() async {
    final saved =
        await showEquipmentEventForm(context, widget.equipmentId);
    if (saved && mounted) _refresh();
  }

  Future<void> _editEvent(Map<String, dynamic> event) async {
    final saved = await showEquipmentEventForm(
      context,
      widget.equipmentId,
      event,
    );
    if (saved && mounted) _refresh();
  }

  Future<void> _deleteEvent(Map<String, dynamic> event) async {
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.delete_outline,
      title: AppText.t('حذف الحدث؟', 'Delete event?'),
      message: AppText.t(
        'سيتم حذف هذا الحدث من السجل.',
        'This event will be removed from the log.',
      ),
      confirmLabel: AppText.t('حذف', 'Delete'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (!confirmed || !mounted) return;
    try {
      await _repo
          .deleteEquipmentEvent((event['id'] as num).toInt());
      if (mounted) _refresh();
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonList(rows: 4, lines: 3, height: 320);
    }
    final equipment = _equipment;
    if (equipment == null) {
      return AppEmptyState(
        icon: Icons.precision_manufacturing_outlined,
        title: AppText.t('الجهاز غير موجود', 'Equipment not found'),
      );
    }
    final calibration =
        '${equipment['last_calibration_date'] ?? ''}'.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${equipment['name'] ?? '-'}',
                      style: TextStyle(
                        fontSize: 16.spMax,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: AppText.t('تعديل', 'Edit'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _editEquipment,
                    icon: Icon(Icons.edit_outlined, size: 20.r),
                  ),
                  IconButton(
                    tooltip: AppText.t('حذف', 'Delete'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _deleteEquipment,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20.r,
                      color: AppColors.danger,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _Chip(
                    icon: Icons.qr_code_2_outlined,
                    text: '${equipment['code'] ?? ''}',
                    mono: true,
                  ),
                  if ('${equipment['manufacturer'] ?? ''}'
                      .trim()
                      .isNotEmpty)
                    _Chip(
                      icon: Icons.factory_outlined,
                      text: '${equipment['manufacturer']}',
                    ),
                  _Chip(
                    icon: Icons.event_available_outlined,
                    text: calibration.isEmpty
                        ? AppText.t(
                            'بلا معايرة مسجلة',
                            'No calibration recorded',
                          )
                        : '${AppText.t('آخر معايرة', 'Last calibration')}: $calibration',
                  ),
                ],
              ),
              if ('${equipment['description'] ?? ''}'.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${equipment['description']}',
                  style: TextStyle(
                    fontSize: 13.spMax,
                    color: AppColors.textMuted,
                    height: 1.6,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppText.t('سجل الأحداث', 'Event log'),
                      style: TextStyle(
                        fontSize: 14.spMax,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AppButton(
                    small: true,
                    label: AppText.t('إضافة حدث', 'Add event'),
                    icon: Icon(Icons.add, size: 16.r),
                    onPressed: _addEvent,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_events.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.md,
                  ),
                  child: Text(
                    AppText.t(
                      'لا توجد أحداث بعد — سجّل معايرة أو صيانة أو إصلاحاً.',
                      'No events yet — log a calibration, maintenance or repair.',
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                )
              else
                for (var i = 0; i < _events.length; i++) ...[
                  if (i > 0) const Divider(height: AppSpacing.lg),
                  _EventRow(
                    event: _events[i],
                    onEdit: () => _editEvent(_events[i]),
                    onDelete: () => _deleteEvent(_events[i]),
                  ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool mono;

  const _Chip({
    required this.icon,
    required this.text,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14.r, color: AppColors.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              textDirection: mono ? TextDirection.ltr : null,
              style: TextStyle(
                fontSize: 12.spMax,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final Map<String, dynamic> event;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _EventRow({
    required this.event,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final type = LabRepo.normalizeEquipmentEventType(event['event_type']);
    final color = switch (type) {
      LabRepo.equipmentEventRepair => AppColors.danger,
      LabRepo.equipmentEventMaintenance => AppColors.partial,
      _ => AppColors.success,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            equipmentEventLabel(type),
            style: TextStyle(
              color: color,
              fontSize: 11.spMax,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${event['event_date'] ?? ''}',
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if ('${event['notes'] ?? ''}'.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '${event['notes']}',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                    height: 1.6,
                  ),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: AppText.t('تعديل', 'Edit'),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: onEdit,
          icon: Icon(Icons.edit_outlined, size: 18.r),
        ),
        IconButton(
          tooltip: AppText.t('حذف', 'Delete'),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: onDelete,
          icon: Icon(
            Icons.delete_outline,
            size: 18.r,
            color: AppColors.danger,
          ),
        ),
      ],
    );
  }
}
