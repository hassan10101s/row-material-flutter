import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_field.dart';

/// Dialog/route title for the create/edit chrome, shared by both experiences.
String unitsEditorTitle(bool isNew) => isNew
    ? AppText.t('وحدة جديدة', 'New Unit')
    : AppText.t('تعديل الوحدة', 'Edit Unit');

/// The unit editor, shared by both experiences.
///
/// Same contract as `ConstantsEditor` and `ParamEditor`: fields and save path
/// are written once, each variant supplies only the chrome through [actions].
class UnitsEditor extends StatefulWidget {
  const UnitsEditor({
    super.key,
    required this.onSubmit,
    this.unit,
    this.actions,
  });

  /// The unit being edited, or null to create one.
  final Map<String, dynamic>? unit;

  /// Performs the save. Injected rather than read from a `BlocProvider` because
  /// the desktop variant shows this inside a dialog: `showDialog` pushes onto
  /// the **root** navigator, so the dialog is a sibling of the screen's
  /// providers rather than a descendant, and a `context.read<UnitsCubit>()`
  /// inside it would throw. The pre-split `_UnitDialog` read the cubit that
  /// way; it only ever worked because nothing exercised it.
  final Future<void> Function(String symbol, {String name, String dimension})
  onSubmit;

  /// Builds the per-experience action row, handed this widget's [State].
  final Widget Function(BuildContext context, UnitsEditorState state)? actions;

  @override
  State<UnitsEditor> createState() => UnitsEditorState();
}

class UnitsEditorState extends State<UnitsEditor> {
  late final TextEditingController _symbol = TextEditingController(
    text: '${widget.unit?['symbol'] ?? ''}',
  );
  late final TextEditingController _name = TextEditingController(
    text: '${widget.unit?['name'] ?? ''}',
  );
  late final TextEditingController _dimension = TextEditingController(
    text: '${widget.unit?['dimension'] ?? ''}',
  );
  bool _saving = false;
  String? _symbolError;

  bool get saving => _saving;

  @override
  void dispose() {
    _symbol.dispose();
    _name.dispose();
    _dimension.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final symbol = _symbol.text.trim();
    if (symbol.isEmpty) {
      setState(
        () => _symbolError = AppText.t('الرمز مطلوب', 'Symbol is required.'),
      );
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSubmit(
        symbol,
        name: _name.text.trim(),
        dimension: _dimension.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions?.call(context, this);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppField(
          label: AppText.t('الرمز', 'Symbol'),
          controller: _symbol,
          onChanged: (_) => setState(() => _symbolError = null),
          hint: 'mg/kg',
          error: _symbolError,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(label: AppText.t('الاسم', 'Name'), controller: _name),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('البعد', 'Dimension'),
          controller: _dimension,
        ),
        if (actions != null) ...[
          const SizedBox(height: AppSpacing.md),
          actions,
        ],
      ],
    );
  }
}

/// Cancel + Save, the chrome the desktop dialog shows.
class UnitsEditorActions extends StatelessWidget {
  const UnitsEditorActions({super.key, required this.state});

  final UnitsEditorState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AppButton(
          style: AppButtonStyle.secondary,
          label: AppStrings.cancel,
          onPressed: state.saving
              ? null
              : () => Navigator.of(context).pop(false),
        ),
        const SizedBox(width: AppSpacing.sm),
        AppButton(
          label: AppStrings.save,
          loading: state.saving,
          onPressed: state.saving ? null : state.submit,
        ),
      ],
    );
  }
}
