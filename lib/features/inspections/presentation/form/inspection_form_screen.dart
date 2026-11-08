import 'dart:convert' show jsonDecode;
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../di/service_locator.dart';
import '../../domain/inspection_repository.dart';
import '../cubit/inspection_form_cubit.dart';
import '../cubit/inspection_form_state.dart';
import 'mobile/inspection_form_wizard.dart';
import 'widgets/inspection_form_sections.dart';

class InspectionFormScreen extends StatefulWidget {
  final VoidCallback? onSaved;
  final bool wizard;
  final Map<String, dynamic>? inspection;

  /// Inspection kind for a *new* record (`raw` or `product`). Editing ignores
  /// this and follows `inspection['inspection_kind']` instead.
  final String kind;
  const InspectionFormScreen({
    super.key,
    this.onSaved,
    this.wizard = false,
    this.inspection,
    this.kind = 'raw',
  });
  @override
  State<InspectionFormScreen> createState() => _InspectionFormScreenState();
}

class _InspectionFormScreenState extends State<InspectionFormScreen> {
  /// True for product (batch) inspections: the header swaps supplier/vehicle
  /// for formula/batch numbers and the catalog is the product list.
  bool get _isProduct {
    final insp = widget.inspection;
    if (insp != null) return '${insp['inspection_kind'] ?? 'raw'}' == 'product';
    return widget.kind == 'product';
  }

  late final TextEditingController _date = TextEditingController(
    text: todayIso(),
  );
  final _expiry = TextEditingController();
  final _supplier = TextEditingController();
  final _truck = TextEditingController();
  final _formula = TextEditingController();
  final _batch = TextEditingController();
  final _qty = TextEditingController();
  final _sampleTaker = TextEditingController();
  final _entryCode = TextEditingController();
  final _decisionReason = TextEditingController();
  final _followUp = TextEditingController();
  final _rejectedQty = TextEditingController();
  final List<TextEditingController> _sampleNames = [TextEditingController()];
  final Map<String, List<TextEditingController>> _physical = {};
  final Map<String, List<TextEditingController>> _chemical = {};
  final _materialController = TextEditingController();
  final _materialFocus = FocusNode();
  int _renderedRefRevision = 0;
  int get _sampleCount => _sampleNames.length;

  /// True once the user has edited anything. Gates the unsaved-changes
  /// [PopScope] below so a half-typed inspection is not discarded by a
  /// back gesture or an app-bar back button.
  bool _dirty = false;

  /// Inline validation errors from the save gate, keyed by field. Rendered
  /// next to the failing field by `_FormBody` / `InspectionFormSections`
  /// (both form factors) instead of a transient toast.
  Map<String, String> _fieldErrors = const {};

  /// Set while the screen writes to a controller itself, so the auto-filled
  /// entry code and material label do not count as user edits. Listeners fire
  /// synchronously from `text=`, so this brackets them exactly.
  bool _programmaticWrite = false;

  /// Controllers with a dirty listener attached, so disposed ones can be
  /// unregistered and [initState] can seed the fixed ones once.
  final List<TextEditingController> _watched = [];

