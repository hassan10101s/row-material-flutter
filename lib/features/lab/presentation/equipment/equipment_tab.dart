import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/report_form_keys.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_export_button.dart';
import '../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../design_system/widgets/app_selection.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/export/table_html_export.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../di/service_locator.dart';
import '../../../inspections/presentation/qr/qr_scan_screen.dart';
import '../../../reports/domain/report_repository.dart';
import '../../domain/lab_local_repository.dart';
import 'equipment_dialogs.dart';
import '../../../../design_system/widgets/app_text_field.dart';

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
            '${r['manufacturer'] ?? ''}'.toLowerCase().contains(q) ||
            '${r['serial_number'] ?? ''}'.toLowerCase().contains(q))
          r,
    ];
  }

  Future<void> _add() async {
    final saved = await showEquipmentForm(context);
    if (saved && mounted) _load();
  }

  void _open(Map<String, dynamic> row) {
    final id = (row['id'] as num).toInt();
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => _EquipmentDetailRoute(equipmentId: id),
          ),
        )
        .then((_) {
          if (mounted) _load();
        });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [AppSkeletonList(rows: 6, lines: 3, height: 380)],
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
        final list = EquipmentMasterList(
          rows: _filtered,
          selectedId: _selectedId,
          query: _query,
          onQuery: () => setState(() {}),
          onClearQuery: () => setState(_query.clear),
          onAdd: _add,
          onOpen: _open,
          wide: wide,
        );
        // Narrow: add floats like the raw-material register (heroTag null:
        // sibling lab tabs share one IndexedStack). Wide keeps inline add.
        if (wide) return list;
        return Scaffold(
          floatingActionButton: FloatingActionButton(
            heroTag: null,
            tooltip: AppText.t('إضافة جهاز', 'Add equipment'),
            onPressed: _add,
            child: Icon(Icons.add, size: 24.r),
          ),
          body: list,
        );
      },
    );
  }
}

/// Master list: title + add + search + table on wide screens, cards on phones.
///
/// Export mapping lives here so both experiences (and tests) share it.
class EquipmentMasterList extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final int? selectedId;
  final TextEditingController query;
  final VoidCallback onQuery;
  final VoidCallback onClearQuery;
  final VoidCallback onAdd;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final bool wide;

  const EquipmentMasterList({
    super.key,
    required this.rows,
    required this.selectedId,
    required this.query,
    required this.onQuery,
    required this.onClearQuery,
    required this.onAdd,
    required this.onOpen,
    required this.wide,
  });

  /// Export mapping shared by the desktop table and the mobile cards.
  static List<String> exportHeaders() => [
    AppText.t('المعدة', 'Equipment'),
    AppText.t('الكود', 'Code'),
    AppText.t('الشركة', 'Manufacturer'),
    AppText.t('آخر معايرة', 'Last calibration'),
    AppText.t('السجل', 'Log'),
  ];

  static List<List<String>> exportRows(List<Map<String, dynamic>> rows) => [
    for (final r in rows)
      [
        '${r['name'] ?? '-'}',
        '${r['code'] ?? '-'}',
        '${r['manufacturer'] ?? '-'}',
        '${r['last_calibration_date'] ?? '-'}',
        '${r['events_count'] ?? 0}',
      ],
  ];

  static String exportTitle() => AppText.t('معدات المعمل', 'Lab equipment');

  @override
  State<EquipmentMasterList> createState() => _MasterListState();
}

class _MasterListState extends State<EquipmentMasterList> {
  /// Table indices picked with the checkbox column (same idea every table).
  final Set<int> _selected = <int>{};

  Future<void> _exportSelected() async {
    final picked = [
      for (var i = 0; i < widget.rows.length; i++)
        if (_selected.contains(i)) widget.rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'equipment',
      title: EquipmentMasterList.exportTitle(),
      headers: EquipmentMasterList.exportHeaders(),
      rows: EquipmentMasterList.exportRows(picked),
    );
    if (mounted && picked.isNotEmpty) {
      setState(_selected.clear);
    }
  }

