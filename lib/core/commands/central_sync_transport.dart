import 'central_projection.dart';

class CentralSyncGap implements Exception {
  const CentralSyncGap();
}

class CentralReadBoundary {
  const CentralReadBoundary({
    required this.sequence,
    required this.readTime,
    required this.manifestVersion,
    this.privacyEpoch = 0,
  });
  final int sequence;
  final String readTime;
  final int manifestVersion;
  final int privacyEpoch;
}

class CentralRecordPage {
  const CentralRecordPage(this.records, this.nextAfter);
  final List<ApprovedRecord> records;
  final String? nextAfter;
}

class CentralChangeSet {
  const CentralChangeSet({required this.records, required this.operationIds});
  final List<ApprovedRecord> records;
  final Set<String> operationIds;
}

/// Production reader: one immutable server read boundary for a complete cycle.
abstract interface class ConsistentCentralSyncReader
    implements CentralSyncReader {
  Future<CentralReadBoundary> readHead();
  Future<CentralRecordPage> readSnapshotPage(
    String entityType,
    CentralReadBoundary boundary, {
    String? after,
  });
  Future<CentralChangeSet> readChanges(
    int afterSequence,
    CentralReadBoundary boundary,
  );
}

/// Compatibility feed contract for local contract tests. The installed
/// production reader uses the typed consistent Firestore interface above.
abstract interface class CentralSyncReader {
  Future<Map<String, dynamic>> call(Map<String, Object?> data);
}

/// Fail closed while a direct backend is not yet installed. This performs no
/// remote calls and cannot report a successful bootstrap or download.
class UnconfiguredCentralSyncReader implements CentralSyncReader {
  const UnconfiguredCentralSyncReader();

  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> data) async {
    throw StateError('المزامنة المباشرة غير مهيأة على هذا الجهاز.');
  }
}
