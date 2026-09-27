import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class DatabaseSettingsState extends Equatable {
  final bool busy;
  final String? error;
  final String? lastPath;

  /// A restore happened and the sync state was reconciled (plan §14-P11.2).
  final bool restored;

  /// Queue entries whose local row was missing from the restored file; they were
  /// surfaced as conflicts instead of being dropped.
  final int restoreConflicts;

  /// Rows put back into `queued` so their change still reaches the server.
  final int restoreRequeued;

  const DatabaseSettingsState({
    this.busy = false,
    this.error,
    this.lastPath,
    this.restored = false,
    this.restoreConflicts = 0,
    this.restoreRequeued = 0,
  });

  DatabaseSettingsState copyWith({
    bool? busy,
    String? error,
    String? lastPath,
    bool? restored,
    int? restoreConflicts,
    int? restoreRequeued,
  }) =>
      DatabaseSettingsState(
        busy: busy ?? this.busy,
        error: error ?? this.error,
        lastPath: lastPath ?? this.lastPath,
        restored: restored ?? this.restored,
        restoreConflicts: restoreConflicts ?? this.restoreConflicts,
        restoreRequeued: restoreRequeued ?? this.restoreRequeued,
      );

  @override
  List<Object?> get props =>
      [busy, error, lastPath, restored, restoreConflicts, restoreRequeued];
}
