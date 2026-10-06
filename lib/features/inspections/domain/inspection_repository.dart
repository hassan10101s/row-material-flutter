// `UserContext` stays in `inspection_repo.dart` on purpose: plan P5 forbids
// changing a single line of that file, so the contract imports the value object
// from there instead of moving it. Presentation never imports `data/` directly
// (see `test/architecture/repository_boundary_test.dart`).
import '../data/inspection_repo.dart' show UserContext;

export '../data/inspection_repo.dart' show UserContext;

/// The inspection *is* the sample: one `inspections` row syncs to
/// `organizations/{orgId}/samples/{entry_code}` (plan §6.3, D7). The sample
/// repository is therefore the write side of the same table, kept as its own
/// contract so the sync layer can be reasoned about per Firestore collection.
abstract interface class SampleRepository {
  /// Creates the sample (`inspections` row) and returns the stored row.
  Future<Map<String, dynamic>> create(
    Map<String, dynamic> payload,
    UserContext user,
  );

  /// Merges `payload` into an existing sample.
  Future<Map<String, dynamic>> update(
    int inspectionId,
    Map<String, dynamic> payload,
    UserContext user,
  );

  /// Hard-deletes locally. The replication is a tombstone (`deletedAt`), so the
  /// row must still be readable right after the call - see
  /// [InspectionRepository.getById].
  Future<void> delete(int inspectionId);

  Future<List<Map<String, dynamic>>> list({
    String query = '',
    String status = '',
    int limit = 50,
    int offset = 0,
    String orderBy = 'id DESC',
  });

  Future<int> count({String query = '', String status = ''});

  Future<Map<String, dynamic>> getById(int id);
}

/// Decision log: `inspection_status_history` rows sync append-only to
/// `organizations/{orgId}/qualityChecks/{qc_<id>_<version>}` - an approved or
/// rejected decision can never be rewritten, only appended (plan §6.3).
abstract interface class QualityCheckRepository {
  /// Appends a decision and moves the sample to the new `decisionStatus`.
  Future<Map<String, dynamic>> updateStatus(
    int inspectionId,
    Map<String, dynamic> payload,
    UserContext user,
  );

  /// Append-only history, newest version first.
  Future<List<Map<String, dynamic>>> getStatusHistory(int inspectionId);
}

/// Point of separation between presentation and data (plan P5, §3).
///
/// Everything the cubits and widgets are allowed to know about persistence:
/// local SQLite first, replication through the sync queue, remote access only
/// behind the repository. No presentation file may import a `data/` file, and no
/// repository method may reach for Firebase directly - both are enforced by
/// `test/architecture/repository_boundary_test.dart`.
abstract interface class InspectionRepository {
  /// Normalizes and validates a raw form payload into the stored column set.
  Future<Map<String, dynamic>> buildBasePayload(
    Map<String, dynamic> payload,
    UserContext user,
  );

  Future<Map<String, dynamic>> create(
    Map<String, dynamic> payload,
    UserContext user,
  );

  Future<Map<String, dynamic>> update(
    int inspectionId,
    Map<String, dynamic> payload,
    UserContext user,
  );

  Future<Map<String, dynamic>> updateStatus(
    int inspectionId,
    Map<String, dynamic> payload,
    UserContext user,
  );

  Future<Map<String, dynamic>> getById(int id);

  Future<List<Map<String, dynamic>>> list({
    String query = '',
    String status = '',
    int limit = 50,
    int offset = 0,
    String orderBy = 'id DESC',
  });

  Future<int> count({String query = '', String status = ''});

  Future<List<Map<String, dynamic>>> getStatusHistory(int inspectionId);

  /// Device-local bookkeeping: the last exported PDF is *not* synced.
  Future<void> markPdfExported(int inspectionId, String pdfPath);

  Future<void> delete(int inspectionId);
}
