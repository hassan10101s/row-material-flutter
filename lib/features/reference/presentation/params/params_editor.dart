import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../domain/parameter_type.dart';

/// Dialog title for the create/edit chrome, shared by both experiences.
String paramEditorTitle(String parameterType, bool isNew) {
  if (!isNew) return AppText.t('تعديل البارامتر', 'Edit Parameter');
  return ParameterType.ofDb(parameterType).isChemical
      ? AppText.t('بارامتر كيميائي', 'Chemical Parameter')
      : AppText.t('بارامتر ظاهري', 'Physical Aspect');
}

/// The parameter editor, shared by both experiences.
///
/// Same contract as `ConstantsEditor`: the fields and the save path are written
/// once, and each variant supplies only the chrome through [actions].
class ParamEditor extends StatefulWidget {
  const ParamEditor({
    super.key,
    required this.parameterType,
    required this.onSubmit,
    this.param,
    this.unitOptions,
    this.actions,
  });

  /// 'chemical' or 'physical'; physical rows are unit-less by design.
  final String parameterType;

  /// The parameter being edited, or null to create one.
  final Map<String, dynamic>? param;

  /// Performs the save. Injected rather than read from a `BlocProvider`
  /// because the desktop variant shows this inside a dialog: `showDialog`
  /// pushes onto the **root** navigator, so the dialog is a sibling of the
  /// screen's providers rather than a descendant, and a
  /// `context.read<ParamsCubit>()` inside it would throw. The pre-split dialog
  /// read the cubit that way; it only ever worked because nothing exercised
  /// it.
  final Future<void> Function(String name, String unit) onSubmit;

  /// Known unit symbols, offered as a shortcut. Ignored for physical rows.
  final List<Map<String, dynamic>>? unitOptions;

  /// Builds the per-experience action row, handed this widget's [State].
  final Widget Function(BuildContext context, ParamEditorState state)? actions;

  @override
  State<ParamEditor> createState() => ParamEditorState();
}

class ParamEditorState extends State<ParamEditor> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.param?['parameter_name'] ?? ''}',
  );
  late final TextEditingController _unit = TextEditingController(
    text: '${widget.param?['unit'] ?? ''}',
  );
  bool _saving = false;
  String? _nameError;

  bool get saving => _saving;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    super.dispose();
  }

  List<String> get _unitOptions {
    final seen = <String>{};
    final out = <String>[];
    for (final u in widget.unitOptions ?? []) {
      final s = '${u['symbol'] ?? ''}'.trim();
      if (s.isNotEmpty && seen.add(s.toLowerCase())) out.add(s);
    }
    final current = _unit.text.trim();
    if (widget.param != null &&
        current.isNotEmpty &&
        seen.add(current.toLowerCase())) {
      out.add(current);
    }
    return out;
  }

  Future<void> submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(
        () => _nameError = AppText.t('الاسم مطلوب', 'Name is required.'),
      );
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSubmit(name, _unit.text.trim());
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
        TextField(
          controller: _name,
          onChanged: (_) => setState(() => _nameError = null),
          decoration: InputDecoration(
            labelText: AppText.t('الاسم', 'Name'),
            isDense: true,
            errorText: _nameError,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<String>(
          initialValue: _unitOptions.contains(_unit.text.trim())
              ? _unit.text.trim()
              : '',
          isExpanded: true,
          decoration: InputDecoration(
            labelText: AppText.t('الوحدة المرجعية', 'Reference unit'),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(AppText.t('بلا وحدة', 'No unit')),
            ),
            for (final unit in _unitOptions)
              DropdownMenuItem(value: unit, child: Text(unit)),
          ],
          onChanged: (value) => setState(() => _unit.text = value ?? ''),
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
class ParamEditorActions extends StatelessWidget {
  const ParamEditorActions({super.key, required this.state});

  final ParamEditorState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: state.saving
              ? null
              : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton(
          onPressed: state.saving ? null : state.submit,
          child: state.saving
              ? SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}
