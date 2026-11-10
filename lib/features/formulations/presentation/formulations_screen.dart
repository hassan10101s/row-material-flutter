import '../../../design_system/widgets/app_adaptive.dart';
import '../../../design_system/widgets/app_mobile_add_layout.dart';
import '../../../design_system/widgets/app_info_hint.dart';
import '../../../design_system/feedback/app_feedback.dart';
import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../../design_system/widgets/app_tooltip.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/sync/sync_data_changes.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/widgets/app_dialogs.dart';
import '../../../design_system/animations/app_animations.dart';
import '../../../design_system/charts/app_chart_palette.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../../../app/auth_gate.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../design_system/widgets/app_page_header.dart';
import '../../../design_system/widgets/app_search_field.dart';
import '../../../design_system/widgets/app_skeleton.dart';
import '../../../design_system/widgets/app_summary_card.dart';
import '../../../design_system/widgets/app_text_field.dart';
import '../../../design_system/widgets/app_select_field.dart';
import '../../../design_system/widgets/app_window.dart';
import '../domain/formulation_calculator.dart';
import '../domain/formulation_timeline.dart';
import '../domain/formulation_tracking.dart';
import '../domain/formulation_repository.dart';
import 'formulation_view_prefs.dart';
import 'formulation_parameter_picker.dart';

class FormulationsScreen extends StatefulWidget {
  const FormulationsScreen({
    super.key,
    this.initialId,
    this.initialProductId,
    this.initialFrom,
    this.initialTo,
  });

  final int? initialId;
  final int? initialProductId;
  final String? initialFrom;
  final String? initialTo;

  @override
  State<FormulationsScreen> createState() => _FormulationsScreenState();
}

class _FormulationsScreenState extends State<FormulationsScreen> {
  late final FormulationRepository _repo = getIt<FormulationRepository>();
  late Future<List<Map<String, dynamic>>> _rows = _repo.list();
  bool get _canWrite =>
      getIt<AuthGate>().canWrite(Permission.formulationsCreate);
  bool get _canDelete =>
      getIt<AuthGate>().canWrite(Permission.formulationsUpdate);
  final _deleting = <int>{};
  bool _archived = false;
  bool _openedInitial = false;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  StreamSubscription<void>? _syncSubscription;

  @override
  void initState() {
    super.initState();
    _syncSubscription = SyncDataChanges.stream.listen((_) {
      if (mounted) unawaited(_reload());
    });
  }

  @override
  void dispose() {
    unawaited(_syncSubscription?.cancel());
    _search.dispose();
    super.dispose();
  }

  Map<String, dynamic> _decode(Object? raw, Map<String, dynamic> fallback) {
    if (raw is! String || raw.isEmpty) return fallback;
    try {
      final value = jsonDecode(raw);
      return value is Map ? Map<String, dynamic>.from(value) : fallback;
    } on FormatException {
      return fallback;
    }
  }

  List<Map<String, dynamic>> _decodeList(Object? raw) {
    if (raw is! String || raw.isEmpty) return [];
    try {
      final value = jsonDecode(raw);
      return value is List
          ? [
              for (final row in value.whereType<Map>())
                Map<String, dynamic>.from(row),
            ]
          : [];
    } on FormatException {
      return [];
    }
  }

  Future<void> _reload() async {
    setState(() {
      _rows = _repo.list(archived: _archived);
    });
  }

