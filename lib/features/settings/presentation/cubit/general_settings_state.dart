import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class GeneralSettingsState extends Equatable {
  final bool loading;
  final bool saving;
  final String departmentLabel;
  final String logoPath;
  final String logoDataUri;

  const GeneralSettingsState({
    this.loading = true,
    this.saving = false,
    this.departmentLabel = 'Quality Assurance Department',
    this.logoPath = '',
    this.logoDataUri = '',
  });

  GeneralSettingsState copyWith({
    bool? loading,
    bool? saving,
    String? departmentLabel,
    String? logoPath,
    String? logoDataUri,
  }) =>
      GeneralSettingsState(
        loading: loading ?? this.loading,
        saving: saving ?? this.saving,
        departmentLabel: departmentLabel ?? this.departmentLabel,
        logoPath: logoPath ?? this.logoPath,
        logoDataUri: logoDataUri ?? this.logoDataUri,
      );

  @override
  List<Object?> get props =>
      [loading, saving, departmentLabel, logoPath, logoDataUri];
}