  /// Marks the form as user-edited on change.
  ///
  /// [setState] is required, not optional: `PopScope` caches `canPop` in its
  /// State, so the guard stays inert until this rebuilds.
  ///
  /// Listeners do not only fire on user gestures: a child control can sync a
  /// parent-supplied controller from its own [initState]/[didUpdateWidget]
  /// (the entity pickers do exactly that), and `didUpdateWidget`-driven writes
  /// land while the tree is still building. [setState] on this ancestor would
  /// then trip the markNeedsBuild-during-build assertion, so mid-frame
  /// triggers are deferred to after the current frame — one frame late is
  /// irrelevant for the guard, and the deferred callbacks dedupe on [_dirty].
  void _markDirty() {
    if (_programmaticWrite || _dirty || !mounted) return;
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_programmaticWrite || _dirty || !mounted) return;
        setState(() => _dirty = true);
      });
      return;
    }
    setState(() => _dirty = true);
  }

  /// Seeds the controllers from [InspectionFormScreen.inspection] for the
  /// edit flow (no dirty marking: programmatic writes are bracketed).
  /// Runs before [_watch] so replaced sample-name controllers are watched.
  void _prefillFromInspection() {
    final src = widget.inspection;
    if (src == null) return;
    _setText(_date, '${src['inspection_date'] ?? todayIso()}');
    _setText(_expiry, '${src['expiry_date'] ?? ''}');
    _setText(_supplier, '${src['supplier'] ?? ''}');
    _setText(_truck, '${src['truck_number'] ?? ''}');
    _setText(_formula, '${src['formula_number'] ?? ''}');
    _setText(_batch, '${src['batch_number'] ?? ''}');
    _setText(_qty, '${src['quantity'] ?? ''}');
    _setText(_sampleTaker, '${src['sample_taken_by'] ?? ''}');
    _setText(_entryCode, '${src['entry_code'] ?? ''}');
    _setText(_decisionReason, '${src['decision_reason'] ?? ''}');
    _setText(_followUp, '${src['follow_up_note'] ?? ''}');
    _setText(_rejectedQty, '${src['rejected_quantity'] ?? ''}');
    final names = _stringList(src['sample_names']);
    if (names.isNotEmpty) {
      for (final c in _sampleNames) {
        c.dispose();
      }
      _sampleNames
        ..clear()
        ..addAll([for (final n in names) TextEditingController(text: n)]);
    }
    _setText(
      _materialController,
      '${src['material_name'] ?? ''} (${src['material_code'] ?? ''})',
    );
    _rebuildResults(_physical, src['physical_reference'], 'physical');
    _rebuildResults(_chemical, src['chemical_reference'], 'chemical');
  }

  /// Parses the stored `sample_names` value (JSON list, separator-joined
  /// string, or inline list) into display strings.
  List<String> _stringList(Object? value) {
    if (value == null) return const [];
    if (value is List) return [for (final v in value) '$v'];
    if (value is String) {
      final t = value.trim();
      if (t.isEmpty) return const [];
      try {
        final decoded = jsonDecode(t);
        if (decoded is List) return [for (final v in decoded) '$v'];
      } catch (_) {
        // Not JSON: fall through to separator splitting.
      }
      return [
        for (final p in t.split(RegExp(r'[|،,\n]+')))
          if (p.trim().isNotEmpty) p.trim(),
      ];
    }
    return const [];
  }

  String get _formTitle => widget.inspection == null
      ? AppText.t('فحص جديد', 'New inspection')
      : AppText.t('تعديل الفحص', 'Edit inspection');

  /// Writes [value] to [c] without registering it as a user edit.
  void _setText(TextEditingController c, String value) {
    _programmaticWrite = true;
    c.text = value;
    _programmaticWrite = false;
  }

  void _watch(Iterable<TextEditingController> controllers) {
    for (final c in controllers) {
      if (_watched.contains(c)) continue;
      c.addListener(_markDirty);
      _watched.add(c);
    }
  }

  /// Detaches and forgets [c] before it is disposed, so a rebuilt results grid
  /// does not accumulate listeners on controllers it no longer owns.
  void _unwatch(TextEditingController c) {
    if (_watched.remove(c)) c.removeListener(_markDirty);
  }

  /// [_unwatch] followed by disposal, for controllers leaving the tree.
  void _dispose(TextEditingController c) {
    _unwatch(c);
    c.dispose();
  }

  void _refreshEntryCode() {
    if (!mounted || _programmaticWrite || widget.inspection != null) return;
    final date = _date.text.trim();
    final cubit = context.read<InspectionFormCubit>();
    if (cubit.state.materialId == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      return;
    }
    unawaited(cubit.regenerateEntryCode(date));
  }

  @override
  void initState() {
    super.initState();
    _prefillFromInspection();
    final initial = context.read<InspectionFormCubit>().state;
    _renderedRefRevision = initial.refRevision;
    if (widget.inspection == null) {
      _rebuildResults(_physical, initial.physicalReference, 'physical');
      _rebuildResults(_chemical, initial.chemicalReference, 'chemical');
      _setText(_entryCode, initial.entryCode);
    }
    _watch([
      _date,
      _materialController,
      _expiry,
      _supplier,
      _truck,
      _formula,
      _batch,
      _qty,
      _sampleTaker,
      _entryCode,
      _decisionReason,
      _followUp,
      _rejectedQty,
      ..._sampleNames,
      ..._physical.values.expand((l) => l),
      ..._chemical.values.expand((l) => l),
    ]);
    _date.addListener(_refreshEntryCode);
  }

  @override
  void dispose() {
    _date.removeListener(_refreshEntryCode);
    for (final c in _watched) {
      c.removeListener(_markDirty);
    }
    _watched.clear();
    _materialController.dispose();
    _materialFocus.dispose();
    for (final c in [
      ..._sampleNames,
      _date,
      _expiry,
      _supplier,
      _truck,
      _formula,
      _batch,
      _qty,
      _sampleTaker,
      _entryCode,
      _decisionReason,
      _followUp,
      _rejectedQty,
    ]) {
      c.dispose();
    }
    for (final list in _physical.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _chemical.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _selectMaterial(int id) async {
    final date = _date.text.trim().isEmpty ? todayIso() : _date.text.trim();
    final cubit = context.read<InspectionFormCubit>();
    if (_isProduct) {
      await cubit.selectProduct(id, date: date);
    } else {
      await cubit.selectMaterial(id, date: date);
    }
    if (!mounted) return;
    final st = context.read<InspectionFormCubit>().state;
    if (st.materialId == id) {
      for (final m in st.materials) {
        if ((m['id'] as num).toInt() == id) {
          _setText(
            _materialController,
            '${m['material_name']} (${m['material_code']})',
          );
          break;
        }
      }
    }
  }

  void _changeMaterial() {
    _materialController.clear();
    context.read<InspectionFormCubit>().clearMaterial();
    _materialFocus.requestFocus();
  }

  void _rebuildResults(
    Map<String, List<TextEditingController>> target,
    dynamic ref,
    String type,
  ) {
    for (final list in target.values) {
      for (final c in list) {
        _dispose(c);
      }
    }
    target.clear();
    final Map<String, dynamic> refMap = ref is Map
        ? Map<String, dynamic>.from(ref)
        : {};
    // Edit-prefill: restore the stored values for this grid. Keys the
    // reference dropped (or never had) are kept too, so saving an opened
    // record never silently discards a column the catalog no longer lists.
    final storedRaw = widget.inspection?['${type}_results'];
    final stored = storedRaw is Map ? storedRaw : const {};
    final keys = <String>{
      ...refMap.keys.map((k) => k.toString()).where((k) => k.trim().isNotEmpty),
      ...stored.keys.map((k) => k.toString()).where((k) => k.trim().isNotEmpty),
    };
    for (final key in keys) {
      final values = _storedValues(stored[key]);
      target[key] = [
        for (var i = 0; i < _sampleCount; i++)
          TextEditingController(text: i < values.length ? values[i] : ''),
      ];
    }
    _watch(target.values.expand((l) => l));
  }

  /// Normalizes a stored grid cell into per-sample display strings: a list
  /// stays positional, a scalar (single-sample records) becomes `[value]`.
  List<String> _storedValues(Object? value) {
    if (value == null) return const [];
    if (value is List) return [for (final v in value) '$v'];
    return ['$value'];
  }

  void _addSample() {
    if (_sampleCount >= 3) {
      AppFeedback.error(
        context,
        AppText.t('الحد الأقصى 3 عينات', 'A maximum of 3 samples.'),
      );
      return;
    }
    setState(() {
      final name = TextEditingController();
      _sampleNames.add(name);
      _watch([name]);
      for (final map in [_physical, _chemical]) {
        for (final entry in map.entries) {
          final c = TextEditingController();
          entry.value.add(c);
          _watch([c]);
        }
      }
    });
  }

  void _removeSample(int index) {
    if (_sampleCount <= 1) return;
    setState(() {
      _dispose(_sampleNames.removeAt(index));
      for (final map in [_physical, _chemical]) {
        for (final entry in map.entries) {
          if (index < entry.value.length) {
            _dispose(entry.value.removeAt(index));
          }
        }
      }
    });
  }

  Map<String, dynamic> _collectResults(
    Map<String, List<TextEditingController>> source,
  ) {
    final out = <String, dynamic>{};
    source.forEach((param, controllers) {
      if (_sampleCount == 1) {
        out[param] = controllers.first.text;
      } else {
        out[param] = [for (final c in controllers) c.text];
      }
    });
    return out;
  }

  Future<void> _save() async {
    final state = context.read<InspectionFormCubit>().state;
    // Inline save gate: every validation failure is rendered next to its
    // field on both form factors instead of as a transient toast.
    final errors = <String, String>{};
    if (state.materialId == null && widget.inspection == null) {
      errors['material'] = _isProduct
          ? AppText.t('يجب اختيار المنتج', 'Product selection is required.')
          : AppText.t('يجب اختيار المادة', 'Material selection is required.');
    }
    if (_isProduct) {
      if (_formula.text.trim().isEmpty) {
        errors['formula'] = AppText.t(
          'رقم الفورمولا مطلوب',
          'Formula number is required.',
        );
      }
      if (_batch.text.trim().isEmpty) {
        errors['batch'] = AppText.t(
          'رقم التشغيلة مطلوب',
          'Batch number is required.',
        );
      }
    } else {
      if (_supplier.text.trim().length < 3) {
        errors['supplier'] = AppText.t(
          'اسم المورد مطلوب (3 أحرف على الأقل)',
          'Supplier is required.',
        );
      }
      // Header-level taker is raw-only; product batches track it per sample.
      if (_sampleTaker.text.trim().length < 3) {
        errors['sampleTaker'] = AppText.t(
          'اسم آخذ العينة مطلوب (3 أحرف على الأقل)',
          'Sample taker is required.',
        );
      }
    }
    if (errors.isNotEmpty) {
      setState(() => _fieldErrors = Map.of(errors));
      return;
    }
    if (_fieldErrors.isNotEmpty) {
      setState(() => _fieldErrors = const {});
    }
    final user = getIt<AuthGate>().currentUser;
    if (user == null) {
      AppFeedback.error(context, AppText.t('انتهت الجلسة', 'Session expired.'));
      return;
    }
    final payload = <String, dynamic>{
      'inspection_kind': _isProduct ? 'product' : 'raw',
      'material_id': _isProduct ? null : state.materialId,
      'product_id': _isProduct ? state.materialId : null,
      'formula_number': _formula.text.trim(),
      'batch_number': _batch.text.trim(),
      'inspection_date': _date.text.trim(),
      'expiry_date': _expiry.text.trim(),
      if (widget.inspection != null)
        'entry_code': '${widget.inspection!['entry_code']}',
      'supplier': _supplier.text.trim(),
      'truck_number': _truck.text.trim(),
      'quantity': _qty.text.trim(),
      'sample_taken_by': _sampleTaker.text.trim(),
      'sample_names': [for (final c in _sampleNames) c.text],
      'physical_results': _collectResults(_physical),
      'chemical_results': _collectResults(_chemical),
    };
    // Products carry no header quality decision (per-sample only); the
    // repo forces the columns empty regardless of what is sent.
    if (!_isProduct) {
      payload.addAll({
        'decision_status': state.decision,
        'decision_reason': _decisionReason.text.trim(),
        'follow_up_note': _followUp.text.trim(),
        'rejected_quantity': _rejectedQty.text.trim(),
      });
    }
    final cubit = context.read<InspectionFormCubit>();
    final ok = await cubit.save(
      payload,
      UserContext(
        id: user.id,
        uid: user.uid,
        fullName: user.fullName,
        role: user.role,
      ),
    );
    if (!mounted) return;
    if (ok) {
      if (cubit.state.pendingApproval) {
        AppFeedback.show(
          context,
          AppText.t(
            'حُفظ طلب الفحص؛ سيظهر السجل بعد اعتماد السيرفر.',
            'Inspection request saved; the record will appear after server approval.',
          ),
          type: AppFeedbackType.info,
        );
      } else {
        AppFeedback.success(
          context,
          AppText.t('تم حفظ الفحص', 'Inspection saved.'),
        );
      }
      // Saved: clear the guard so this pop is not intercepted and re-confirmed.
      _dirty = false;
      final onSaved = widget.onSaved;
      if (onSaved != null) {
        onSaved();
      } else {
        Navigator.of(context).pop(true);
      }
      return;
    }
    // `save` swallowed the exception into `state.error`; without this the user
    // only ever saw a console line and no feedback at all.
    AppFeedback.errorFrom(
      context,
      cubit.state.error ??
          AppText.t('تعذر حفظ الفحص', 'Could not save the inspection.'),
      summary: AppText.t('تعذر حفظ الفحص', 'Could not save the inspection.'),
    );
  }

  /// Confirms discarding edits, then pops with [result]. Reached only when
  /// [PopScope] has already blocked a pop, i.e. the form is dirty.
  Future<void> _confirmDiscardAndPop(Object? result) async {
    final discard = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.warning_amber_rounded,
      title: AppText.t('تجاهل التعديلات؟', 'Discard your changes?'),
      message: AppText.t(
        'لديك تعديلات لم يتم حفظها. إذا خرجت الآن فستفقدها.',
        'You have unsaved changes. Leaving now will lose them.',
      ),
      confirmLabel: AppText.t('تجاهل', 'Discard'),
    );
    if (!discard || !mounted) return;
    _dirty = false;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Covers the back gesture, the app-bar back button, and the Cancel
        // button: all of them route through `Navigator.pop`, so the single
        // guard below is enough.
        _confirmDiscardAndPop(result);
      },
      child: BlocListener<InspectionFormCubit, InspectionFormState>(
        listenWhen: (prev, curr) =>
            prev.refRevision != curr.refRevision ||
            prev.entryCode != curr.entryCode,
        listener: (context, state) {
          if (state.refRevision != _renderedRefRevision) {
            _renderedRefRevision = state.refRevision;
            _rebuildResults(_physical, state.physicalReference, 'physical');
            _rebuildResults(_chemical, state.chemicalReference, 'chemical');
          }
          if (_entryCode.text != state.entryCode &&
              state.entryCode.isNotEmpty) {
            _setText(_entryCode, state.entryCode);
          }
        },
        child: _FormBody(
          wizard: widget.wizard,
          editing: widget.inspection != null,
          isProduct: _isProduct,
          title: _formTitle,
          date: _date,
          expiry: _expiry,
          supplier: _supplier,
          truck: _truck,
          formula: _formula,
          batch: _batch,
          qty: _qty,
          sampleTaker: _sampleTaker,
          entryCode: _entryCode,
          decisionReason: _decisionReason,
          followUp: _followUp,
          rejectedQty: _rejectedQty,
          sampleNames: _sampleNames,
          materialController: _materialController,
          materialFocus: _materialFocus,
          onChangeMaterial: _changeMaterial,
          physical: _physical,
          chemical: _chemical,
          sampleCount: _sampleCount,
          onSelectMaterial: _selectMaterial,
          onAddSample: _addSample,
          onRemoveSample: _removeSample,
          onSave: _save,
          fieldErrors: _fieldErrors,
        ),
      ),
    );
  }
}

