import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class GeneralSettingsState extends Equatable {
  final bool loading;
  final bool saving;
  final String departmentLabel;
  final String logoPath;
  final String logoDataUri;

  /// Export root for report PDFs (`export_root_path`); empty means the app
  /// default exports folder is used.
  final String exportRootPath;

  const GeneralSettingsState({
    this.loading = true,
    this.saving = false,
    this.departmentLabel = 'Quality Assurance Department',
    this.logoPath = '',
    this.logoDataUri = '',
    this.exportRootPath = '',
  });

  GeneralSettingsState copyWith({
    bool? loading,
    bool? saving,
    String? departmentLabel,
    String? logoPath,
    String? logoDataUri,
    String? exportRootPath,
  }) => GeneralSettingsState(
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    departmentLabel: departmentLabel ?? this.departmentLabel,
    logoPath: logoPath ?? this.logoPath,
    logoDataUri: logoDataUri ?? this.logoDataUri,
    exportRootPath: exportRootPath ?? this.exportRootPath,
  );

  @override
  List<Object?> get props => [
    loading,
    saving,
    departmentLabel,
    logoPath,
    logoDataUri,
    exportRootPath,
  ];
}