  /// Device stickers for the picked rows (one PDF, N-up on A4 — like the
  /// inspections batch labels). Selection clears on success only; the file is
  /// then handed to the delivery sheet (open/share), never a path-only banner.
  Future<void> _exportSelectedLabels() async {
    final ids = [
      for (var i = 0; i < widget.rows.length; i++)
        if (_selected.contains(i)) (widget.rows[i]['id'] as num).toInt(),
    ];
    try {
      final reports = getIt<ReportRepository>();
      final doc = await reports.equipmentLabelsPdf(ids);
      final file = await reports.saveReport(doc, asLabel: true);
      if (!mounted) return;
      setState(_selected.clear);
      await AppFeedbackExport.actions(
        context,
        filePath: file.path,
        documentName: file.uri.pathSegments.last,
      );
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final query = widget.query;
    final wide = widget.wide;
    // Same platform guard as the inspections scan entry points: the camera
    // scanner is Android-only (QrScanScreen itself degrades to manual search
    // elsewhere, but the button is never built outside Android).
    final scanAvailable =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    // Pairs with AppExportIconButton in the narrow search row.
    final scanButton = IconButton.outlined(
      tooltip: AppText.t('مسح رمز', 'Scan QR'),
      onPressed: () => Navigator.of(
        context,
      ).push(AppPageRoute(builder: (_) => const QrScanScreen())),
      icon: Icon(Icons.qr_code_scanner_outlined, size: 20.r),
    );
    final search = AppTextField(
      controller: query,
      onChanged: (_) {
        if (_selected.isNotEmpty) setState(_selected.clear);
        widget.onQuery();
      },
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.search, size: 20.r),
        suffixIcon: query.text.isEmpty
            ? null
            : IconButton(
                tooltip: AppText.t('مسح البحث', 'Clear search'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: Icon(Icons.close, size: 18.r),
                onPressed: widget.onClearQuery,
              ),
        hintText: AppText.t(
          'بحث بالاسم أو الكود أو الشركة...',
          'Search by name, code or manufacturer...',
        ),
      ),
    );
    final exportButton = IconButton(
      tooltip: AppText.t('تصدير جدول', 'Export table'),
      visualDensity: VisualDensity.compact,
      constraints: wide
          ? null
          : const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: rows.isEmpty
          ? null
          : () => TableHtmlExport.export(
              context,
              filePrefix: 'equipment',
              title: EquipmentMasterList.exportTitle(),
              headers: EquipmentMasterList.exportHeaders(),
              rows: EquipmentMasterList.exportRows(rows),
            ),
      icon: Icon(Icons.table_view_outlined, size: 18.r),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide)
          // Search and every action share one row; no space wasted.
          Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: AppSpacing.sm),
              exportButton,
              if (scanAvailable) ...[
                AppButton(
                  icon: Icon(Icons.qr_code_scanner_outlined, size: 18.r),
                  label: AppText.t('مسح رمز', 'Scan QR'),
                  style: AppButtonStyle.secondary,
                  onPressed: () => Navigator.of(
                    context,
                  ).push(AppPageRoute(builder: (_) => const QrScanScreen())),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              AppButton(
                small: true,
                label: AppText.t('إضافة جهاز', 'Add equipment'),
                icon: Icon(Icons.add, size: 16.r),
                onPressed: widget.onAdd,
              ),
            ],
          )
        else ...[
          // Compact top row like the other lab registers: search takes the
          // width, export sits beside it — no big title, no end-aligned
          // row that wastes a whole line on small phones.
          // Add floats (FAB on the host Scaffold) like the raw-material
          // register.
          AppSearchRow(
            search: search,
            export: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (scanAvailable) ...[
                  scanButton,
                  const SizedBox(width: AppSpacing.sm),
                ],
                AppExportIconButton(
                  onPressed: rows.isEmpty
                      ? null
                      : () => TableHtmlExport.export(
                          context,
                          filePrefix: 'equipment',
                          title: EquipmentMasterList.exportTitle(),
                          headers: EquipmentMasterList.exportHeaders(),
                          rows: EquipmentMasterList.exportRows(rows),
                        ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // The tab area is bounded (Expanded ← IndexedStack in lab_screen), so
        // the trailing content must flex instead of sizing naturally — a fixed
        // table height or a shrink-wrapped list overflows the Column (60px in
        // the reported RenderFlex overflow).
        if (_selected.isNotEmpty && wide) ...[
          TableSelectionBar(
            selectedCount: _selected.length,
            onExportTable: _exportSelected,
            onExportLabels: _exportSelectedLabels,
            onClear: () => setState(_selected.clear),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Expanded(
          child: rows.isEmpty
              ? SingleChildScrollView(
                  child: AppEmptyState(
                    icon: Icons.precision_manufacturing_outlined,
                    title: AppText.t('لا توجد معدات بعد', 'No equipment yet'),
                    subtitle: AppText.t(
                      'سجّل أول جهاز بزر إضافة جهاز.',
                      'Register the first device with Add equipment.',
                    ),
                  ),
                )
              : wide
              ? AppPaginatedTable(
                  // `null` fills the Expanded above instead of a fixed
                  // height that may exceed the viewport.
                  height: null,
                  minTableWidth: 820,
                  columnFlex: const [1.2, 0.8, 1.2, 1.2, 1.0, 1.0],
                  headers: [
                    ...EquipmentMasterList.exportHeaders(),
                    AppText.t('الإجراءات', 'Actions'),
                  ],
                  rows: [
                    for (final r in rows)
                      [
                        Text(
                          '${r['name'] ?? '-'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${r['code'] ?? '-'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${r['manufacturer'] ?? '-'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${r['last_calibration_date'] ?? '-'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text('${r['events_count'] ?? 0}'),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: AppText.t(
                                'فتح سجل التغييرات',
                                'Open change log',
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => widget.onOpen(r),
                              icon: Icon(Icons.history_outlined, size: 18.r),
                            ),
                          ],
                        ),
                      ],
                  ],
                  selectedIndices: _selected,
                  selectHidden: true,
                  onToggleIndex: (i) => setState(() {
                    if (!_selected.remove(i)) _selected.add(i);
                  }),
                  selectAllValue: _selected.isEmpty
                      ? false
                      : _selected.length >= rows.length
                      ? true
                      : null,
                  onToggleAll: (_) => setState(() {
                    if (_selected.length >= rows.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(List.generate(rows.length, (i) => i));
                    }
                  }),
                )
              : ListView.separated(
                  // Scrolls in the Expanded space above; the old
                  // shrink-wrap + never-scrollable combo overflowed the
                  // Column on short viewports.
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.md),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return _EquipmentCard(
                      row: r,
                      selected: false,
                      onTap: () => widget.onOpen(r),
                    );
                  },
                ),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                      ? AppText.t('بلا معايرة مسجلة', 'No calibration recorded')
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              Icon(Icons.chevron_left, size: 22.r, color: AppColors.textMuted),
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
          child: _EquipmentDetail(equipmentId: equipmentId, pushed: true),
        ),
      ),
    );
  }
}

