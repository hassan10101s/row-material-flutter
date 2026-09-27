import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import '../../sync/sync_test_fixture.dart';

/// `inspections.created_by` / `inspection_status_history.changed_by` are
/// `INTEGER NOT NULL REFERENCES users(id)`.
///
/// Since V2 the signed-in identity is a Firebase uid and `AuthGate.currentUser`
/// leaves `User.id` null, so every local write used to bind `NULL` and the save
/// died with:
/// `NOT NULL constraint failed: inspections.created_by (code 1299)`.
void main() {
  late SyncFixture fx;
  late InspectionRepo repo;

  /// The V2 shape: no local row id, only the Firebase uid.
  UserContext v2User({String? uid = 'uid_admin'}) =>
      UserContext(id: null, uid: uid, fullName: 'Hassan el sayed', role: 'admin');

  Map<String, dynamic> payload(String entryCode) => <String, dynamic>{
        'entry_code': entryCode,
        'material_id': 1,
        'inspection_date': '2026-09-27',
        'supplier': 'xcfhd',
        'truck_number': 'gx',
        'quantity': '4444',
        'sample_taken_by': 'gsdfgfgcg',
        'decision_status': 'APPROVED',
        'physical_results': <String, dynamic>{'color': 'Light gray'},
        'chemical_results': <String, dynamic>{'Moisture': '6'},
      };

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    repo = InspectionRepo(
      dbHelper: fx.helper,
      referenceRepo: ReferenceRepo(dbHelper: fx.helper),
    );
  });

  tearDown(() async => fx.dispose());

  test('create resolves created_by from the roster row matching the uid', () async {
    final row = await repo.create(payload('BTM-20260927-001'), v2User());

    expect(row['created_by'], 1, reason: 'uid_admin is mirrored as users.id 1');
    expect(row['created_by_name'], 'Hassan el sayed');
  });

  test('create falls back to the reserved "Unknown user" row, not NULL',
      () async {
    // A member who has never been pulled onto this device.
    final row = await repo.create(payload('BTM-20260927-002'), v2User(uid: 'uid_stranger'));

    final reserved = await fx.db.query('users', where: 'id = ?', whereArgs: [0], limit: 1);
    expect(reserved, isNotEmpty, reason: '_ensureUnknownUserRow must have created id 0');
    expect(row['created_by'], 0);
  });

  test('an explicit local id still wins over the uid lookup', () async {
    final row = await repo.create(
      payload('BTM-20260927-003'),
      const UserContext(id: 1, fullName: 'Hassan el sayed', role: 'admin'),
    );
    expect(row['created_by'], 1);
  });

  test('a status change writes a valid changed_by', () async {
    final created = await repo.create(payload('BTM-20260927-004'), v2User());
    final id = created['id'] as int;

    await repo.updateStatus(id, <String, dynamic>{
      'decision_status': 'FULL_REJECTION',
      'decision_reason': 'out of specification',
    }, v2User());

    final history = await fx.db.query('inspection_status_history',
        where: 'inspection_id = ?', whereArgs: [id]);
    expect(history, isNotEmpty);
    expect(history.first['changed_by'], 1);
    expect(history.first['changed_by_name'], 'Hassan el sayed');
  });
}
