@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// End-to-end check of `firestore.rules` against the Firestore + Auth
/// Emulators (plan §14-P4.2, scenarios a..i):
///
/// ```
/// firebase emulators:exec --only firestore,auth --project demo-materiallab ^
///   "flutter test test/security/firestore_rules_test.dart"
/// ```
///
/// Why raw HTTP instead of the `cloud_firestore` client: `flutter test` runs on
/// the host VM with no plugin channels, and the project ships no Windows
/// `firebase_auth`/`firebase_core` implementation, so `Firebase.initializeApp`
/// cannot work here. The emulators' REST API evaluates exactly the same rules
/// for a real user ID token, which is what this gate is about: the client is
/// untrusted, the rules decide.
///
/// Seeding uses the emulator's `Bearer owner` credential, so fixtures are
/// written *without* going through the rules; every assertion afterwards runs
/// with a signed-in user token. The suite skips itself when no emulator is
/// reachable, so a plain `flutter test` stays green on a developer machine.
const String _project = 'demo-materiallab';
const String _org = 'org_test';
const String _otherOrg = 'org_other';
const String _password = 'Passw0rd!';
const String _dbPath = 'v1/projects/$_project/databases/(default)/documents';
const String _identityPath =
    'identitytoolkit.googleapis.com/v1/projects/$_project';