class _FormBody extends StatelessWidget {
  /// True on phones: render the stepped [InspectionFormWizard] over the
  /// same controllers instead of the stacked desktop form.
  final bool wizard;
  final bool editing;

  /// Product (batch) mode: formula/batch replace supplier/vehicle.
  final bool isProduct;

  /// New vs edit title, shown by either chrome.
  final String title;
  final TextEditingController date;
  final TextEditingController expiry;
  final TextEditingController supplier;
  final TextEditingController truck;
  final TextEditingController formula;
  final TextEditingController batch;
  final TextEditingController qty;
  final TextEditingController sampleTaker;
  final TextEditingController entryCode;
  final TextEditingController decisionReason;
  final TextEditingController followUp;
  final TextEditingController rejectedQty;
  final List<TextEditingController> sampleNames;
  final TextEditingController materialController;
  final FocusNode materialFocus;
  final VoidCallback onChangeMaterial;
  final Map<String, List<TextEditingController>> physical;
  final Map<String, List<TextEditingController>> chemical;
  final int sampleCount;
  final ValueChanged<int> onSelectMaterial;
  final VoidCallback onAddSample;
  final ValueChanged<int> onRemoveSample;
  final VoidCallback onSave;
  final Map<String, String> fieldErrors;
  const _FormBody({
    this.wizard = false,
    this.editing = false,
    this.isProduct = false,
    this.title = '',
    required this.date,
    required this.expiry,
    required this.supplier,
    required this.truck,
    required this.formula,
    required this.batch,
    required this.qty,
    required this.sampleTaker,
    required this.entryCode,
    required this.decisionReason,
    required this.followUp,
    required this.rejectedQty,
    required this.sampleNames,
    required this.materialController,
    required this.materialFocus,
    required this.onChangeMaterial,
    required this.physical,
    required this.chemical,
    required this.sampleCount,
    required this.onSelectMaterial,
    required this.onAddSample,
    required this.onRemoveSample,
    required this.onSave,
    this.fieldErrors = const {},
  });
  @override
  Widget build(BuildContext context) {
    final state = context.watch<InspectionFormCubit>().state;
    final sections = InspectionFormSections(
      isProduct: isProduct,
      editing: editing,
      compact: wizard,
      date: date,
      expiry: expiry,
      supplier: supplier,
      truck: truck,
      formula: formula,
      batch: batch,
      qty: qty,
      sampleTaker: sampleTaker,
      entryCode: entryCode,
      decisionReason: decisionReason,
      followUp: followUp,
      rejectedQty: rejectedQty,
      sampleNames: sampleNames,
      materialController: materialController,
      materialFocus: materialFocus,
      onChangeMaterial: onChangeMaterial,
      physical: physical,
      chemical: chemical,
      sampleCount: sampleCount,
      onSelectMaterial: onSelectMaterial,
      onAddSample: onAddSample,
      onRemoveSample: onRemoveSample,
      fieldErrors: fieldErrors,
    );
    if (wizard) {
      return InspectionFormWizard(
        sections: sections,
        onSave: onSave,
        title: title,
      );
    }
    return AppErrorFeedback<InspectionFormCubit, InspectionFormState>(
      selector: (s) => s.error,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
            if (!state.saving && !state.loading && !state.selectingReference) {
              onSave();
            }
          },
        },
        child: Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppTopAppBar(
            title: title.isEmpty
                ? AppText.t('فحص جديد', 'New Inspection')
                : title,
          ),
          body: state.loading && state.materials.isEmpty
              ? const AppSkeletonList(rows: 8)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.page),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sections.basicCard(context),
                      if (!isProduct) ...[
                        if (physical.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.md),
                          sections.physicalCard(context),
                        ],
                        if (chemical.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.md),
                          sections.chemicalCard(context),
                        ],
                        if (sections.hasResults) ...[
                          const SizedBox(height: AppSpacing.md),
                          sections.addSampleButton(context),
                        ],
                        const SizedBox(height: AppSpacing.md),
                        sections.decisionCard(context),
                      ],
                      const SizedBox(height: AppSpacing.xl),
                      Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: AppSpacing.sm,
                        children: [
                          AppButton(
                            label: AppStrings.save,
                            icon: const Icon(Icons.check, size: 18),
                            loading: state.saving,
                            onPressed: state.saving || state.selectingReference
                                ? null
                                : onSave,
                          ),
                          AppButton(
                            style: AppButtonStyle.secondary,
                            label: AppStrings.cancel,
                            onPressed: () => Navigator.of(context).pop(false),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
