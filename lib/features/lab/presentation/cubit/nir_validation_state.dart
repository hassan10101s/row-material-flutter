import 'package:equatable/equatable.dart';

import '../../../../core/constants/app_strings.dart';
import '../../domain/nir_validation_repository.dart';

class NirValidationState extends Equatable {
  const NirValidationState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.settings,
    this.stats = const [],
    this.scopeFilter,
    this.query = '',
    this.resetHistory = const [],
  });

  final bool loading;
  final bool saving;
  final String? error;
  final NirValidationSettings? settings;
  final List<NirParameterStats> stats;

  /// Null = both scopes (خامات + منتجات).
  final NirScope? scopeFilter;
  final String query;
  final List<NirValidationSettings> resetHistory;

  List<NirParameterStats> get filteredStats {
    final q = query.trim().toLowerCase();
    return stats.where((s) {
      if (scopeFilter != null && s.scope != scopeFilter) return false;
      if (q.isEmpty) return true;
      return '${s.entityName} ${s.parameter}'.toLowerCase().contains(q);
    }).toList();
  }

  static String scopeLabel(NirScope scope) =>
      scope == NirScope.rawMaterial
          ? AppText.t('خامة', 'Raw material')
          : AppText.t('منتج', 'Product');

  NirValidationState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    bool clearError = false,
    NirValidationSettings? settings,
    List<NirParameterStats>? stats,
    NirScope? scopeFilter,
    bool clearScope = false,
    String? query,
    List<NirValidationSettings>? resetHistory,
  }) =>
      NirValidationState(
        loading: loading ?? this.loading,
        saving: saving ?? this.saving,
        error: clearError ? null : (error ?? this.error),
        settings: settings ?? this.settings,
        stats: stats ?? this.stats,
        scopeFilter: clearScope ? null : (scopeFilter ?? this.scopeFilter),
        query: query ?? this.query,
        resetHistory: resetHistory ?? this.resetHistory,
      );

  @override
  List<Object?> get props => [
        loading,
        saving,
        error,
        settings,
        stats,
        scopeFilter,
        query,
        resetHistory,
      ];
}