void main() {
  final firestoreHost = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  final authHost = Platform.environment['FIREBASE_AUTH_EMULATOR_HOST'];
  final skip = firestoreHost == null || firestoreHost.isEmpty
      ? 'set FIRESTORE_EMULATOR_HOST (run through firebase emulators:exec)'
      : null;

  String? token;

  // ── low level helpers ──────────────────────────────────────────────────

  Map<String, dynamic> fieldValue(dynamic value) {
    if (value == null) return <String, dynamic>{'nullValue': null};
    if (value is bool) return <String, dynamic>{'booleanValue': value};
    if (value is int) return <String, dynamic>{'integerValue': '$value'};
    if (value is double) return <String, dynamic>{'doubleValue': value};
    return <String, dynamic>{'stringValue': '$value'};
  }

  Map<String, dynamic> fields(Map<String, dynamic> data) => <String, dynamic>{
    for (final entry in data.entries) entry.key: fieldValue(entry.value),
  };

  String maskFor(Map<String, dynamic> data) =>
      data.keys.map((key) => 'updateMask.fieldPaths=$key').join('&');

  /// Writes a fixture document with owner privileges (bypasses the rules).
  Future<void> seed(String path, Map<String, dynamic> data) async {
    final response = await http.patch(
      Uri.parse('http://$firestoreHost/$_dbPath/$path?${maskFor(data)}'),
      headers: <String, String>{
        'Authorization': 'Bearer owner',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{'fields': fields(data)}),
    );
    expect(
      response.statusCode,
      anyOf(200, 201),
      reason: 'seed $path failed: ${response.body}',
    );
  }

  /// Auth emulator admin call (owner privileges).
  Future<Map<String, dynamic>> authAdmin(
    String path, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) async {
    final response = await http.post(
      Uri.parse('http://$authHost/$_identityPath/$path'),
      headers: <String, String>{
        'Authorization': 'Bearer owner',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    expect(
      response.statusCode,
      anyOf(200, 201),
      reason: 'auth admin $path failed: ${response.body}',
    );
    return response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Creates an Auth emulator account and marks the e-mail verified, because the
  /// rules require `email_verified` for invitation claiming.
  Future<String> createAuthUser(String email) async {
    final created = await authAdmin('accounts', <String, dynamic>{
      'email': email,
      'password': _password,
      'emailVerified': true,
      'returnSecureToken': true,
    });
    final localId = created['localId'] as String;
    await authAdmin('accounts:update', <String, dynamic>{
      'localId': localId,
      'emailVerified': true,
    });
    return localId;
  }

  /// Signs in and remembers the ID token used for every Firestore call.
  Future<void> signInAs(String email) async {
    final response = await http.post(
      Uri.parse(
        'http://$authHost/identitytoolkit.googleapis.com/v1/'
        'accounts:signInWithPassword?key=fake-api-key',
      ),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'email': email,
        'password': _password,
        'returnSecureToken': true,
      }),
    );
    expect(
      response.statusCode,
      200,
      reason: 'sign-in failed for $email: ${response.body}',
    );
    token =
        (jsonDecode(response.body) as Map<String, dynamic>)['idToken']
            as String;
  }

  // ── Firestore calls as the signed-in user ──────────────────────────────

  Future<http.Response> userGet(String path) => http.get(
    Uri.parse('http://$firestoreHost/$_dbPath/$path'),
    headers: <String, String>{'Authorization': 'Bearer $token'},
  );

  Future<http.Response> userList(String collectionPath) => http.get(
    Uri.parse('http://$firestoreHost/$_dbPath/$collectionPath'),
    headers: <String, String>{'Authorization': 'Bearer $token'},
  );

  /// A user-facing write. The payload is the *whole* document (no update mask),
  /// which is what the emulator hands to the rules as `request.resource.data`
  ///; sending a partial mask would make the missing fields look like a delete.
  Future<http.Response> userPatch(String path, Map<String, dynamic> data) =>
      http.patch(
        Uri.parse('http://$firestoreHost/$_dbPath/$path'),
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{'fields': fields(data)}),
      );

  Future<http.Response> userDelete(String path) => http.delete(
    Uri.parse('http://$firestoreHost/$_dbPath/$path'),
    headers: <String, String>{'Authorization': 'Bearer $token'},
  );

  void expectDenied(String what, http.Response response) {
    expect(
      response.statusCode,
      403,
      reason:
          'expected $what to be DENIED, got HTTP ${response.statusCode}: '
          '${response.body}',
    );
    expect(response.body, contains('PERMISSION_DENIED'));
  }

  void expectAllowed(String what, http.Response response) {
    expect(
      response.statusCode,
      anyOf(200, 201),
      reason:
          'expected $what to be ALLOWED, got HTTP ${response.statusCode}: '
          '${response.body}',
    );
  }

  // ── fixtures ───────────────────────────────────────────────────────────

  Future<void> seedOrg(String orgId, String ownerUid) =>
      seed('organizations/$orgId', <String, dynamic>{
        'name': orgId == _org ? 'Acme' : 'Other Co',
        'ownerUid': ownerUid,
        'status': 'active',
        'schemaVersion': 2,
        'version': 1,
      });

  Future<void> seedUser(
    String uid,
    String email, {
    String org = _org,
    String role = 'admin',
    String status = 'active',
  }) => seed('users/$uid', <String, dynamic>{
    'email': email,
    'organizationId': org,
    'role': role,
    'status': status,
    'memberId': 'member_$uid',
    'version': 1,
    'updatedBy': uid,
  });

  /// A complete sync envelope, as the push worker writes it.
  Map<String, dynamic> envelope({
    required String uid,
    String org = _org,
    int version = 1,
    String? updatedBy,
    String localId = '1',
  }) => <String, dynamic>{
    'organizationId': org,
    'localId': localId,
    'version': version,
    'updatedBy': updatedBy ?? uid,
    'createdBy': uid,
    'deviceId': 'dev_test',
    'createdAt': '2026-01-01T00:00:00Z',
    'updatedAt': '2026-01-02T00:00:00Z',
    'deletedAt': null,
    'materialName': 'Cement',
  };

  /// A complete `users/{uid}` document, so a caller can change one field and
  /// still send a full document (see [userPatch]).
  Map<String, dynamic> userPayload(
    String uid,
    String email, {
    String org = _org,
    String role = 'admin',
    String status = 'active',
    int version = 1,
    String? updatedBy,
    String? memberId,
    String? inviteKey,
    String createdAt = '2026-01-01T00:00:00Z',
    String updatedAt = '2026-01-01T00:00:00Z',
  }) => <String, dynamic>{
    'email': email,
    'organizationId': org,
    'role': role,
    'status': status,
    'memberId': memberId ?? 'member_$uid',
    'version': version,
    'updatedBy': updatedBy ?? uid,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'inviteKey': ?inviteKey,
  };

  /// A complete `organizations/{orgId}/members/{memberId}` document.
  Map<String, dynamic> memberPayload(
    String memberId, {
    required String uid,
    required String email,
    String role = 'lab',
    String status = 'invited',
    int version = 1,
    String? updatedBy,
    String createdAt = '2026-01-01T00:00:00Z',
    String updatedAt = '2026-01-01T00:00:00Z',
    String? deletedAt,
  }) => <String, dynamic>{
    'uid': uid,
    'email': email,
    'role': role,
    'status': status,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'version': version,
    'updatedBy': updatedBy ?? uid,
    'deletedAt': ?deletedAt,
  };

  group('organization isolation', () {
    late String adminUid;
    late String otherUid;
    late String viewerUid;
    late String labUid;
    late String invitedUid;

    setUpAll(() async {
      if (skip != null) return;
      await seedOrg(_org, 'seed_owner');
      await seedOrg(_otherOrg, 'seed_owner_other');

      adminUid = await createAuthUser('admin@lab.test');
      otherUid = await createAuthUser('other@lab.test');
      await createAuthUser('noprofile@lab.test');
      viewerUid = await createAuthUser('viewer@lab.test');
      labUid = await createAuthUser('lab@lab.test');
      invitedUid = await createAuthUser('invited@lab.test');

      await seedUser(adminUid, 'admin@lab.test');
      await seedUser(otherUid, 'other@lab.test', org: _otherOrg);
      await seedUser(viewerUid, 'viewer@lab.test', role: 'viewer');
      await seedUser(labUid, 'lab@lab.test', role: 'lab');
      await seedUser(
        invitedUid,
        'invited@lab.test',
        role: 'lab',
        status: 'invited',
      );

      // A synced sample the readers can see.
      await seed('organizations/$_org/samples/s1', envelope(uid: adminUid));
    });

    test('(a) a user without a profile document reads nothing', () async {
      await signInAs('noprofile@lab.test');
      expectDenied(
        'list samples',
        await userList('organizations/$_org/samples'),
      );
      expectDenied('get organization', await userGet('organizations/$_org'));
    });

    test('(b) a member of another organization cannot read or write', () async {
      await signInAs('other@lab.test');
      expectDenied(
        'list samples',
        await userList('organizations/$_org/samples'),
      );
      expectDenied(
        'write into the other org',
        await userPatch(
          'organizations/$_org/samples/hack',
          envelope(uid: otherUid),
        ),
      );
    });

    test('(c) a viewer reads but never creates or updates', () async {
      await signInAs('viewer@lab.test');
      final read = await userList('organizations/$_org/samples');
      expectAllowed('viewer list samples', read);
      expect(
        (jsonDecode(read.body) as Map<String, dynamic>)['documents'],
        isNotEmpty,
      );

      expectDenied(
        'viewer create',
        await userPatch(
          'organizations/$_org/samples/s_view',
          envelope(uid: viewerUid),
        ),
      );
      expectDenied(
        'viewer update',
        await userPatch(
          'organizations/$_org/samples/s1',
          envelope(uid: viewerUid, version: 2),
        ),
      );
    });

    test('(d) an invited member can neither read nor write', () async {
      await signInAs('invited@lab.test');
      expectDenied(
        'invited list',
        await userList('organizations/$_org/samples'),
      );
      expectDenied(
        'invited create',
        await userPatch(
          'organizations/$_org/samples/s_inv',
          envelope(uid: invitedUid),
        ),
      );
    });

    test('(e) the version has to increase by exactly one', () async {
      await signInAs('admin@lab.test');
      expectDenied(
        'version + 5',
        await userPatch(
          'organizations/$_org/samples/s1',
          envelope(uid: adminUid, version: 5),
        ),
      );
      expectDenied(
        'version unchanged',
        await userPatch(
          'organizations/$_org/samples/s1',
          envelope(uid: adminUid, version: 1),
        ),
      );
      // A legal bump is accepted, which proves the rejections above came from
      // the version rule and not from a blanket deny.
      expectAllowed(
        'version + 1',
        await userPatch(
          'organizations/$_org/samples/s1',
          envelope(uid: adminUid, version: 2),
        ),
      );
    });

    test('(f) updatedBy has to be the authenticated uid', () async {
      await signInAs('admin@lab.test');
      expectDenied(
        'forged updatedBy',
        await userPatch(
          'organizations/$_org/samples/s1',
          envelope(uid: adminUid, version: 3, updatedBy: 'someone_else'),
        ),
      );
    });

    test('(g) deletes are always rejected (tombstone only)', () async {
      await signInAs('admin@lab.test');
      expectDenied(
        'delete sample',
        await userDelete('organizations/$_org/samples/s1'),
      );
    });

    test('(h) a user cannot promote their own role', () async {
      await signInAs('lab@lab.test');
      expectDenied(
        'self promotion',
        await userPatch(
          'users/$labUid',
          userPayload(
            labUid,
            'lab@lab.test',
            role: 'admin',
            version: 2,
            updatedAt: '2026-01-03T00:00:00Z',
          ),
        ),
      );
    });

    test('(i) a forged organizationId is rejected (path juggling)', () async {
      await signInAs('admin@lab.test');
      expectDenied(
        'write into org_other while active in org_test',
        await userPatch(
          'organizations/$_otherOrg/samples/s_juggle',
          envelope(uid: adminUid, org: _org),
        ),
      );
    });

    test('a lab member cannot approve a quality decision', () async {
      await signInAs('lab@lab.test');
      expectDenied(
        'qc approve by lab',
        await userPatch(
          'organizations/$_org/qualityChecks/q1',
          <String, dynamic>{...envelope(uid: labUid), 'newStatus': 'approved'},
        ),
      );
    });

    test('an admin invites, the invitee claims, the admin activates', () async {
      const newEmail = 'newcomer@lab.test';
      final newUid = await createAuthUser(newEmail);

      await signInAs('admin@lab.test');
      expectAllowed(
        'admin creates the invite',
        await userPatch('organizations/$_org/invites/inv1', <String, dynamic>{
          'email': newEmail,
          'role': 'lab',
          'memberId': 'member_newcomer',
          'status': 'invited',
          'invitedBy': adminUid,
          'invitedByName': 'Admin',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
          'version': 1,
        }),
      );
      expectAllowed(
        'admin creates the invited member',
        await userPatch(
          'organizations/$_org/members/member_newcomer',
          memberPayload(
            'member_newcomer',
            uid: '',
            email: newEmail,
            updatedBy: adminUid,
          ),
        ),
      );

      // The invitee claims: uid + version only, the status stays `invited`.
      await signInAs(newEmail);
      expectAllowed(
        'invitee claims the profile',
        await userPatch('users/$newUid', <String, dynamic>{
          ...userPayload(
            newUid,
            newEmail,
            role: 'lab',
            status: 'invited',
            memberId: 'member_newcomer',
            inviteKey: 'inv1',
            createdAt: '2026-01-02T00:00:00Z',
            updatedAt: '2026-01-02T00:00:00Z',
          ),
          'memberId': 'member_newcomer',
        }),
      );
      expectAllowed(
        'invitee claims the member document',
        await userPatch(
          'organizations/$_org/members/member_newcomer',
          memberPayload(
            'member_newcomer',
            uid: newUid,
            email: newEmail,
            version: 2,
            updatedAt: '2026-01-02T00:00:00Z',
          ),
        ),
      );

      // `invited` still means no writes at all.
      expectDenied(
        'invited write after claiming',
        await userPatch(
          'organizations/$_org/samples/s_newcomer',
          envelope(uid: newUid),
        ),
      );

      // The admin activates; now the member may read and write.
      await signInAs('admin@lab.test');
      expectAllowed(
        'admin activates the member',
        await userPatch(
          'organizations/$_org/members/member_newcomer',
          memberPayload(
            'member_newcomer',
            uid: newUid,
            email: newEmail,
            status: 'active',
            version: 3,
            updatedBy: adminUid,
            updatedAt: '2026-01-03T00:00:00Z',
          ),
        ),
      );
      expectAllowed(
        'admin activates the profile',
        await userPatch(
          'users/$newUid',
          userPayload(
            newUid,
            newEmail,
            role: 'lab',
            status: 'active',
            version: 2,
            updatedBy: adminUid,
            memberId: 'member_newcomer',
            inviteKey: 'inv1',
            createdAt: '2026-01-02T00:00:00Z',
            updatedAt: '2026-01-03T00:00:00Z',
          ),
        ),
      );

      await signInAs(newEmail);
      expectAllowed(
        'activated member reads',
        await userList('organizations/$_org/samples'),
      );
      expectAllowed(
        'activated member writes',
        await userPatch(
          'organizations/$_org/samples/s_newcomer',
          envelope(uid: newUid, localId: '2'),
        ),
      );
    });

    test('the audit log is append-only and closed to non-auditors', () async {
      await signInAs('admin@lab.test');
      expectAllowed(
        'admin writes the audit log',
        await userPatch('organizations/$_org/auditLogs/al1', <String, dynamic>{
          'userId': adminUid,
          'userName': 'Admin',
          'organizationId': _org,
          'action': 'SAMPLE_CREATED',
          'entityType': 'sample',
          'entityId': 's1',
          'detailsJson': null,
          'deviceId': 'dev_test',
          'occurredAt': '2026-01-01T00:00:00Z',
          'version': 1,
        }),
      );
      expectDenied(
        'audit delete',
        await userDelete('organizations/$_org/auditLogs/al1'),
      );
      expectDenied(
        'audit update',
        await userPatch('organizations/$_org/auditLogs/al1', <String, dynamic>{
          'action': 'TAMPERED',
        }),
      );

      // `lab` has no `audit.read`.
      await signInAs('lab@lab.test');
      expectDenied(
        'lab reads the audit log',
        await userList('organizations/$_org/auditLogs'),
      );
    });

    // ── /devices ownership ────────────────────────────────────────────────
    //
    // Regression cover for a rule that read `request.resource.data.uid` (the
    // *incoming* value) instead of `resource.data.uid` (the stored one) and
    // constrained no fields. Any member could therefore write their own uid
    // into somebody else's device document and set arbitrary fields on it.
    //
    // The allow-lists mirror what `DeviceRegistry` actually sends: `register()`
    // and the `lastSeenAt` heartbeat merge-set seven fields, `revoke()` merge-
    // sets `uid: ''` (it may act on a device it did not create) plus
    // `status`/`revokedAt`/`revokedReason`, and every write carries
    // `version: 1` — device documents are never version-bumped.
    group('device documents are owned by their member', () {
      Map<String, dynamic> devicePayload(
        String uid, {
        String email = 'lab@lab.test',
        String role = 'lab',
        String status = 'active',
      }) => <String, dynamic>{
        'uid': uid,
        'email': email,
        'displayName': 'Device',
        'platform': 'windows',
        'role': role,
        'readOnly': false,
        'lastSeenAt': '2026-01-01T00:00:00Z',
        'status': status,
        'version': 1,
      };

      /// Byte-for-byte what `DeviceRegistry.revoke()` sends for another device.
      Map<String, dynamic> revokePayload() => <String, dynamic>{
        'uid': '',
        'status': 'revoked',
        'revokedAt': '2026-02-01T00:00:00Z',
        'revokedReason': 'revoked_by_admin',
        'version': 1,
      };

      setUp(() async {
        await seed(
          'organizations/$_org/devices/dev_victim',
          devicePayload(labUid),
        );
      });

      test('a member may register their own device', () async {
        await signInAs('lab@lab.test');
        expectAllowed(
          'lab registers own device',
          await userPatch(
            'organizations/$_org/devices/dev_lab',
            devicePayload(labUid),
          ),
        );
      });

      test('a member may refresh their own device', () async {
        await signInAs('lab@lab.test');
        expectAllowed(
          'lab refreshes own device',
          await userPatch(
            'organizations/$_org/devices/dev_lab',
            devicePayload(labUid),
          ),
        );
      });

      test('a member may not rewrite another member\'s device', () async {
        await signInAs('viewer@lab.test');
        // Claims ownership by writing the *pusher's* uid into the victim's
        // document — exactly what the old rule accepted.
        expectDenied(
          'viewer overwrites another device',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            devicePayload(viewerUid),
          ),
        );
      });

      test('a member may not revoke another member\'s device', () async {
        await signInAs('viewer@lab.test');
        expectDenied(
          'viewer revokes another device',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            revokePayload(),
          ),
        );
      });

      test('a member may not inject fields into their own device', () async {
        await signInAs('lab@lab.test');
        expectDenied(
          'lab injects a field into own device',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            <String, dynamic>{...devicePayload(labUid), 'injected': 'payload'},
          ),
        );
      });

      test('an admin may refresh another device', () async {
        await signInAs('admin@lab.test');
        expectAllowed(
          'admin refreshes another device',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            devicePayload(labUid, email: 'lab@lab.test'),
          ),
        );
      });

      test('an admin may revoke another device', () async {
        // The exact payload `DeviceRegistry.revoke()` produces. It blanks the
        // uid and carries keys the create allow-list does not have, so an
        // over-tight rule silently breaks device revocation.
        await signInAs('admin@lab.test');
        expectAllowed(
          'admin revokes another device',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            revokePayload(),
          ),
        );
      });

      test('an admin may not re-assign a device to another member', () async {
        await signInAs('admin@lab.test');
        expectDenied(
          'admin re-assigns device ownership',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            devicePayload(adminUid, email: 'admin@lab.test'),
          ),
        );
      });

      test('an admin may not inject fields into a device', () async {
        await signInAs('admin@lab.test');
        expectDenied(
          'admin injects a field',
          await userPatch(
            'organizations/$_org/devices/dev_victim',
            <String, dynamic>{...devicePayload(labUid), 'injected': 'payload'},
          ),
        );
      });

      test('device documents are never deletable', () async {
        await signInAs('admin@lab.test');
        expectDenied(
          'admin deletes a device',
          await userDelete('organizations/$_org/devices/dev_victim'),
        );
      });
    });

    // ── invite confidentiality ────────────────────────────────────────────
    //
    // The invite document id is `inviteKey(email)`, derived from the e-mail, so
    // the "the e-mail equals mine" gate was not a boundary: any authenticated
    // member of the project could `get()` any org's invite and read its
    // roster-in-progress. Cross-org reads must now be refused, while the owning
    // org's admin can still resolve one by key.
    test('an invite cannot be read across organizations', () async {
      await seed(
        'organizations/$_otherOrg/invites/inv_other',
        <String, dynamic>{
          'email': 'victim@other.test',
          'role': 'admin',
          'memberId': 'member_victim',
          'status': 'invited',
          'invitedBy': 'seed_owner_other',
          'invitedByName': 'Owner',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
          'version': 1,
        },
      );
      await seed('organizations/$_org/invites/inv_own', <String, dynamic>{
        'email': 'someone@lab.test',
        'role': 'lab',
        'memberId': 'member_someone',
        'status': 'invited',
        'invitedBy': adminUid,
        'invitedByName': 'Admin',
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
        'version': 1,
      });

      await signInAs('viewer@lab.test');
      expectDenied(
        'member of org A reads org B invite',
        await userGet('organizations/$_otherOrg/invites/inv_other'),
      );

      await signInAs('admin@lab.test');
      expectAllowed(
        'admin of the owning org reads its invite',
        await userGet('organizations/$_org/invites/inv_own'),
      );
    });

    // ── inactive members read nothing ─────────────────────────────────────
    test('an invited member cannot list the device inventory', () async {
      await signInAs('invited@lab.test');
      expectDenied(
        'invited member lists devices',
        await userList('organizations/$_org/devices'),
      );
      expectDenied(
        'invited member reads the organization profile',
        await userGet('organizations/$_org'),
      );
    });

    /// A member must always be able to walk away from an organization on their
    /// own, and that exit may never double as a promotion, a version skip, or a
    /// way to tombstone somebody else's membership.
    group('self-leave', () {
      const leaverEmail = 'leaver@lab.test';
      const neighbourEmail = 'neighbour@lab.test';
      late String leaverUid;
      late String neighbourUid;

      String memberPath(String uid) =>
          'organizations/$_org/members/member_$uid';

      setUpAll(() async {
        if (skip != null) return;
        leaverUid = await createAuthUser(leaverEmail);
        neighbourUid = await createAuthUser(neighbourEmail);
      });

      /// Both documents are re-seeded before every case: leaving rewrites them, so
      /// each assertion has to start from a clean `active` / version 1 state.
      setUp(() async {
        if (skip != null) return;
        await seed(memberPath(leaverUid), <String, dynamic>{
          ...memberPayload(
            'member_$leaverUid',
            uid: leaverUid,
            email: leaverEmail,
            role: 'lab',
            status: 'active',
          ),
          // `seed` masks the fields it sends, so clear a previous tombstone.
          'deletedAt': null,
        });
        await seed(memberPath(neighbourUid), <String, dynamic>{
          ...memberPayload(
            'member_$neighbourUid',
            uid: neighbourUid,
            email: neighbourEmail,
            role: 'lab',
            status: 'active',
          ),
          'deletedAt': null,
        });
        await seedUser(leaverUid, leaverEmail, role: 'lab');
      });

      /// The exact field set the client writes when leaving.
      Map<String, dynamic> leaveMember(String uid, String email) =>
          memberPayload(
            'member_$uid',
            uid: uid,
            email: email,
            role: 'lab',
            status: 'disabled',
            version: 2,
            updatedAt: '2026-01-02T00:00:00Z',
            deletedAt: '2026-01-02T00:00:00Z',
          );

      test(
        'a member tombstones their own membership and unbinds the profile',
        () async {
          await signInAs(leaverEmail);
          expectAllowed(
            'the member disables their own membership',
            await userPatch(
              memberPath(leaverUid),
              leaveMember(leaverUid, leaverEmail),
            ),
          );
          expectAllowed(
            'the member drops the organization binding from the profile',
            await userPatch('users/$leaverUid', <String, dynamic>{
              'status': 'disabled',
              'organizationId': null,
              'version': 2,
              'updatedBy': leaverUid,
              'updatedAt': '2026-01-02T00:00:00Z',
            }),
          );
        },
      );

      test('leaving is never a promotion', () async {
        await signInAs(leaverEmail);
        expectDenied(
          'promoting the role inside the leaving update',
          await userPatch(
            memberPath(leaverUid),
            memberPayload(
              'member_$leaverUid',
              uid: leaverUid,
              email: leaverEmail,
              role: 'admin',
              status: 'disabled',
              version: 2,
              updatedAt: '2026-01-02T00:00:00Z',
              deletedAt: '2026-01-02T00:00:00Z',
            ),
          ),
        );
        expectDenied(
          'promoting the role inside the profile update',
          await userPatch('users/$leaverUid', <String, dynamic>{
            'status': 'disabled',
            'role': 'admin',
            'organizationId': null,
            'version': 2,
            'updatedBy': leaverUid,
            'updatedAt': '2026-01-02T00:00:00Z',
          }),
        );
      });

      test('a member cannot tombstone somebody else', () async {
        await signInAs(leaverEmail);
        expectDenied(
          'disabling a neighbour',
          await userPatch(
            memberPath(neighbourUid),
            leaveMember(neighbourUid, neighbourEmail),
          ),
        );
      });

      test(
        'leaving has to unbind the profile, not only disable the membership',
        () async {
          await signInAs(leaverEmail);
          expectDenied(
            'keeping organizationId while leaving',
            await userPatch('users/$leaverUid', <String, dynamic>{
              'status': 'disabled',
              'version': 2,
              'updatedBy': leaverUid,
              'updatedAt': '2026-01-02T00:00:00Z',
            }),
          );
        },
      );

      test('leaving still has to move the version by exactly one', () async {
        await signInAs(leaverEmail);
        expectDenied(
          'skipping the version',
          await userPatch(
            memberPath(leaverUid),
            memberPayload(
              'member_$leaverUid',
              uid: leaverUid,
              email: leaverEmail,
              role: 'lab',
              status: 'disabled',
              version: 3,
              updatedAt: '2026-01-02T00:00:00Z',
              deletedAt: '2026-01-02T00:00:00Z',
            ),
          ),
        );
      });

      test('leaving is not repeatable: a tombstoned row stays put', () async {
        await signInAs(leaverEmail);
        expectAllowed(
          'the first departure',
          await userPatch(
            memberPath(leaverUid),
            leaveMember(leaverUid, leaverEmail),
          ),
        );
        expectDenied(
          'a second departure',
          await userPatch(
            memberPath(leaverUid),
            leaveMember(leaverUid, leaverEmail),
          ),
        );
      });
    });
  }, skip: skip);
}