  Future<void> _edit([Map<String, dynamic>? row, bool? view]) async {
    final catalogues = await Future.wait([
      _repo.materials(),
      _repo.products(),
      _repo.parameters(),
    ]);
    final [materials, products, parameters] = catalogues;
    if (!mounted) return;
    final result = await showAppContentSurface<bool>(
      context,
      builder: (_, fullScreen) => _FormulationEditor(
        repo: _repo,
        materials: materials,
        products: products,
        parameters: parameters,
        initial: row,
        productId: widget.initialProductId,
        initialFrom: widget.initialFrom,
        initialTo: widget.initialTo,
        writable: _canWrite,
        fullScreen: fullScreen,
        viewMode: row != null && (view ?? false),
      ),
    );
    if (result != true || !mounted) return;
    try {
      await _reload();
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تم حفظ التركيبة', 'Formulation saved'),
        );
      }
    } on AppError catch (error) {
      if (mounted) {
        AppFeedback.errorFrom(context, error);
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.errorFrom(context, error);
      }
    }
  }

  Future<void> _archive(Map<String, dynamic> row) async {
    try {
      await _repo.archive((row['id'] as num).toInt());
      await _reload();
    } on AppError catch (error) {
      if (mounted) {
        AppFeedback.errorFrom(context, error);
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final id = (row['id'] as num).toInt();
    if (_deleting.contains(id) || !_canDelete) return;
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('حذف التركيبة؟', 'Delete formulation?'),
      message: AppText.t(
        'سيتم حذف «${row['name']}» من قائمة التركيبات. لن تتغير محاضر الفحص أو نتائج المعمل.',
        'Delete “${row['name']}” from formulations? Inspection and laboratory records will be retained.',
      ),
      confirmLabel: AppText.t('حذف', 'Delete'),
      danger: true,
      icon: Icons.delete_outline,
    );
    if (!confirmed || !mounted || !_canDelete || _deleting.contains(id)) return;
    setState(() => _deleting.add(id));
    try {
      await _repo.delete(id);
      if (!mounted) return;
      await _reload();
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تم حذف التركيبة', 'Formulation deleted'),
        );
      }
    } on AppError catch (error) {
      if (mounted) AppFeedback.errorFrom(context, error);
    } catch (error) {
      if (mounted) AppFeedback.errorFrom(context, error);
    } finally {
      if (mounted) setState(() => _deleting.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_openedInitial && widget.initialId != null) {
      _openedInitial = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final groups = await Future.wait([
          _repo.list(),
          _repo.list(archived: true),
        ]);
        final rows = groups.expand((items) => items);
        final found = rows
            .where((row) => row['id'] == widget.initialId)
            .firstOrNull;
        if (mounted && found != null) await _edit(found);
      });
    }
    return AppMobileAddLayout(
      floating: !appUsesDesktopChrome(context),
      tooltip: AppText.t('تركيبة جديدة', 'New formulation'),
      onAdd: _canWrite ? () => _edit() : null,
      child: Padding(
        padding: EdgeInsets.all(
          appUsesDesktopChrome(context)
              ? AppSpacing.page
              : AppSpacing.pageMobile,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppEntrance(
              child: AppPageHeader(
                title: AppText.t('متتبع التركيبات', 'Formula tracking'),
                actions: [
                  if (_canWrite && appUsesDesktopChrome(context))
                    AppButton(
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add),
                      label: AppText.t('تركيبة جديدة', 'New formulation'),
                    ),
                ],
                bottom: AppFilterBar(
                  searchHint: AppText.t('بحث بالاسم', 'Search by name...'),
                  onSearch: (query) {
                    if (mounted) setState(() => _query = query.trim());
                  },
                  filters: [
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(AppText.t('النشطة', 'Active')),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(AppText.t('المؤرشفة', 'Archived')),
                        ),
                      ],
                      selected: {_archived},
                      onSelectionChanged: (value) {
                        setState(() {
                          _archived = value.first;
                          _rows = _repo.list(archived: _archived);
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _rows,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const AppSkeletonList(
                      rows: 5,
                      lines: 2,
                      height: 420,
                    );
                  }
                  if (snapshot.hasError) {
                    return AppErrorState(
                      title: AppText.t(
                        'تعذر تحميل التركيبات',
                        'Could not load formulations',
                      ),
                      subtitle: AppError.friendly(snapshot.error!),
                      onRetry: () => _reload(),
                    );
                  }
                  final all = snapshot.data ?? [];
                  final query = _query.toLowerCase();
                  final items = query.isEmpty
                      ? all
                      : [
                          for (final row in all)
                            if ('${row['name'] ?? ''}'.toLowerCase().contains(
                              query,
                            ))
                              row,
                        ];
                  if (items.isEmpty) {
                    if (query.isNotEmpty) {
                      return AppEmptyState(
                        icon: Icons.search_off,
                        title: AppText.t(
                          'لا توجد نتائج مطابقة',
                          'No matching formulations',
                        ),
                        subtitle: AppText.t(
                          'جرّب مسح البحث.',
                          'Try clearing the search.',
                        ),
                        action: AppButton(
                          style: AppButtonStyle.secondary,
                          label: AppText.t('مسح البحث', 'Clear search'),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                      );
                    }
                    return AppEmptyState(
                      icon: _archived
                          ? Icons.archive_outlined
                          : Icons.science_outlined,
                      title: _archived
                          ? AppText.t(
                              'لا توجد تركيبات مؤرشفة',
                              'No archived formulations',
                            )
                          : AppText.t(
                              'لا توجد تركيبات محفوظة بعد',
                              'No saved formulations yet',
                            ),
                      subtitle: _canWrite && !_archived
                          ? AppText.t(
                              'أنشئ أول تركيبة وحدد خاماتها وأوزانها.',
                              'Create your first formulation with its materials and weights.',
                            )
                          : null,
                      action:
                          _canWrite &&
                              !_archived &&
                              appUsesDesktopChrome(context)
                          ? AppButton(
                              onPressed: () => _edit(),
                              icon: const Icon(Icons.add),
                              label: AppText.t(
                                'تركيبة جديدة',
                                'New formulation',
                              ),
                            )
                          : null,
                    );
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _formulationCard(context, items[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _formulationCard(BuildContext context, Map<String, dynamic> row) {
    final data = _decode(row['calculation_json'], {});
    final kg = (data['total_kg'] as num?)?.toDouble();
    final cost = (data['cost_per_kg'] as num?)?.toDouble();
    final ingredients = _decodeList(row['items_json']);
    // The whole card opens the graph page with the saved information; the
    // quick-edit pencil opens the editing page directly.
    final pillChildren = [
      _formulationPill(
        '${ingredients.length} ${AppText.t('خامة', 'ingredients')}',
      ),
      if (row['_missing_references'] == true)
        _formulationPill(
          AppText.t(
            'خامة أو منتج غير متاح على الجهاز',
            'A material or product is unavailable on this device',
          ),
          color: AppColors.warning,
        ),
      if (kg != null) _formulationPill('${kg.toStringAsFixed(1)} kg'),
      if (cost != null)
        _formulationPill(
          '${cost.toStringAsFixed(3)} / kg',
          color: AppColors.success,
        ),
      if (row['updated_at'] != null)
        Text(
          '${row['updated_at']}',
          style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
        ),
    ];
    final name = Text(
      '${row['name'] ?? ''}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15.spMax,
        fontWeight: FontWeight.w700,
        color: AppColors.textStrong,
      ),
    );
    final actions = [
      if (_canDelete)
        IconButton(
          tooltip: AppText.t('حذف التركيبة', 'Delete formulation'),
          onPressed: _deleting.contains(row['id']) ? null : () => _delete(row),
          icon: Icon(Icons.delete_outline, color: AppColors.danger),
        ),
      if (_canWrite)
        IconButton(
          tooltip: AppText.t('تعديل سريع', 'Quick edit'),
          onPressed: () => _edit(row),
          icon: const Icon(Icons.edit_outlined),
          visualDensity: VisualDensity.compact,
          iconSize: 19,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      IconButton(
        tooltip: AppText.t('عرض الجراف', 'Open the graph'),
        onPressed: () => _edit(row, true),
        icon: const Icon(Icons.query_stats),
        visualDensity: VisualDensity.compact,
        iconSize: 19,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      ),
      PopupMenuButton<String>(
        tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
        onSelected: (value) async {
          if (value == 'copy') {
            final copy = Map<String, dynamic>.from(row)
              ..remove('id')
              ..remove('remote_id')
              ..['name'] = 'نسخة من ${row['name']}'
              ..['copied_from_id'] = row['id'];
            final itemList = _decodeList(row['items_json']);
            await _edit({
              ...copy,
              'items_json': jsonEncode(itemList),
              'graph_parameters_json': row['graph_parameters_json'],
              'parameters_json': row['parameters_json'],
              'calculation_json': '{}',
              'source_snapshot_json': '[]',
            });
          } else if (value == 'archive') {
            await _archive(row);
          }
        },
        itemBuilder: (_) => [
          if (_canWrite)
            PopupMenuItem(
              value: 'copy',
              child: Text(AppText.t('تكرار', 'Duplicate')),
            ),
          if (_canWrite && !_archived)
            PopupMenuItem(
              value: 'archive',
              child: Text(AppText.t('أرشفة', 'Archive')),
            ),
        ],
      ),
    ];
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () => _edit(row, true),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 12,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final pills = Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: pillChildren,
            );
            // Very narrow phones stack the pills under the name row so the
            // trailing tray keeps them from shrinking off screen.
            if (box.maxWidth < 330) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: name),
                      ...actions,
                    ],
                  ),
                  const SizedBox(height: 6),
                  pills,
                ],
              );
            }
            return Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [name, const SizedBox(height: 4), pills],
                  ),
                ),
                ...actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Ingredient picker: debounced search beside two quick filters — materials
/// that have a محضر (receipt/inspection) versus all materials.
class _MaterialPicker extends StatefulWidget {
  const _MaterialPicker({
    required this.materials,
    required this.loadReceiptIds,
    this.fullScreen = false,
  });
  final List<Map<String, dynamic>> materials;
  final Future<Set<int>> Function() loadReceiptIds;
  final bool fullScreen;

  @override
  State<_MaterialPicker> createState() => _MaterialPickerState();
}

class _MaterialPickerState extends State<_MaterialPicker> {
  late bool _receiptOnly = true;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  Set<int> _withReceipts = {};
  bool _loadingReceipts = true;
  String? _receiptError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReceiptIds());
  }

  Future<void> _loadReceiptIds() async {
    setState(() {
      _loadingReceipts = true;
      _receiptError = null;
    });
    try {
      final ids = await widget.loadReceiptIds();
      if (mounted) setState(() => _withReceipts = ids);
    } on Object catch (error) {
      if (mounted) setState(() => _receiptError = AppError.friendly(error));
    } finally {
      if (mounted) setState(() => _loadingReceipts = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered => [
    for (final material in widget.materials)
      if (_withReceipts.contains((material['id'] as num).toInt()) ||
          !_receiptOnly)
        if ('${material['material_name'] ?? ''}'.toLowerCase().contains(
          _query.toLowerCase(),
        ))
          material,
  ];

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    return SizedBox(
      height: widget.fullScreen ? null : 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DebouncedSearchField(
                  controller: _search,
                  hint: AppText.t('بحث باسم الخامة', 'Search material...'),
                  onChanged: (value) => setState(() => _query = value.trim()),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                small: true,
                style: _receiptOnly
                    ? AppButtonStyle.primary
                    : AppButtonStyle.secondary,
                label: AppText.t('لها محضر', 'With receipt'),
                onPressed: () => setState(() => _receiptOnly = true),
              ),
              const SizedBox(width: 6),
              AppButton(
                small: true,
                style: !_receiptOnly
                    ? AppButtonStyle.primary
                    : AppButtonStyle.secondary,
                label: AppText.t('الكل', 'All'),
                onPressed: () => setState(() => _receiptOnly = false),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_loadingReceipts) const LinearProgressIndicator(),
          if (_receiptError != null)
            Row(
              children: [
                Expanded(child: Text(_receiptError!)),
                AppButton(
                  onPressed: _loadReceiptIds,
                  label: AppText.t('إعادة المحاولة', 'Retry'),
                  small: true,
                  style: AppButtonStyle.ghost,
                ),
              ],
            ),
          Expanded(
            child: _receiptOnly && _loadingReceipts
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                ? Center(
                    child: Text(
                      AppText.t(
                        'لا توجد خامات مطابقة',
                        'No matching materials',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (dialogContext, index) => ListTile(
                      onTap: () => Navigator.pop(dialogContext, rows[index]),
                      title: Text('${rows[index]['material_name']}'),
                      trailing:
                          _withReceipts.contains(
                            (rows[index]['id'] as num).toInt(),
                          )
                          ? AppTooltip(
                              message: AppText.t('لها محضر', 'Has receipt'),
                              child: Icon(
                                Icons.receipt_long_outlined,
                                size: 18,
                                color: AppColors.success,
                              ),
                            )
                          : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small tinted pill shared by the list cards and the editor tiles.
Widget _formulationPill(String text, {Color? color, IconData? icon}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? AppColors.primary).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (color ?? AppColors.primary).withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color ?? AppColors.primary),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.spMax,
                fontWeight: FontWeight.w600,
                color: color ?? AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );

/// Per-point labels carry the values, so the grouped touch tooltip is muted.
enum _PeriodMode { day, month, year, range }

class _FormulationEditor extends StatefulWidget {
  const _FormulationEditor({
    required this.repo,
    required this.materials,
    required this.products,
    required this.parameters,
    required this.initial,
    required this.productId,
    required this.initialFrom,
    required this.initialTo,
    required this.writable,
    this.fullScreen = false,
    this.viewMode = false,
  });
  final FormulationRepository repo;
  final List<Map<String, dynamic>> materials;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> parameters;
  final Map<String, dynamic>? initial;
  final int? productId;
  final String? initialFrom;
  final String? initialTo;
  final bool writable;
  final bool fullScreen;

  /// Open read-only on the graph page (list card body / graph button). The
  /// internal Edit button flips in-place to the editing page.
  final bool viewMode;

  @override
  State<_FormulationEditor> createState() => _FormulationEditorState();
}

class _FormulationEditorState extends State<_FormulationEditor> {
  bool get _authoringLocked => _saving || _pendingMessage != null;
  bool _allowProductUnlink = false;
  bool get _unresolvedProductReference =>
      _productId == null &&
      _settings['_product_reference'] is Map &&
      !_allowProductUnlink;

  /// False = the ingredients/name editing page; true = the graph page with
  /// the formulation's saved information (list card body / graph button).
  /// Flipped in place by the Edit button in the actions bar.
  late bool _viewing = widget.viewMode;

  StreamSubscription<void>? _sourceChanges;
  String? _baseline;
  late final _closeGuard = AppContentGuard(
    confirmDiscard: () async {
      if (_saving || !mounted) return false;
      return showAppConfirm(
        context,
        title: AppText.t('تجاهل التعديلات؟', 'Discard changes?'),
        message: AppText.t(
          'توجد تعديلات لم تُحفظ. هل تريد الخروج؟',
          'You have unsaved changes. Leave this editor?',
        ),
        confirmLabel: AppText.t('تجاهل وخروج', 'Discard and leave'),
        cancelLabel: AppText.t('متابعة التعديل', 'Keep editing'),
      );
    },
  );

  String _draftSignature() => jsonEncode({
    'name': _name.text,
    'product': _productId,
    'allow_product_unlink': _allowProductUnlink,
    'items': [
      for (final row in _items)
        {
          'id': row['material_id'],
          'quantity': row['quantity_kg'],
          'price': row['price_per_kg'],
        },
    ],
  });

  void _syncCloseGuard() {
    _closeGuard.canClose =
        !_saving && (!widget.writable || _baseline == _draftSignature());
  }

  @override
  void setState(VoidCallback fn) {
    final before = _viewPrefsReady && _viewing
        ? jsonEncode(_viewPrefs())
        : null;
    super.setState(fn);
    if (_baseline != null) _syncCloseGuard();
    if (before != null && before != jsonEncode(_viewPrefs())) _storeViewPrefs();
  }

  late final TextEditingController _name = TextEditingController(
    text: '${widget.initial?['name'] ?? ''}',
  );
  late final List<Map<String, dynamic>> _items = _readItems();
  late int? _productId =
      (widget.initial?['product_id'] as num?)?.toInt() ?? widget.productId;
  late final Set<String> _graphParameters = _readGraphParameters();
  late List<Map<String, dynamic>> _parameterCatalog = widget.parameters;
  bool _choosingParameters = false;
  bool _loadingParameterCatalog = false;
  Map<String, dynamic> _savedSettings() {
    final raw = widget.initial?['parameters_json'];
    if (raw is! String) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  late final Map<String, dynamic> _settings = _savedSettings();
  late FormulationDataSource _dataSource = FormulationDataSource.values
      .firstWhere(
        (value) => value.name == _settings['data_source'],
        orElse: () => FormulationDataSource.all,
      );
  late FormulationChartInterval _chartInterval = FormulationChartInterval.values
      .firstWhere(
        (value) => value.name == _settings['chart_interval'],
        orElse: () => FormulationChartInterval.automatic,
      );
  late _PeriodMode _mode = _PeriodMode.values.firstWhere(
    (value) => value.name == _settings['period'],
    orElse: () => _PeriodMode.month,
  );
  late FormulationAggregation _aggregation = FormulationAggregation.values
      .firstWhere(
        (value) => value.name == _settings['aggregation'],
        orElse: () => FormulationAggregation.average,
      );
  late DateTime _selected =
      DateTime.tryParse(widget.initialFrom ?? '${_settings['from'] ?? ''}') ??
      DateTime.now();
  late DateTime _from =
      DateTime.tryParse(widget.initialFrom ?? '${_settings['from'] ?? ''}') ??
      DateTime(_selected.year, _selected.month, 1);
  late DateTime _to =
      DateTime.tryParse(widget.initialTo ?? '${_settings['to'] ?? ''}') ??
      _selected;
  bool _busy = false;
  bool _saving = false;
  bool _sourcesReady = false;
  String? _error;
  String? _pendingMessage;
  FormulationResult? _calculation;
  List<Map<String, dynamic>> _sourceHints = [];
  List<MaterialReceipt> _receipts = [];
  Future<List<MaterialReceipt>>? _receiptRequest;
  Map<String, List<FlSpot>> _spotsByParameter = {};
  List<String> _axisLabels = [];
  List<String> _axisRangeLabels = [];
  int _refreshGeneration = 0;
  Future<FormulationTrackingResult>? _trackingTask;
  List<MaterialReceipt>? _trackingReceipts;
  final _trackingCache = <String, FormulationTrackingResult>{};

  /// Chart hover state: series bar index -> spot index. Stored as plain
  /// indices and re-validated against the live series on every build — a
  /// data refresh (aggregation switch, series toggled off) used to leave
  /// stale spot references that crashed fl_chart's paint pass.
  final Map<int, int> _chartHover = {};
  bool _viewPrefsReady = false;
  late final String? _viewUserId = getIt<AuthGate>().currentUser?.uid;

  /// Selected contribution parameter, persisted only as a local view choice.
  String? _donutParameter;

  List<Map<String, dynamic>> _readItems() {
    final raw = widget.initial?['items_json'];
    if (raw is! String) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List
          ? [
              for (final e in decoded.whereType<Map>())
                Map<String, dynamic>.from(e),
            ]
          : [];
    } on FormatException {
      return [];
    }
  }

  Set<String> _readGraphParameters() {
    final raw = widget.initial?['graph_parameters_json'];
    if (raw is! String) return {'protein', 'fat'};
    try {
      final value = jsonDecode(raw);
      return value is List
          ? value.map((e) => '$e').toSet()
          : {'protein', 'fat'};
    } on FormatException {
      return {'protein', 'fat'};
    }
  }

  DateTime get _periodStart => switch (_mode) {
    _PeriodMode.day => DateTime(_selected.year, _selected.month, _selected.day),
    _PeriodMode.month => DateTime(_selected.year, _selected.month, 1),
    _PeriodMode.year => DateTime(_selected.year, 1, 1),
    _PeriodMode.range => DateTime(_from.year, _from.month, _from.day),
  };
  DateTime get _periodEnd => switch (_mode) {
    _PeriodMode.day => DateTime(_selected.year, _selected.month, _selected.day),
    _PeriodMode.month => DateTime(_selected.year, _selected.month + 1, 0),
    _PeriodMode.year => DateTime(_selected.year, 12, 31),
    _PeriodMode.range => DateTime(_to.year, _to.month, _to.day),
  };

  List<FormulationIngredient> get _ingredients => [
    for (final row in _items)
      FormulationIngredient(
        materialId: (row['material_id'] as num).toInt(),
        name: '${row['material_name'] ?? ''}',
        quantityKg: FormulationCalculator.number(row['quantity_kg']) ?? 0,
        pricePerKg: FormulationCalculator.number(row['price_per_kg']),
      ),
  ];

  Future<void> _refresh({bool loadSources = true}) async {
    final generation = ++_refreshGeneration;
    final ids = _items
        .map((row) => (row['material_id'] as num).toInt())
        .toSet()
        .toList();
    if (ids.isEmpty) {
      _receiptRequest = null;
      setState(() {
        _busy = false;
        _sourcesReady = true;
        _calculation = FormulationCalculator.calculate(
          ingredients: [],
          averages: {},
        );
        _spotsByParameter = {};
        _axisLabels = [];
        _axisRangeLabels = [];
        _receipts = [];
        _chartHover.clear();
        _sourceHints = [];
      });
      return;
    }
    setState(() {
      _busy = true;
      _sourcesReady = false;
    });
    try {
      if (loadSources || _receiptRequest == null) {
        _trackingCache.clear();
        _trackingReceipts = null;
        final today = DateTime.now();
        _receiptRequest = widget.repo.receipts(
          ids,
          DateTime(1900, 1, 1),
          _periodEnd.isAfter(today) ? _periodEnd : today,
        );
      }
      final receipts = await _receiptRequest!;
      if (!mounted || generation != _refreshGeneration) return;
      // Only the newest refresh may start work. Rapid control changes wait
      // for the current worker rather than spawning competing calculations.
      while (_trackingTask != null) {
        try {
          await _trackingTask;
        } on Object {
          // The owning refresh reports its error; the newest request can retry.
        }
        if (!mounted || generation != _refreshGeneration) return;
      }
      if (!identical(_trackingReceipts, receipts)) {
        _trackingReceipts = receipts;
        _trackingCache.clear();
      }
      final chart = _chartBuckets();
      final ingredients = _ingredients;
      final key = jsonEncode({
        'items': [
          for (final row in ingredients)
            [row.materialId, row.name, row.quantityKg, row.pricePerKg],
        ],
        'from': _periodStart.toIso8601String(),
        'to': _periodEnd.toIso8601String(),
        'buckets': [
          for (final bucket in chart)
            [bucket.$1.toIso8601String(), bucket.$2.toIso8601String()],
        ],
        'parameters': _graphParameters.toList()..sort(),
        'aggregation': _aggregation.name,
        'source': _dataSource.name,
      });
      var tracking = _trackingCache.remove(key);
      if (tracking == null) {
        final request = FormulationTrackingRequest(
          ingredients: ingredients,
          receipts: receipts,
          from: _periodStart,
          to: _periodEnd,
          buckets: [
            for (final bucket in chart)
              FormulationChartBucket(bucket.$1, bucket.$2),
          ],
          parameters: Set.of(_graphParameters),
          aggregation: _aggregation,
          dataSource: _dataSource,
        );
        if (request.needsIsolate) {
          final task = compute(calculateFormulationTracking, request);
          _trackingTask = task;
          try {
            tracking = await task;
          } finally {
            if (identical(_trackingTask, task)) _trackingTask = null;
          }
        } else {
          tracking = calculateFormulationTracking(request);
        }
      }
      // A finished older worker must never overwrite a newer selection.
      if (!mounted || generation != _refreshGeneration) return;
      _trackingCache[key] = tracking;
      if (_trackingCache.length > (widget.fullScreen ? 3 : 8)) {
        _trackingCache.remove(_trackingCache.keys.first);
      }
      final current = tracking.current;
      final spots = {
        for (final entry in tracking.series.entries)
          entry.key: [
            for (var i = 0; i < entry.value.length; i++)
              entry.value[i] == null || !entry.value[i]!.isFinite
                  ? FlSpot.nullSpot
                  : FlSpot(i.toDouble(), entry.value[i]!),
          ],
      };
      final labels = [for (final bucket in chart) bucket.$3];
      final hints = [
        for (final row in current.ingredients)
          {
            'material_id': row.ingredient.materialId,
            'name': row.ingredient.name,
            'parameters': {
              for (final entry in row.parameters.entries)
                entry.key: {
                  'source': entry.value.source,
                  'receipts': entry.value.receipts,
                  'code': entry.value.receiptCode,
                  'date': entry.value.receiptDate.toIso8601String(),
                  'fallback': entry.value.usedFallback,
                  'fallback_after': entry.value.usedFutureFallback,
                  'value': entry.value.value,
                },
            },
          },
      ];
      if (mounted) {
        setState(() {
          _receipts = receipts;
          _calculation = current;
          _sourcesReady = true;
          _sourceHints = hints;
          _spotsByParameter = spots;
          _chartHover.clear();
          _axisLabels = labels;
          _axisRangeLabels = [
            for (final bucket in chart)
              '${_displayDate(bucket.$1)} - ${_displayDate(bucket.$2)}',
          ];
          _busy = false;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _refreshGeneration) {
        _receiptRequest = null;
        setState(() {
          _busy = false;
          _error = AppError.friendly(error);
        });
      }
    }
  }

  List<(DateTime, DateTime, String)> _chartBuckets() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final buckets = formulationChartBuckets(
      from: _periodStart,
      to: _periodEnd.isAfter(today) ? today : _periodEnd,
      interval: _resolvedChartInterval,
    );
    return [
      for (final bucket in buckets)
        (
          bucket.from,
          bucket.to,
          _resolvedChartInterval == FormulationChartInterval.month
              ? _monthName(bucket.from.month)
              : '${bucket.from.day}/${bucket.from.month}',
        ),
    ];
  }

  FormulationChartInterval get _resolvedChartInterval =>
      _chartInterval != FormulationChartInterval.automatic
      ? _chartInterval
      : _mode == _PeriodMode.year ||
            (_mode == _PeriodMode.range &&
                _periodEnd.difference(_periodStart).inDays >= 31)
      ? FormulationChartInterval.month
      : FormulationChartInterval.day;

  String _monthName(int month) => AppText.t(
    const [
      'يناير',
      'فبراير',
      'مارس',
      'أبريل',
      'مايو',
      'يونيو',
      'يوليو',
      'أغسطس',
      'سبتمبر',
      'أكتوبر',
      'نوفمبر',
      'ديسمبر',
    ][month - 1],
    const [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ][month - 1],
  );
  String _displayDate(DateTime value) =>
      '${value.day} ${_monthName(value.month)} ${value.year}';

  @override
  void initState() {
    super.initState();
    _baseline = _draftSignature();
    _name.addListener(_syncCloseGuard);
    _sourceChanges = SyncDataChanges.stream.listen((_) {
      if (mounted && !_saving) unawaited(_refresh());
    });
    // The first refresh must never wait behind the preference file: the IO
    // future can stay pending (tests), so the initial frame refreshes with
    // the record's own settings and the second pass re-runs with the last
    // stored graph view once the preferences arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_refresh()));
    // Restore the last viewed window independently of source loading.
    unawaited(_bootstrap());
  }

  /// Absorbs the stored view preferences, then runs the first refresh.
  Future<void> _bootstrap() async {
    if (_viewing) await _restoreViewPrefs();
    if (!mounted) return;
    _viewPrefsReady = true;
    await _refresh();
  }

  /// Current graph cosmetics as a JSON map (never a business write; the map
  /// stays on this device in the organization's local file).
  Map<String, dynamic>? _viewPrefs() {
    final id = (widget.initial?['id'] as num?)?.toInt();
    if (id == null) {
      return null;
    }
    return {
      'period_mode': _mode.name,
      'selected': _selected.toIso8601String(),
      'from': _from.toIso8601String(),
      'to': _to.toIso8601String(),
      'aggregation': _aggregation.name,
      'chart_interval': _chartInterval.name,
      'data_source': _dataSource.name,
      'graph': _graphParameters.toList()..sort(),
      'donut': _donutParameter,
    };
  }

  void _storeViewPrefs() {
    if (!_viewPrefsReady || !_viewing) return;
    unawaited(
      FormulationViewPrefs.store(
        (widget.initial?['id'] as num?)?.toInt(),
        _viewPrefs() ?? const {},
        userId: _viewUserId,
      ),
    );
  }

  /// Applies the stored graph view preferences before the first refresh.
  Future<void> _restoreViewPrefs() async {
    final id = (widget.initial?['id'] as num?)?.toInt();
    final originalView = jsonEncode(_viewPrefs());
    final prefs = await FormulationViewPrefs.load(id, userId: _viewUserId);
    if (!mounted || prefs == null || originalView != jsonEncode(_viewPrefs())) {
      return;
    }
    setState(() {
      final forceRange = widget.initialFrom != null || widget.initialTo != null;
      if (!forceRange) {
        final mode = _PeriodMode.values
            .where((value) => value.name == prefs['period_mode'])
            .firstOrNull;
        if (mode != null) {
          _mode = mode;
        }
        final selected = DateTime.tryParse('${prefs['selected'] ?? ''}');
        if (selected != null) {
          _selected = selected;
        }
        final from = DateTime.tryParse('${prefs['from'] ?? ''}');
        if (from != null) {
          _from = from;
        }
        final to = DateTime.tryParse('${prefs['to'] ?? ''}');
        if (to != null) {
          _to = to;
        }
      }
      final aggregation = FormulationAggregation.values
          .where((value) => value.name == prefs['aggregation'])
          .firstOrNull;
      if (aggregation != null) {
        _aggregation = aggregation;
      }
      final interval = FormulationChartInterval.values
          .where((value) => value.name == prefs['chart_interval'])
          .firstOrNull;
      if (interval != null) {
        _chartInterval = interval;
      }
      final source = FormulationDataSource.values
          .where((value) => value.name == prefs['data_source'])
          .firstOrNull;
      if (source != null) {
        _dataSource = source;
      }
      final graph = prefs['graph'];
      if (graph is List) {
        _graphParameters
          ..clear()
          ..addAll([for (final key in graph) '$key']);
      }
      if (prefs['donut'] is String) {
        _donutParameter = prefs['donut'] as String?;
      }
    });
    // View choices never contribute to unsaved ingredient edits.
    _syncCloseGuard();
  }

  @override
  void dispose() {
    _storeViewPrefs();
    unawaited(_sourceChanges?.cancel());
    _closeGuard.dispose();
    _name.dispose();
    for (final row in _items) {
      (row['_quantity'] as TextEditingController?)?.dispose();
      (row['_price'] as TextEditingController?)?.dispose();
    }
    super.dispose();
  }

  Future<void> _selectDate() async {
    if (_authoringLocked) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _selected = picked);
    await _refresh();
  }

  Future<void> _selectRange() async {
    if (_authoringLocked) return;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(
        start: _from,
        end: _to.isBefore(_from) ? _from : _to,
      ),
    );
    if (picked == null) return;
    setState(() {
      _from = picked.start;
      _to = picked.end;
    });
    await _refresh();
  }

  String _periodLabel() => switch (_mode) {
    _PeriodMode.day => _selected.toIso8601String().substring(0, 10),
    _PeriodMode.month =>
      '${_selected.year}-${_selected.month.toString().padLeft(2, '0')}',
    _PeriodMode.year => '${_selected.year}',
    _PeriodMode.range =>
      '${_from.toIso8601String().substring(0, 10)} – ${_to.toIso8601String().substring(0, 10)}',
  };

  /// Physical-only receipt keys (density, separation, visual checks…).
  /// Nutrition formulations analyse chemistry: these must never become chart
  /// series, KPI tiles or source pills.
  Set<String> get _physicalKeys => {
    for (final receipt in _receipts) ...receipt.physicalKeys,
  };

  /// Manual chart hover bookkeeping (built-in touches are off). On exit or
  /// any non-interested event the hover is dropped.
  void _handleChartTouch(FlTouchEvent event, LineTouchResponse? response) {
    final spots = response?.lineBarSpots;
    if (!event.isInterestedForInteractions || spots == null || spots.isEmpty) {
      if (widget.fullScreen) return; // A phone tap keeps its readout visible.
      if (_chartHover.isNotEmpty) {
        setState(_chartHover.clear);
      }
      return;
    }
    final touched = spots
        .where((spot) => spot.x.isFinite && spot.y.isFinite)
        .firstOrNull;
    if (touched == null) return;
    final index = touched.x.round();
    final series = _seriesOrder()
        .where(
          (entry) => _spotsByParameter[entry.$1]!.any((spot) => !spot.isNull()),
        )
        .toList();
    final next = {
      for (var bar = 0; bar < series.length; bar++)
        if (index >= 0 &&
            index < _spotsByParameter[series[bar].$1]!.length &&
            !_spotsByParameter[series[bar].$1]![index].isNull())
          bar: index,
    };
    final changed =
        _chartHover.length != next.length ||
        next.keys.any((bar) => _chartHover[bar] != next[bar]);
    if (!changed) return;
    setState(() {
      _chartHover
        ..clear()
        ..addAll(next);
    });
  }

  Widget _chartLayout(Widget chart) {
    if (!widget.fullScreen) {
      return SizedBox(height: 220, child: chart);
    }
    return SizedBox(
      height: 230,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: chart),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(width: 96, child: _chartReadout()),
        ],
      ),
    );
  }

  Widget _chartReadout() {
    final series = _seriesOrder();
    var point = _chartHover.values.firstOrNull;
    if (point == null) {
      for (var index = _axisLabels.length - 1; index >= 0; index--) {
        if (series.any(
          (entry) =>
              index < _spotsByParameter[entry.$1]!.length &&
              !_spotsByParameter[entry.$1]![index].isNull(),
        )) {
          point = index;
          break;
        }
      }
    }
    return AppCard(
      key: const ValueKey('formulation-chart-readout'),
      flat: true,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppText.t('قيم النقطة', 'Point values'),
              style: TextStyle(
                color: AppColors.textStrong,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              point != null && point < _axisRangeLabels.length
                  ? _axisRangeLabels[point]
                  : AppText.t('المس نقطة على الرسم', 'Tap a chart point'),
              style: TextStyle(color: AppColors.textStrong, fontSize: 10),
            ),
            for (final entry in series)
              if (point != null &&
                  point < _spotsByParameter[entry.$1]!.length &&
                  !_spotsByParameter[entry.$1]![point].isNull()) ...[
                const Divider(height: 12),
                Text(
                  _parameterName(entry.$1),
                  style: TextStyle(color: AppColors.textStrong, fontSize: 11),
                ),
                Text(
                  _formatPointValue(_spotsByParameter[entry.$1]![point].y),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    color: AppColors.textStrong,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }

  Future<void> _chooseParameters() async {
    if (_authoringLocked || _choosingParameters) return;
    setState(() {
      _choosingParameters = true;
      _loadingParameterCatalog = true;
    });
    try {
      // Reload on demand: analyses added since this graph opened are available.
      final catalogue = await widget.repo.parameters();
      if (!mounted) return;
      setState(() {
        _parameterCatalog = catalogue;
        _loadingParameterCatalog = false;
      });
      final excluded = _physicalKeys;
      final keys = <String>{
        ...FormulationCalculator.names.keys,
        for (final row in catalogue)
          formulationParameterKey('${row['parameter_name'] ?? ''}'),
        ...?_calculation?.parameters.keys,
        for (final receipt in _receipts) ...receipt.values.keys,
        for (final receipt in _receipts) ...receipt.inspectionValues.keys,
        for (final receipt in _receipts) ...receipt.labHistory.keys,
        ..._graphParameters,
      }..removeWhere((key) => key.isEmpty || excluded.contains(key));
      final selected = await showFormulationParameterPicker(
        context,
        fullScreen: widget.fullScreen,
        options: {for (final key in keys) key: _parameterName(key)},
        selected: _graphParameters,
        plotted: {
          for (final entry
              in _calculation?.parameters.entries ??
                  const <MapEntry<String, double?>>[])
            if (entry.value != null) entry.key,
        },
      );
      if (!mounted || selected == null) return;
      setState(() {
        _graphParameters
          ..clear()
          ..addAll(selected);
      });
      await _refresh(loadSources: false);
    } catch (error) {
      if (mounted) {
        AppFeedback.errorFrom(
          context,
          error,
          summary: AppText.t('تعذر تحميل التحاليل', 'Could not load analyses'),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _choosingParameters = false;
          _loadingParameterCatalog = false;
        });
      }
    }
  }

  Widget _graph() {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    AppText.t('تغيّر التحليل عبر الفترة', 'Analysis trend'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
                AppInfoHint(
                  label: AppText.t('خامات التركيبة', 'Formulation ingredients'),
                  message: _items
                      .map(
                        (item) =>
                            '${item['material_name']}: ${item['quantity_kg']} kg',
                      )
                      .join('\n'),
                ),
                AppTooltip(
                  message: AppText.t('اختيار التحاليل', 'Choose parameters'),
                  child: AppButton(
                    label: AppText.t('إعداد التحاليل', 'Analysis settings'),
                    icon: const Icon(Icons.tune, size: 19),
                    small: true,
                    style: AppButtonStyle.secondary,
                    loading: _loadingParameterCatalog,
                    onPressed: _authoringLocked || _choosingParameters
                        ? null
                        : _chooseParameters,
                  ),
                ),
              ],
            ),
            Text(_periodLabel(), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            // Statistic labels intentionally stay English in both UI languages.
            SegmentedButton<FormulationAggregation>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 6),
                ),
                minimumSize: WidgetStatePropertyAll(Size(0, 44)),
              ),
              segments: [
                ButtonSegment(
                  value: FormulationAggregation.average,
                  label: Text('Mean', style: const TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: FormulationAggregation.minimum,
                  label: Text('Min', style: const TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: FormulationAggregation.maximum,
                  label: Text('Max', style: const TextStyle(fontSize: 12)),
                ),
                const ButtonSegment(
                  value: FormulationAggregation.mode,
                  label: Text('Mode', style: TextStyle(fontSize: 12)),
                  tooltip: 'Most frequent value; highest value wins a tie',
                ),
              ],
              selected: {_aggregation},
              onSelectionChanged: _authoringLocked
                  ? null
                  : (value) {
                      setState(() => _aggregation = value.first);
                      unawaited(_refresh(loadSources: false));
                    },
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppSelectField<FormulationChartInterval>(
                    key: const ValueKey('formulation-chart-interval'),
                    initialValue: _chartInterval,
                    selectedItemBuilder: (_) => [
                      for (final interval in FormulationChartInterval.values)
                        Text(switch (interval) {
                          FormulationChartInterval.automatic => AppText.t(
                            'تلقائي',
                            'Auto',
                          ),
                          FormulationChartInterval.day => AppText.t(
                            'يومي',
                            'Daily',
                          ),
                          FormulationChartInterval.week => AppText.t(
                            'أسبوعي',
                            'Weekly',
                          ),
                          FormulationChartInterval.month => AppText.t(
                            'شهري',
                            'Monthly',
                          ),
                        }),
                    ],
                    decoration: InputDecoration(
                      labelText: AppText.t(
                        'كل نقطة تمثل',
                        'Each point represents',
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: FormulationChartInterval.automatic,
                        child: Text(
                          AppText.t('تلقائي حسب الفترة', 'Automatic by period'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: FormulationChartInterval.day,
                        child: Text(AppText.t('يومًا', 'One day')),
                      ),
                      DropdownMenuItem(
                        value: FormulationChartInterval.week,
                        child: Text(
                          AppText.t(
                            'أسبوعًا (السبت - الجمعة)',
                            'One week (Sat - Fri)',
                          ),
                        ),
                      ),
                      DropdownMenuItem(
                        value: FormulationChartInterval.month,
                        child: Text(AppText.t('شهرًا', 'One month')),
                      ),
                    ],
                    onChanged: _authoringLocked
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() => _chartInterval = value);
                            unawaited(_refresh(loadSources: false));
                          },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppSelectField<FormulationDataSource>(
                    key: const ValueKey('formulation-data-source'),
                    initialValue: _dataSource,
                    decoration: InputDecoration(
                      labelText: AppText.t('المصدر', 'Source'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: FormulationDataSource.all,
                        child: Text(AppText.t('الكل', 'All')),
                      ),
                      DropdownMenuItem(
                        value: FormulationDataSource.lab,
                        child: Text(AppText.t('المعمل فقط', 'Lab only')),
                      ),
                      DropdownMenuItem(
                        value: FormulationDataSource.nir,
                        child: Text(AppText.t('NIR فقط', 'NIR only')),
                      ),
                    ],
                    onChanged: _authoringLocked
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() => _dataSource = value);
                            unawaited(_refresh(loadSources: false));
                          },
                  ),
                ),
              ],
            ),
            if (_resolvedChartInterval == FormulationChartInterval.week)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  AppText.t(
                    'كل أسبوع من السبت إلى الجمعة',
                    'Each week runs Saturday to Friday',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            _chartLayout(
              _spotsByParameter.isEmpty || _graphParameters.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.show_chart,
                            size: 32,
                            color: AppColors.textMuted.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            AppText.t(
                              'لا توجد نقاط مكتملة للعرض',
                              'No complete data points',
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    )
                  : () {
                      final rtl =
                          Directionality.of(context) == TextDirection.rtl;
                      // fl_chart crashes on a series whose spots are all
                      // null (mostRightSpot never initialized), and such a
                      // series has nothing to show anyway — skip it.
                      final seriesEntries = <(String, Color)>[];
                      final lineBars = <LineChartBarData>[];
                      for (final entry in _seriesOrder()) {
                        final spots = _spotsByParameter[entry.$1]!;
                        if (!spots.any((spot) => !spot.isNull())) continue;
                        final barIndex = lineBars.length;
                        final hovered = _chartHover[barIndex];
                        seriesEntries.add(entry);
                        lineBars.add(
                          LineChartBarData(
                            spots: spots,
                            isCurved: spots.length < 200,
                            preventCurveOverShooting: true,
                            barWidth: 2.5,
                            dotData: FlDotData(show: spots.length < 20),
                            color: entry.$2,
                            // Hover highlight rebuilt from live data only.
                            showingIndicators: [
                              if (hovered != null &&
                                  hovered >= 0 &&
                                  hovered < spots.length &&
                                  !spots[hovered].isNull())
                                hovered,
                            ],
                          ),
                        );
                      }
                      if (lineBars.isEmpty) {
                        return Center(
                          child: Text(
                            AppText.t(
                              'لا توجد نقاط مكتملة للعرض',
                              'No complete data points',
                            ),
                          ),
                        );
                      }
                      // Tooltip spots are constructed from the live series,
                      // never from fl_chart's retained touch state.
                      final hoverSpots = <LineBarSpot>[];
                      for (final hovered in _chartHover.entries) {
                        if (hovered.key >= lineBars.length) continue;
                        final spots = lineBars[hovered.key].spots;
                        final index = hovered.value;
                        if (index < 0 || index >= spots.length) continue;
                        if (spots[index].isNull()) continue;
                        hoverSpots.add(
                          LineBarSpot(
                            lineBars[hovered.key],
                            hovered.key,
                            spots[index],
                          ),
                        );
                      }
                      hoverSpots.sort((a, b) => b.y.compareTo(a.y));
                      return LineChart(
                        LineChartData(
                          minX: 0,
                          maxX:
                              (_axisLabels.length > 1
                                      ? _axisLabels.length - 1
                                      : 1)
                                  .toDouble(),
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: AppColors.borderMuted,
                              strokeWidth: 1,
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          // One label per line anchors the name and value to
                          // its own point rather than grouping them at one Y.
                          showingTooltipIndicators: [
                            if (!widget.fullScreen && hoverSpots.isNotEmpty)
                              ShowingTooltipIndicators(hoverSpots),
                          ],
                          lineTouchData: LineTouchData(
                            // Hover is tracked here so every tooltip and
                            // indicator is rebuilt from the current data;
                            // fl_chart's retained touch state used to carry
                            // stale indices after a refresh and crash paint.
                            handleBuiltInTouches: false,
                            touchCallback: _handleChartTouch,
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipColor: (_) =>
                                  AppChartPalette.tooltipBackground,
                              tooltipRoundedRadius: 8,
                              tooltipPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              maxContentWidth: 220,
                              fitInsideHorizontally: true,
                              fitInsideVertically: true,
                              getTooltipItems: (touchedSpots) => [
                                for (final spot in touchedSpots)
                                  if (spot.barIndex < seriesEntries.length)
                                    LineTooltipItem(
                                      '${_parameterName(seriesEntries[spot.barIndex].$1)}: ${_formatPointValue(spot.y)}',
                                      AppChartPalette.tooltipStyle(),
                                      textDirection: rtl
                                          ? TextDirection.rtl
                                          : TextDirection.ltr,
                                    )
                                  else
                                    null,
                              ],
                            ),
                            getTouchedSpotIndicator: (barData, indicators) => [
                              // Defensive: never index beyond the live spots
                              // (the built-in default does and crashes paint).
                              for (final index in indicators)
                                index >= 0 &&
                                        index < barData.spots.length &&
                                        !barData.spots[index].isNull()
                                    ? TouchedSpotIndicatorData(
                                        FlLine(
                                          color:
                                              barData.gradient?.colors.first ??
                                              barData.color ??
                                              AppColors.info,
                                          strokeWidth: 4,
                                        ),
                                        FlDotData(
                                          getDotPainter:
                                              (spot, percent, bar, index) =>
                                                  FlDotCirclePainter(
                                                    radius: 6,
                                                    color:
                                                        bar
                                                            .gradient
                                                            ?.colors
                                                            .first ??
                                                        bar.color ??
                                                        AppColors.info,
                                                  ),
                                        ),
                                      )
                                    : null,
                            ],
                          ),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            leftTitles: const AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 42,
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 32,
                                interval:
                                    (_axisLabels.length /
                                            (widget.fullScreen ? 3 : 6))
                                        .ceilToDouble()
                                        .clamp(1, 999),
                                getTitlesWidget: (value, meta) {
                                  final index = value.toInt();
                                  if (index < 0 ||
                                      index >= _axisLabels.length) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      _axisLabels[index],
                                      style: TextStyle(
                                        color: AppColors.textStrong,
                                        fontSize: 10,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          lineBarsData: lineBars,
                        ),
                        // Dense daily histories should not interpolate every
                        // point again on each animation/hover frame.
                        duration:
                            widget.fullScreen ||
                                lineBars.any(
                                  (bar) =>
                                      bar.spots.any((spot) => spot.isNull()),
                                ) ||
                                lineBars.fold<int>(
                                      0,
                                      (count, bar) => count + bar.spots.length,
                                    ) >
                                    200
                            ? Duration.zero
                            : const Duration(milliseconds: 150),
                      );
                    }(),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _seriesOrder())
                  _legendPill(entry.$2, _parameterName(entry.$1)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // Readout donuts under the chart: how the formulation weight is
            // split, and how a chosen parameter blends from which ingredient.
            _contributionDonuts(),
          ],
        ),
      ),
    );
  }

  Future<void> _addIngredient() async {
    final already = _items
        .map((e) => (e['material_id'] as num).toInt())
        .toSet();
    final choice = widget.materials
        .where((m) => !already.contains(m['id']))
        .toList();
    if (choice.isEmpty) return;
    // Open immediately. The picker loads only distinct material ids while
    // search and "All" remain usable; no historical lab calculations here.
    final receiptEnd = _periodEnd;
    final selected = await showAppContent<Map<String, dynamic>>(
      context,
      fullScreen: widget.fullScreen,
      title: AppText.t('اختيار خامة', 'Choose raw material'),
      scrollBody: false,
      height: 520,
      builder: (_, _) => _MaterialPicker(
        materials: choice,
        loadReceiptIds: () => widget.repo.materialIdsWithReceipts(receiptEnd),
        fullScreen: widget.fullScreen,
      ),
    );
    if (selected == null) return;
    setState(
      () => _items.add({
        'material_id': selected['id'],
        'material_name': selected['material_name'],
        'quantity_kg': 0,
        'price_per_kg': null,
      }),
    );
    await _refresh();
  }

  Future<void> _save(Map<String, dynamic> record) async {
    setState(() {
      _saving = true;
      _busy = true;
      _error = null;
    });
    try {
      await widget.repo.save(
        record,
        id: (widget.initial?['id'] as num?)?.toInt(),
      );
      if (mounted) {
        _closeGuard.canClose = true;
        Navigator.pop(context, true);
      }
    } on PendingOperation catch (pending) {
      if (mounted) {
        setState(() {
          _saving = false;
          _busy = false;
          _pendingMessage = pending.userMessage;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _busy = false;
          _error = AppError.friendly(error);
        });
      }
    }
  }

  Map<String, dynamic> _snapshot() => {
    'period_from': _periodStart.toIso8601String(),
    'period_to': _periodEnd.toIso8601String(),
    'total_kg': _calculation?.totalKg ?? 0,
    'total_cost': _calculation?.totalCost,
    'cost_per_kg': _calculation?.costPerKg,
    'parameters': _calculation?.parameters ?? {},
  };

  @override
  Widget build(BuildContext context) {
    final result = _calculation;
    return AppContentPopScope<bool>(
      guard: _closeGuard,
      child: AppWindow(
        fullScreen: widget.fullScreen,
        title: _viewing && widget.initial != null
            ? AppText.t('عرض التركيبة', 'Formulation graph')
            : widget.initial == null
            ? AppText.t('تركيبة جديدة', 'New formulation')
            : AppText.t('تعديل التركيبة', 'Edit formulation'),
        size: AppWindowSize.lg,
        height: 680,
        scrollBody: false,
        actions: [
          if (_busy)
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(),
              ),
            ),
          if (widget.writable && _viewing)
            AppButton(
              style: AppButtonStyle.ghost,
              onPressed: _busy || _saving || _pendingMessage != null
                  ? null
                  : () {
                      _storeViewPrefs();
                      setState(() => _viewing = false);
                    },
              icon: const Icon(Icons.edit_outlined),
              label: AppText.t('تعديل', 'Edit'),
            ),
          if (widget.writable && !_viewing)
            AppButton(
              style: AppButtonStyle.ghost,
              onPressed:
                  _busy ||
                      _saving ||
                      !_sourcesReady ||
                      _pendingMessage != null ||
                      _unresolvedProductReference
                  ? null
                  : () => _save({
                      'name': _name.text,
                      'product_id': _productId,
                      '_allow_product_unlink': _allowProductUnlink,
                      'items': [
                        for (final item in _items)
                          {
                            ...item,
                            'material_id': item['material_id'],
                            'material_name': item['material_name'],
                            'quantity_kg':
                                FormulationCalculator.number(
                                  item['quantity_kg'],
                                ) ??
                                0,
                            'price_per_kg': FormulationCalculator.number(
                              item['price_per_kg'],
                            ),
                          },
                      ],
                      'parameters': widget.initial != null
                          ? _settings
                          : {
                              'period': _mode.name,
                              'aggregation': _aggregation.name,
                              'chart_interval': _chartInterval.name,
                              'data_source': _dataSource.name,
                              'from': _periodStart.toIso8601String(),
                              'to': _periodEnd.toIso8601String(),
                            },
                      'graph_parameters': widget.initial != null
                          ? _readGraphParameters().toList()
                          : _graphParameters.toList(),
                      'calculation': _snapshot(),
                      'sources': _sourceHints,
                      'copied_from_id': widget.initial?['copied_from_id'],
                    }),
              icon: const Icon(Icons.save_outlined),
              label: AppText.t('حفظ', 'Save'),
            ),
        ],
        child: ListView(
          // AppWindow already supplies the mobile page inset.
          padding: widget.fullScreen
              ? EdgeInsets.zero
              : const EdgeInsets.all(AppSpacing.page),
          children: [
            if (_viewing)
              Text(
                _name.text,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textStrong,
                ),
              )
            else
              AppTextField(
                controller: _name,
                readOnly: !widget.writable || _authoringLocked,
                decoration: InputDecoration(
                  labelText: AppText.t('اسم التركيبة', 'Formulation name'),
                ),
              ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_viewing)
                    SizedBox(
                      width: widget.fullScreen ? constraints.maxWidth : 190,
                      child: AppSelectField<_PeriodMode>(
                        initialValue: _mode,
                        decoration: InputDecoration(
                          labelText: AppText.t('الفترة', 'Period'),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: _PeriodMode.day,
                            child: Text(AppText.t('يومي', 'Day')),
                          ),
                          DropdownMenuItem(
                            value: _PeriodMode.month,
                            child: Text(AppText.t('شهري', 'Month')),
                          ),
                          DropdownMenuItem(
                            value: _PeriodMode.year,
                            child: Text(AppText.t('سنوي', 'Year')),
                          ),
                          DropdownMenuItem(
                            value: _PeriodMode.range,
                            child: Text(AppText.t('من–إلى', 'Custom range')),
                          ),
                        ],
                        onChanged: _authoringLocked
                            ? null
                            : (value) async {
                                if (value == null) return;
                                setState(() => _mode = value);
                                if (value == _PeriodMode.range) {
                                  await _selectRange();
                                } else {
                                  await _selectDate();
                                }
                                if (mounted) await _refresh();
                              },
                      ),
                    ),
                  if (_viewing)
                    SizedBox(
                      width: widget.fullScreen ? constraints.maxWidth : null,
                      child: AppButton(
                        style: AppButtonStyle.secondary,
                        onPressed: _mode == _PeriodMode.range
                            ? _selectRange
                            : _selectDate,
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: _periodLabel(),
                      ),
                    ),
                  if (!_viewing)
                    SizedBox(
                      width: widget.fullScreen ? constraints.maxWidth : 240,
                      child: AppSelectField<int?>(
                        initialValue: _productId,
                        decoration: InputDecoration(
                          labelText: AppText.t(
                            'المنتج (اختياري)',
                            'Product (optional)',
                          ),
                        ),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text(AppText.t('بدون ربط', 'Not linked')),
                          ),
                          for (final row in widget.products)
                            DropdownMenuItem<int?>(
                              value: (row['id'] as num).toInt(),
                              child: Text('${row['name']}'),
                            ),
                        ],
                        onChanged: _viewing || _authoringLocked
                            ? null
                            : (value) => setState(() {
                                _productId = value;
                                _allowProductUnlink = true;
                              }),
                      ),
                    ),
                  if (_productId != null)
                    AppButton(
                      style: AppButtonStyle.ghost,
                      onPressed: () => context.go(
                        '/inspections?products=1&product=$_productId&from=${_periodStart.toIso8601String().substring(0, 10)}&to=${_periodEnd.toIso8601String().substring(0, 10)}',
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: AppText.t('فحوصات المنتج', 'Product inspections'),
                    ),
                ],
              ),
            ),
            if (_unresolvedProductReference)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppText.t(
                      'مرجع المنتج المحفوظ غير متاح. اختر منتجًا أو أكّد فك ارتباطه قبل الحفظ.',
                      'The saved product reference is unavailable. Choose a product or explicitly unlink it before saving.',
                    ),
                  ),
                  if (widget.writable && !_viewing)
                    AppButton(
                      label: AppText.t(
                        'فك ارتباط المنتج المفقود',
                        'Unlink missing product',
                      ),
                      style: AppButtonStyle.ghost,
                      onPressed: _authoringLocked
                          ? null
                          : () => setState(() => _allowProductUnlink = true),
                    ),
                ],
              ),
            if (_pendingMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _pendingMessage!,
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            // The editing page stays focused on the items: name, period and
            // quantities — no chart. The graph lives on its own view page.
            if (_viewing) ...[_graph(), const SizedBox(height: AppSpacing.md)],
            AppCard(
              padding: EdgeInsets.all(
                widget.fullScreen ? AppSpacing.sm : AppSpacing.md,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: [
                    _kpi(
                      context,
                      width: widget.fullScreen
                          ? (constraints.maxWidth - AppSpacing.md) / 2
                          : 210,
                      icon: Icons.scale_outlined,
                      color: AppColors.primary,
                      label: AppText.t('الوزن', 'Weight'),
                      value: '${result?.totalKg.toStringAsFixed(1) ?? '0'} kg',
                    ),
                    for (final entry
                        in result?.parameters.entries ??
                            const <MapEntry<String, double?>>[])
                      // Only the parameters enabled on the trend chart appear as
                      // cards, plus cost per kilo — the row stays focused on what
                      // the user is actually tracking.
                      if (_graphParameters.contains(entry.key) &&
                          !_physicalKeys.contains(entry.key))
                        _kpi(
                          context,
                          width: widget.fullScreen
                              ? (constraints.maxWidth - AppSpacing.md) / 2
                              : 210,
                          icon: Icons.insights,
                          color: _parameterColor(entry.key),
                          label: _parameterName(entry.key),
                          value: entry.value?.toStringAsFixed(2) ?? '—',
                        ),
                    _kpi(
                      context,
                      width: widget.fullScreen
                          ? (constraints.maxWidth - AppSpacing.md) / 2
                          : 210,
                      icon: Icons.payments_outlined,
                      color: AppColors.success,
                      label: AppText.t('التكلفة', 'Total cost'),
                      value: result?.totalCost?.toStringAsFixed(2) ?? '—',
                    ),
                    _kpi(
                      context,
                      width: widget.fullScreen
                          ? (constraints.maxWidth - AppSpacing.md) / 2
                          : 210,
                      icon: Icons.sell_outlined,
                      color: AppColors.warning,
                      label: AppText.t('سعر الكيلو', 'Cost per kg'),
                      value: result?.costPerKg?.toStringAsFixed(3) ?? '—',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (!_viewing)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppText.t('الخامات', 'Ingredients'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (widget.writable && !_viewing)
                    IconButton(
                      onPressed: _authoringLocked ? null : _addIngredient,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                ],
              ),
            if (!_viewing)
              for (var index = 0; index < _items.length; index++)
                _ingredientTile(index),
          ],
        ),
      ),
    );
  }

  Widget _ingredientTile(int index) {
    final item = _items[index];
    final hint = _sourceHints
        .where((row) => row['material_id'] == item['material_id'])
        .firstOrNull;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${item['material_name']}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                AppInfoHint(
                  message: _sourceTooltip(hint),
                  label: AppText.t('تحليل الخامة', 'Ingredient analysis'),
                  onTap: () async {
                    final mayLeave = await _closeGuard.resolveClose();
                    if (!mounted || !mayLeave) {
                      return;
                    }
                    context.go(
                      '/inspections?formulation=1&material=${item['material_id']}'
                      '&from=${_periodStart.toIso8601String().substring(0, 10)}'
                      '&to=${_periodEnd.toIso8601String().substring(0, 10)}',
                    );
                  },
                ),
                if (widget.writable && !_viewing)
                  IconButton(
                    tooltip: AppText.t('إزالة', 'Remove'),
                    onPressed: _authoringLocked
                        ? null
                        : () async {
                            setState(() => _items.removeAt(index));
                            await _refresh();
                          },
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
            if (!widget.fullScreen) ...[
              const SizedBox(height: 8),
              _sourcePills(hint),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: AppField(
                    key: ValueKey('q-$index-${item['material_id']}'),
                    initialValue: '${item['quantity_kg'] ?? 0}',
                    enabled: widget.writable && !_authoringLocked && !_viewing,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    label: AppText.t('الكمية (كجم)', 'Quantity (kg)'),
                    onChanged: (value) {
                      item['quantity_kg'] =
                          FormulationCalculator.number(value) ?? 0;
                      _refresh(loadSources: false);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppField(
                    key: ValueKey('p-$index-${item['material_id']}'),
                    initialValue: '${item['price_per_kg'] ?? ''}',
                    enabled: widget.writable && !_authoringLocked && !_viewing,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    label: AppText.t('سعر الكيلو', 'Price per kg'),
                    onChanged: (value) {
                      item['price_per_kg'] = FormulationCalculator.number(
                        value,
                      );
                      _refresh(loadSources: false);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Per-ingredient analysis pills: one per sourced parameter (value +
  /// fallback tone), or a muted "no analysis" pill when the period has none.
  Widget _sourcePills(Map<String, dynamic>? hint) {
    final excluded = _physicalKeys;
    final parameters = hint?['parameters'] as Map<String, dynamic>? ?? {};
    final pills = <Widget>[
      for (final entry in parameters.entries)
        if (entry.value is Map && !excluded.contains(entry.key))
          () {
            final value = Map<String, dynamic>.from(entry.value as Map);
            final fallback = value['fallback'] == true;
            final source = '${value['source']}';
            // Lab-sourced values carry a flask badge so the user can see at a
            // glance which numbers came from the lab and which from the
            // inspection sheet.
            final labSourced = source == 'lab' || source == 'mixed';
            final raw = value['value'];
            final number = raw is num ? raw.toStringAsFixed(2) : '$raw';
            return _formulationPill(
              '${_parameterName(entry.key)}: $number${fallback ? ' · ${_fallbackName(value['fallback_after'] == true)}' : ''}',
              color: fallback
                  ? AppColors.warning
                  : labSourced
                  ? AppColors.accent
                  : AppColors.info,
              icon: labSourced ? Icons.science_outlined : null,
            );
          }(),
    ];
    if (pills.isEmpty) {
      return _formulationPill(
        AppText.t(
          'لا يوجد تحليل صالح في هذه الفترة',
          'No valid analysis in this period',
        ),
        color: AppColors.textMuted,
      );
    }
    return Wrap(spacing: 6, runSpacing: 4, children: pills);
  }

  String _sourceTooltip(Map<String, dynamic>? hint) {
    if (hint == null) {
      return AppText.t(
        'لا يوجد تحليل صالح في هذه الفترة',
        'No valid analysis in this period',
      );
    }
    final parameters = hint['parameters'] as Map<String, dynamic>? ?? {};
    if (parameters.isEmpty) {
      return AppText.t(
        'لا يوجد تحليل صالح في هذه الفترة',
        'No valid analysis in this period',
      );
    }
    final excluded = _physicalKeys;
    return [
      for (final entry in parameters.entries)
        if (entry.value is Map && !excluded.contains(entry.key))
          () {
            final value = Map<String, dynamic>.from(entry.value as Map);
            if (value['source'] == 'missing') {
              return '${_parameterName(entry.key)}: 0 (${AppText.t('لا يوجد تحليل؛ محسوب بصفر', 'No analysis; counted as zero')})';
            }
            final date = DateTime.tryParse('${value['date'] ?? ''}');
            final source = switch ('${value['source']}') {
              'lab' => AppText.t('المعمل', 'Lab'),
              'mixed' => AppText.t('مصادر متعددة', 'Mixed sources'),
              _ => AppText.t('الفحص', 'Inspection'),
            };
            final detail = value['fallback'] == true
                ? '${_fallbackName(value['fallback_after'] == true)} · ${value['code']}'
                : 'متوسط ${value['receipts']} محاضر · آخر محضر ${value['code']}';
            return '${_parameterName(entry.key)}: ${value['value']}'
                ' ($source · $detail'
                '${date == null ? '' : ' · ${date.toIso8601String().substring(0, 10)}'})';
          }(),
    ].join('\n');
  }

  /// Two donut readouts under the trend chart: the weight share of every
  /// ingredient, and — for a chosen analysis parameter — how much each
  /// ingredient contributes to the blended value (quantity × analysis value).
  Widget _contributionDonuts() {
    final result = _calculation;
    if (result == null || result.ingredients.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Side by side only when there is room (desktop dialog); phones stack
        // the two cards full width so the donut+legend row never squeezes.
        final width = widget.fullScreen
            ? constraints.maxWidth
            : (constraints.maxWidth - AppSpacing.md) / 2;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _weightDonut(result, width),
            _parameterDonut(result, width),
          ],
        );
      },
    );
  }

  /// Weight share of each ingredient — `share` is already a percent.
  Widget _weightDonut(FormulationResult result, double width) {
    return _donutCard(
      width: width,
      title: AppText.t('مشاركة كل خامة', 'Ingredient share'),
      subtitle: AppText.t('حسب الوزن (كجم)', 'By weight (kg)'),
      slices: [
        for (var i = 0; i < result.ingredients.length; i++)
          (
            result.ingredients[i].ingredient.name,
            result.ingredients[i].share,
            AppChartPalette.forIndex(i),
          ),
      ],
      emptyLabel: AppText.t(
        'أدخل كميات الخامات لعرض التوزيع',
        'Enter ingredient quantities to see the split',
      ),
    );
  }

  /// How a chosen parameter (e.g. protein) blends: each ingredient's weighted
  /// contribution — quantity × its own analysis value — as a share of the mix.
  Widget _parameterDonut(FormulationResult result, double width) {
    final candidates = [
      for (final entry in result.parameters.entries)
        if (entry.value != null && !_physicalKeys.contains(entry.key))
          entry.key,
    ];
    if (candidates.isEmpty) {
      return _donutCard(
        width: width,
        title: AppText.t('مصدر التحليل', 'Parameter contribution'),
        subtitle: AppText.t(
          'من أي خامة جاءت نسبة التحليل',
          'Which ingredient contributes what',
        ),
        slices: const [],
        emptyLabel: AppText.t(
          'لا يوجد تحليل مكتمل في هذه الفترة',
          'No complete analysis in this period',
        ),
      );
    }
    final selected = candidates.contains(_donutParameter)
        ? _donutParameter!
        : candidates.first;
    final contributions = <double>[
      for (final ingredient in result.ingredients)
        () {
          final value = ingredient.parameters[selected]?.value;
          return (value == null || value <= 0)
              ? 0.0
              : ingredient.ingredient.quantityKg * value;
        }(),
    ];
    return _donutCard(
      width: width,
      title: AppText.t('مصدر التحليل', 'Parameter contribution'),
      subtitle: AppText.t(
        'من أي خامة جاءت نسبة التحليل',
        'Which ingredient contributes what',
      ),
      slices: [
        for (var i = 0; i < result.ingredients.length; i++)
          (
            result.ingredients[i].ingredient.name,
            contributions[i],
            AppChartPalette.forIndex(i),
          ),
      ],
      emptyLabel: AppText.t(
        'لا يوجد تحليل صالح لـ ${_parameterName(selected)}',
        'No valid analysis for ${_parameterName(selected)}',
      ),
      centerValue: result.parameters[selected] == null
          ? null
          : _formatPointValue(result.parameters[selected]!),
      selector: AppSelectField<String>(
        key: const ValueKey('formulation-parameter-donut'),
        initialValue: selected,
        decoration: InputDecoration(
          labelText: AppText.t('التحليل', 'Parameter'),
          isDense: true,
        ),
        items: [
          for (final key in candidates)
            DropdownMenuItem(value: key, child: Text(_parameterName(key))),
        ],
        onChanged: (value) =>
            setState(() => _donutParameter = value ?? selected),
      ),
    );
  }

  /// A donut card: title + optional selector, a colored donut on one side and
  /// a name/percent legend beside it (the Row flips automatically in RTL).
  Widget _donutCard({
    required double width,
    required String title,
    required String subtitle,
    required List<(String, double, Color)> slices,
    required String emptyLabel,
    AppSelectField<String>? selector,
    String? centerValue,
  }) {
    final total = slices.fold<double>(0, (sum, slice) => sum + slice.$2);
    return SizedBox(
      width: width,
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textStrong,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
            if (selector != null) ...[const SizedBox(height: 6), selector],
            const SizedBox(height: 10),
            if (total <= 0)
              Text(
                emptyLabel,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              )
            else ...[
              SizedBox(
                height: 140,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        // Pure readout: touches must never steal the editor's
                        // outer list scroll gesture.
                        pieTouchData: PieTouchData(enabled: false),
                        centerSpaceRadius: 30,
                        startDegreeOffset: -90,
                        sectionsSpace: 2,
                        sections: [
                          for (final slice in slices)
                            if (slice.$2 > 0)
                              PieChartSectionData(
                                value: slice.$2,
                                color: slice.$3,
                                radius: 20,
                                showTitle: false,
                              ),
                        ],
                      ),
                    ),
                    // The chosen parameter's blended number sits in the hole,
                    // so selecting fat shows the fat figure and protein shows
                    // the protein figure.
                    if (centerValue != null)
                      Text(
                        centerValue,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textStrong,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              // Legend as a plain list under the donut — no inner scrollable
              // so it never competes with the page scroll.
              for (final slice in slices)
                if (slice.$2 > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: slice.$3,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            slice.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.spMax,
                              color: AppColors.textStrong,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(slice.$2 * 100 / total).toStringAsFixed(1)}%',
                          textDirection: TextDirection.ltr,
                          style: TextStyle(
                            fontSize: 11.spMax,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textStrong,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// Displayed series in stable palette order: (parameter key, series color).
  /// Colors come from the design-system chart palette so light/dark and the
  /// rest of the app's charts stay consistent.
  List<(String, Color)> _seriesOrder() {
    final keys = [
      for (final key in _spotsByParameter.keys)
        if (_graphParameters.contains(key)) key,
    ];
    return [
      for (var i = 0; i < keys.length; i++)
        (keys[i], AppChartPalette.forIndex(i)),
    ];
  }

  String _formatPointValue(double value) =>
      value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);

  String _fallbackName(bool after) => after
      ? AppText.t('تعويض من أقرب لاحق', 'Nearest later fallback')
      : AppText.t('تعويض من أقرب سابق', 'Nearest earlier fallback');

  Color _parameterColor(String key) {
    for (final entry in _seriesOrder()) {
      if (entry.$1 == key) return entry.$2;
    }
    return AppColors.primary;
  }

  Widget _legendPill(Color color, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.spMax,
            fontWeight: FontWeight.w600,
            color: AppColors.textStrong,
          ),
        ),
      ],
    ),
  );

  String _parameterName(String key) {
    if (FormulationCalculator.names.containsKey(key)) {
      return switch (key) {
        'protein' => AppText.t('بروتين', 'Protein'),
        'fat' => AppText.t('دهون', 'Fat'),
        'moisture' => AppText.t('رطوبة', 'Moisture'),
        _ => FormulationCalculator.names[key]!,
      };
    }
    return _parameterCatalog
            .where(
              (row) =>
                  formulationParameterKey('${row['parameter_name']}') == key,
            )
            .map((row) => '${row['parameter_name']}')
            .firstOrNull ??
        key;
  }

  Widget _kpi(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    double width = 210,
  }) => SizedBox(
    width: width,
    child: AppSummaryCard(
      label: label,
      value: value,
      icon: icon,
      color: color,
      compact: widget.fullScreen,
    ),
  );
}