/// Public entry to the device file (device card + event log), used by the
/// QR scanner: a scan opens this route directly by equipment id.
class EquipmentDetailScreen extends StatelessWidget {
  final int equipmentId;
  const EquipmentDetailScreen({super.key, required this.equipmentId});

  @override
  Widget build(BuildContext context) {
    return _EquipmentDetailRoute(equipmentId: equipmentId);
  }
}

/// Detail: header card + editable event log.
///
/// [pushed] is true only when shown as its own route (phones): after a
/// delete the route pops. Embedded on desktop it must never pop — that
/// would close the whole Lab page.
class _EquipmentDetail extends StatefulWidget {
  final int equipmentId;
  final bool pushed;

  const _EquipmentDetail({required this.equipmentId, this.pushed = false});

  @override
  State<_EquipmentDetail> createState() => _EquipmentDetailState();
}

class _EquipmentDetailState extends State<_EquipmentDetail> {
  final _repo = getIt<LabLocalRepository>();
  Map<String, dynamic>? _equipment;
  List<Map<String, dynamic>> _events = const [];
  bool _loading = true;
  bool _printing = false;

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
      if (widget.pushed && mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  Future<void> _addEvent() async {
    final saved = await showEquipmentEventForm(context, widget.equipmentId);
    if (saved && mounted) _refresh();
  }

  /// Opens the QA form-number editor (gear): the `Form No:` line printed
  /// on this equipment's label only.
  Future<void> _editFormNo() async {
    await showQaFormNoDialog(
      context,
      key: ReportFormKeys.equipmentLabel,
      title: AppText.t('رقم فورم ملصق المعدة', 'Equipment label form no.'),
    );
  }

  /// Prints the 10×5cm device sticker (same flow as the sample label):
  /// PDF bytes from the reports repository, then the delivery sheet
  /// (open on desktop, open/share on a phone) via `AppFeedbackExport`.
  Future<void> _printLabel() async {
    if (_printing || _equipment == null) return;
    setState(() => _printing = true);
    try {
      final reports = getIt<ReportRepository>();
      final doc = await reports.equipmentLabelPdf(widget.equipmentId);
      final file = await reports.saveReport(doc, asLabel: true);
      if (!mounted) return;
      setState(() => _printing = false);
      await AppFeedbackExport.actions(
        context,
        filePath: file.path,
        documentName: file.uri.pathSegments.last,
      );
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() => _printing = false);
      AppFeedback.error(context, e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _printing = false);
      AppFeedback.errorFrom(context, e);
    }
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
      await _repo.deleteEquipmentEvent((event['id'] as num).toInt());
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
    final calibration = '${equipment['last_calibration_date'] ?? ''}'.trim();
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
                    tooltip: AppText.t('طباعة الليبل', 'Print label'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _printing ? null : _printLabel,
                    icon: _printing
                        ? SizedBox(
                            width: 20.r,
                            height: 20.r,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : Icon(Icons.print_outlined, size: 20.r),
                  ),
                  IconButton(
                    tooltip: AppText.t('رقم فورم الجودة', 'QA form number'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _editFormNo,
                    icon: Icon(Icons.settings_outlined, size: 20.r),
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
                  if ('${equipment['manufacturer'] ?? ''}'.trim().isNotEmpty)
                    _Chip(
                      icon: Icons.factory_outlined,
                      text: '${equipment['manufacturer']}',
                    ),
                  if ('${equipment['serial_number'] ?? ''}'.trim().isNotEmpty)
                    _Chip(
                      icon: Icons.confirmation_number_outlined,
                      text: '${equipment['serial_number']}',
                      mono: true,
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
                  if ('${equipment['next_calibration_date'] ?? ''}'
                      .trim()
                      .isNotEmpty)
                    _Chip(
                      icon: Icons.event_repeat_outlined,
                      text:
                          '${AppText.t('المعايرة القادمة', 'Next calibration')}: '
                          '${equipment['next_calibration_date']}',
                      danger: _isOverdue(
                        '${equipment['next_calibration_date']}',
                      ),
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
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
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
  final bool danger;

  const _Chip({
    required this.icon,
    required this.text,
    this.mono = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14.r, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              textDirection: mono ? TextDirection.ltr : null,
              style: TextStyle(
                fontSize: 12.spMax,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// True when a bare `yyyy-MM-dd` date is before today (overdue calibration).
bool _isOverdue(String date) {
  final day = date.trim().length >= 10
      ? date.trim().substring(0, 10)
      : date.trim();
  if (day.isEmpty) return false;
  return day.compareTo(DateTime.now().toString().substring(0, 10)) < 0;
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
    final type = EquipmentEventType.normalize(event['event_type']);
    final color = switch (type) {
      EquipmentEventType.repair => AppColors.danger,
      EquipmentEventType.maintenance => AppColors.partial,
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
          icon: Icon(Icons.delete_outline, size: 18.r, color: AppColors.danger),
        ),
      ],
    );
  }
}
