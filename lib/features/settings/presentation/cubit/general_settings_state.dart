import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class GeneralSettingsState extends Equatable {
  final bool loading;
  final bool saving;
  final String departmentLabel;

  const GeneralSettingsState({
    this.loading = true,
    this.saving = false,
    this.departmentLabel = 'Quality Assurance Department',
  });

  GeneralSettingsState copyWith({
    bool? loading,
    bool? saving,
    String? departmentLabel,
  }) =>
      GeneralSettingsState(
        loading: loading ?? this.loading,
        saving: saving ?? this.saving,
        departmentLabel: departmentLabel ?? this.departmentLabel,
      );

  @override
  List<Object?> get props => [loading, saving, departmentLabel];
}