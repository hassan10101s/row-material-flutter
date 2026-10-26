@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_lab/core/sync/remote_write_policy.dart';
import 'package:material_lab/core/sync/sync_codec.dart';

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
    if (value == SyncCodec.serverTimestampPlaceholder) {
      value = DateTime.now().toUtc();
    }
    if (value is DateTime) {
      return {'timestampValue': value.toUtc().toIso8601String()};
    }
    if (value == null) return <String, dynamic>{'nullValue': null};
    if (value is Map) {
      return {
        'mapValue': {
          'fields': {
            for (final entry in value.entries)
              '${entry.key}': fieldValue(entry.value),
          },
        },
      };
    }
    if (value is List) {
      return {
        'arrayValue': {'values': value.map(fieldValue).toList()},
      };
    }
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

  Future<http.Response> userCommit(
    Map<String, Map<String, dynamic>> documents,
  ) => http.post(
    Uri.parse(
      'http://$firestoreHost/v1/projects/$_project/databases/(default)/documents:commit',
    ),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'writes': [
        for (final entry in documents.entries)
          {
            'update': {
              'name':
                  'projects/$_project/databases/(default)/documents/${entry.key}',
              'fields': fields(entry.value),
            },
          },
      ],
    }),
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
  }) async {
    await seed('users/$uid', <String, dynamic>{
      'email': email,
      'organizationId': org,
      'role': role,
      'status': status,
      'memberId': 'member_$uid',
      'version': 1,
      'updatedBy': uid,
    });
    await seed('organizations/$org/devices/dev_$uid', {
      'uid': uid,
      'status': 'active',
      'readOnly': role == 'viewer',
      'version': 1,
    });
  }

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
    'deviceId': 'dev_$uid',
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

    test(
      'central cutover blocks legacy clinical writes while keeping reads',
      () async {
        await signInAs('admin@lab.test');
        await seed('organizations/$_org', {
          'commandProtocol': {'enabled': true},
        });
        try {
          expectDenied(
            'legacy create during central cutover',
            await userPatch(
              'organizations/$_org/samples/forbidden-legacy',
              envelope(uid: adminUid),
            ),
          );
          expectDenied(
            'legacy update during central cutover',
            await userPatch(
              'organizations/$_org/samples/s1',
              envelope(uid: adminUid, version: 2),
            ),
          );
          expectAllowed(
            'read remains available',
            await userGet('organizations/$_org/samples/s1'),
          );
        } finally {
          final response = await http.patch(
            Uri.parse(
              'http://$firestoreHost/$_dbPath/organizations/$_org?updateMask.fieldPaths=commandProtocol',
            ),
            headers: {
              'Authorization': 'Bearer owner',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'fields': {}}),
          );
          expect(response.statusCode, 200);
        }
      },
      skip: skip,
    );

    test(
      'pilot feed never exposes unsupported entity types to members',
      () async {
        await seed('organizations/$_org/changeEvents/pilot-sample', {
          'entityType': 'sample',
        });
        await seed('organizations/$_org/changeEvents/future-qc', {
          'entityType': 'qcInspection',
        });
        await signInAs('lab@lab.test');
        expectAllowed(
          'permitted sample event',
          await userGet('organizations/$_org/changeEvents/pilot-sample'),
        );
        expectDenied(
          'unsupported quality event',
          await userGet('organizations/$_org/changeEvents/future-qc'),
        );
        expectDenied(
          'client receipt forgery',
          await userPatch('organizations/$_org/commandReceipts/forged', {
            'uid': labUid,
          }),
        );
      },
      skip: skip,
    );

    test(
      'transport preserves identity and restores missing acknowledged rows',
      () async {
        await signInAs('admin@lab.test');
        final original = envelope(uid: adminUid);
        final path = 'organizations/$_org/samples/transport';
        expectAllowed('create original', await userPatch(path, original));
        final incoming = {
          ...original,
          'localId': '900',
          'createdBy': 'other',
          'materialName': 'Changed',
        };
        final plan = RemoteWritePolicy.plan(
          organizationId: _org,
          data: incoming,
          baseVersion: 1,
          current: original,
        );
        expect(plan.refusal, isNull);
        expectAllowed(
          'preserve original identity',
          await userPatch(path, {...original, ...plan.payload}),
        );
        final restored = RemoteWritePolicy.plan(
          organizationId: _org,
          data: incoming..remove('createdAt'),
          baseVersion: 9,
        );
        expect(restored.version, 1);
        expectAllowed(
          'recreate missing v1',
          await userPatch(
            'organizations/$_org/samples/transport-restored',
            restored.payload,
          ),
        );
      },
      skip: skip,
    );

    test(
      'server never resurrects a tombstone through a normal update',
      () async {
        await signInAs('admin@lab.test');
        final path = 'organizations/$_org/samples/no-resurrection';
        final original = envelope(uid: adminUid);
        expectAllowed('create', await userPatch(path, original));
        expectAllowed(
          'tombstone',
          await userPatch(path, {
            ...original,
            'version': 2,
            'deletedAt': '2026-10-24T00:00:00Z',
          }),
        );
        expectDenied(
          'resurrect',
          await userPatch(path, {...original, 'version': 3}),
        );
      },
      skip: skip,
    );

    test('server denies read-only revoked and foreign devices', () async {
      await signInAs('admin@lab.test');
      final device = 'organizations/$_org/devices/dev_$adminUid';
      try {
        for (final state in [
          {'uid': adminUid, 'status': 'active', 'readOnly': true},
          {'uid': adminUid, 'status': 'revoked', 'readOnly': false},
          {'uid': labUid, 'status': 'active', 'readOnly': false},
        ]) {
          await seed(device, state);
          expectDenied(
            'restricted device write',
            await userPatch(
              'organizations/$_org/samples/restricted-device',
              envelope(uid: adminUid),
            ),
          );
        }
      } finally {
        await seed(device, {
          'uid': adminUid,
          'status': 'active',
          'readOnly': false,
        });
      }
    }, skip: skip);

    test(
      'a member cannot remove its own device read-only restriction',
      () async {
        await signInAs('lab@lab.test');
        final path = 'organizations/$_org/devices/dev_$labUid';
        final device = {
          'uid': labUid,
          'status': 'active',
          'version': 1,
          'readOnly': true,
        };
        await seed(path, device);
        try {
          expectDenied(
            'self enable writes',
            await userPatch(path, {...device, 'readOnly': false}),
          );
        } finally {
          await seed(path, {...device, 'readOnly': false});
        }
      },
      skip: skip,
    );

    test(
      'append receipts are private immutable and contain no business fields',
      () async {
        await signInAs('lab@lab.test');
        final path =
            'organizations/$_org/syncReceipts/$labUid/entries/${'a' * 64}';
        expect((await userGet(path)).statusCode, 404);
        final receipt = {
          'fingerprint': 'b' * 64,
          'deviceId': 'dev_$labUid',
          'collectionId': 'auditLogs',
          'documentId': 'audit-transport',
          'version': 1,
          'createdAt': DateTime.now().toUtc(),
        };
        expectAllowed('create own receipt', await userPatch(path, receipt));
        expectAllowed('read own receipt', await userGet(path));
        expectDenied('mutate receipt', await userPatch(path, receipt));
        expectDenied(
          'business values in receipt',
          await userPatch(
            'organizations/$_org/syncReceipts/$labUid/entries/${'c' * 64}',
            {...receipt, 'chemicalResultsJson': '{}'},
          ),
        );
        await signInAs('admin@lab.test');
        expectDenied('read another member receipt', await userGet(path));
        await signInAs('other@lab.test');
        expectDenied('cross organization receipt', await userGet(path));
      },
      skip: skip,
    );

    test(
      'lab atomically commits an audit and its receipt without audit read access',
      () async {
        await signInAs('lab@lab.test');
        final auditPath = 'organizations/$_org/auditLogs/receipt-atomic-audit';
        final receiptPath =
            'organizations/$_org/syncReceipts/$labUid/entries/${'d' * 64}';
        expectDenied('lab audit read', await userGet(auditPath));
        final response = await http.post(
          Uri.parse('http://$firestoreHost/$_dbPath:commit'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'writes': [
              {
                'update': {
                  'name':
                      'projects/$_project/databases/(default)/documents/$auditPath',
                  'fields': fields({
                    'organizationId': _org,
                    'userId': labUid,
                    'userName': 'Lab',
                    'deviceId': 'dev_$labUid',
                    'action': 'CUSTOM_ROW_RECORDED',
                    'entityType': 'qcCustomRow',
                    'entityId': 'row',
                    'detailsJson': '{}',
                    'occurredAt': '2026-10-24',
                    'version': 1,
                  }),
                },
              },
              {
                'update': {
                  'name':
                      'projects/$_project/databases/(default)/documents/$receiptPath',
                  'fields': fields({
                    'fingerprint': 'e' * 64,
                    'deviceId': 'dev_$labUid',
                    'collectionId': 'auditLogs',
                    'documentId': 'receipt-atomic-audit',
                    'version': 1,
                    'createdAt': DateTime.now().toUtc(),
                  }),
                },
              },
            ],
          }),
        );
        expectAllowed('atomic append plus receipt', response);
        expectAllowed('retry reads receipt', await userGet(receiptPath));
        expectDenied('audit remains private', await userGet(auditPath));
      },
      skip: skip,
    );

    test(
      'shared program records obey organization, viewer and writer permissions',
      () async {
        for (final collection in [
          'parameters',
          'materialBounds',
          'organizationSettings',
          'qcSops',
          'qcSopRevisions',
          'qcSopReads',
        ]) {
          final data = <String, dynamic>{
            ...envelope(uid: adminUid),
            if (collection == 'organizationSettings') ...{
              'key': 'department_label',
              'value': 'QA',
            },
            if (collection == 'qcSops') 'status': 'Draft',
          };
          final path = 'organizations/$_org/$collection/shared-test';
          await signInAs('admin@lab.test');
          expectAllowed(
            'writer creates $collection',
            await userPatch(path, data),
          );
          await signInAs('viewer@lab.test');
          expectAllowed('viewer reads $collection', await userGet(path));
          expectDenied(
            'viewer cannot change $collection',
            await userPatch(path, {
              ...data,
              'version': 2,
              'updatedBy': viewerUid,
            }),
          );
          await signInAs('other@lab.test');
          expectDenied(
            'other organization cannot read $collection',
            await userGet(path),
          );
        }
        await signInAs('admin@lab.test');
        expectDenied(
          'local file paths cannot become organization settings',
          await userPatch(
            'organizations/$_org/organizationSettings/local-path',
            {
              ...envelope(uid: adminUid),
              'key': 'export_root_path',
              'value': 'C:/private',
            },
          ),
        );
      },
    );

    test('private push tokens bind only to an active owned device', () async {
      const device = 'viewer-push-phone';
      await seed('organizations/$_org/devices/$device', {
        'uid': viewerUid,
        'status': 'active',
        'version': 1,
      });
      final tokenPath = 'organizations/$_org/pushTokens/test-viewer-token';
      final data = <String, dynamic>{
        'uid': viewerUid,
        'deviceId': device,
        'token': 'synthetic-test-token',
        'platform': 'android',
        'updatedAt': '2026-10-24T00:00:00Z',
      };
      await signInAs('viewer@lab.test');
      expectAllowed(
        'read-only viewer registers own delivery token',
        await userPatch(tokenPath, data),
      );
      expectDenied(
        'tokens are never readable in the client',
        await userGet(tokenPath),
      );
      expectDenied(
        'another device cannot be impersonated',
        await userPatch('organizations/$_org/pushTokens/forged-device', {
          ...data,
          'deviceId': 'unregistered',
        }),
      );
      expectDenied(
        'another organization cannot receive this token',
        await userPatch('organizations/$_otherOrg/pushTokens/cross-org', data),
      );
      await signInAs('lab@lab.test');
      expectDenied(
        'another member cannot take over a token',
        await userPatch(tokenPath, {...data, 'uid': labUid}),
      );
      await seed('organizations/$_org/devices/$device', {'status': 'revoked'});
      await signInAs('viewer@lab.test');
      expectDenied(
        'revoked device cannot refresh its token',
        await userPatch(tokenPath, data),
      );
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

      // The invitee claims: binds the uid, the status moves invited →
      // `pending_activation` (waiting for manager activation).
      await signInAs(newEmail);
      expectAllowed(
        'invitee claims the profile',
        await userPatch('users/$newUid', <String, dynamic>{
          ...userPayload(
            newUid,
            newEmail,
            role: 'lab',
            status: 'pending_activation',
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
            status: 'pending_activation',
            version: 2,
            updatedAt: '2026-01-02T00:00:00Z',
          ),
        ),
      );

      // `pending_activation` still means no reads and no writes at all.
      expectDenied(
        'pending write after claiming',
        await userPatch(
          'organizations/$_org/samples/s_newcomer',
          envelope(uid: newUid),
        ),
      );
      expectDenied(
        'pending list after claiming',
        await userList('organizations/$_org/samples'),
      );

      // The invitee cannot activate itself.
      expectDenied(
        'self activation via the profile',
        await userPatch(
          'users/$newUid',
          userPayload(
            newUid,
            newEmail,
            role: 'lab',
            status: 'active',
            version: 2,
            updatedBy: newUid,
            memberId: 'member_newcomer',
            inviteKey: 'inv1',
            createdAt: '2026-01-02T00:00:00Z',
            updatedAt: '2026-01-02T00:00:00Z',
          ),
        ),
      );
      expectDenied(
        'self activation via the member document',
        await userPatch(
          'organizations/$_org/members/member_newcomer',
          memberPayload(
            'member_newcomer',
            uid: newUid,
            email: newEmail,
            status: 'active',
            version: 3,
            updatedBy: newUid,
            updatedAt: '2026-01-02T00:00:00Z',
          ),
        ),
      );

      // Both authorization copies must change atomically.
      await signInAs('admin@lab.test');
      final activeMember = <String, dynamic>{
        ...memberPayload(
          'member_newcomer',
          uid: newUid,
          email: newEmail,
          status: 'active',
          version: 3,
          updatedBy: adminUid,
          updatedAt: '2026-01-03T00:00:00Z',
        ),
        'activatedAt': '2026-01-03T00:00:00Z',
        'activatedBy': adminUid,
      };
      final activeProfile = <String, dynamic>{
        ...userPayload(
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
        'activatedAt': '2026-01-03T00:00:00Z',
        'activatedBy': adminUid,
      };
      expectDenied(
        'activation cannot leave the profile stale',
        await userPatch(
          'organizations/$_org/members/member_newcomer',
          activeMember,
        ),
      );
      expectAllowed(
        'admin activates both copies together',
        await userCommit({
          'organizations/$_org/members/member_newcomer': activeMember,
          'users/$newUid': activeProfile,
        }),
      );

      await signInAs(newEmail);
      expectAllowed(
        'activated member reads',
        await userList('organizations/$_org/samples'),
      );
      expectAllowed(
        'activated member enrolls its device',
        await userPatch('organizations/$_org/devices/dev_$newUid', {
          'uid': newUid,
          'role': 'lab',
          'readOnly': false,
          'status': 'active',
          'version': 1,
        }),
      );
      expectAllowed(
        'activated member writes',
        await userPatch(
          'organizations/$_org/samples/s_newcomer',
          envelope(uid: newUid, localId: '2'),
        ),
      );
    });

    test(
      'multi-role grants and role changes cannot bypass the profile mirror',
      () async {
        final uid = await createAuthUser('multirole@lab.test');
        final memberId = 'member_$uid';
        final profile = userPayload(uid, 'multirole@lab.test', role: 'lab');
        final member = memberPayload(
          memberId,
          uid: uid,
          email: 'multirole@lab.test',
          role: 'lab',
          status: 'active',
        );
        await seed('users/$uid', {
          ...profile,
          'roles': ['lab', 'nutritionist'],
        });
        await seed('organizations/$_org/members/$memberId', {
          ...member,
          'roles': ['lab', 'nutritionist'],
        });
        await seed('organizations/$_org/devices/dev_$uid', {
          'uid': uid,
          'status': 'active',
          'readOnly': false,
          'role': 'lab',
          'version': 1,
        });
        await signInAs('multirole@lab.test');
        expectAllowed(
          'primary role creates sample',
          await userPatch(
            'organizations/$_org/samples/multi-sample',
            envelope(uid: uid),
          ),
        );
        expectAllowed(
          'secondary role creates formulation',
          await userPatch('organizations/$_org/labConfig/nf_multi-formula', {
            ...envelope(uid: uid),
            'configType': 'nutrition_formulation',
          }),
        );
        expectDenied(
          'cannot add own manager role',
          await userPatch('users/$uid', {
            ...profile,
            'roles': ['lab', 'quality_manager', 'nutritionist'],
            'version': 2,
          }),
        );
        await signInAs('admin@lab.test');
        final revisedProfile = {
          ...profile,
          'roles': ['lab'],
          'version': 2,
          'updatedBy': adminUid,
        };
        final revisedMember = {
          ...member,
          'roles': ['lab'],
          'version': 2,
          'updatedBy': adminUid,
        };
        expectDenied(
          'one-sided role change',
          await userPatch('users/$uid', revisedProfile),
        );
        expectAllowed(
          'atomic role change',
          await userCommit({
            'users/$uid': revisedProfile,
            'organizations/$_org/members/$memberId': revisedMember,
          }),
        );
        await signInAs('multirole@lab.test');
        expectDenied(
          'removed secondary role stops writes',
          await userPatch('organizations/$_org/labConfig/nf_multi-removed', {
            ...envelope(uid: uid),
            'configType': 'nutrition_formulation',
          }),
        );
        for (final roles in [
          <String>[],
          ['lab', 'viewer'],
          ['lab', 'unknown'],
          ['lab', 'lab'],
        ]) {
          await seed('users/$uid', {'roles': roles});
          expectDenied(
            'malformed roles fail closed',
            await userPatch(
              'organizations/$_org/samples/multi-invalid',
              envelope(uid: uid),
            ),
          );
        }
        await seed('users/$uid', {
          'roles': ['lab'],
        });
        await signInAs('admin@lab.test');
        final disabledProfile =
            <String, dynamic>{
                ...revisedProfile,
                'status': 'disabled',
                'version': 3,
              }
              ..remove('organizationId')
              ..remove('memberId');
        expectAllowed(
          'manager disables both copies and releases the binding',
          await userCommit({
            'users/$uid': disabledProfile,
            'organizations/$_org/members/$memberId': {
              ...revisedMember,
              'status': 'disabled',
              'version': 3,
            },
          }),
        );
        await signInAs('multirole@lab.test');
        expectDenied(
          'disabled employee cannot read the company',
          await userGet('organizations/$_org/samples/multi-sample'),
        );
      },
    );

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
          'deviceId': 'dev_$adminUid',
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

    /// Single-company policy: a bound account cannot create a second company,
    /// while an unbound account may create exactly one trial company.
    group('single-company policy', () {
      test('a bound account cannot create a second company', () async {
        await signInAs('admin@lab.test');
        expectDenied(
          'active member creates a second organization',
          await userPatch('organizations/org_second', <String, dynamic>{
            'name': 'Second Co',
            'ownerUid': adminUid,
            'status': 'trial',
            'schemaVersion': 2,
            'version': 1,
            'trialStartedAt': '2026-01-01T00:00:00Z',
            'trialEndsAt': '2026-01-31T00:00:00Z',
            'trialConsumed': false,
            'manuallyActivated': false,
          }),
        );
      });

      test(
        'an unbound account creates a trial company as trial_owner',
        () async {
          const email = 'founder@trial.test';
          final uid = await createAuthUser(email);
          await signInAs(email);
          expectAllowed(
            'unbound account creates a trial organization',
            await userPatch('organizations/org_trial_new', <String, dynamic>{
              'name': 'Trial Co',
              'ownerUid': uid,
              'status': 'trial',
              'schemaVersion': 2,
              'version': 1,
              'trialStartedAt': '2026-01-01T00:00:00Z',
              'trialEndsAt': '2026-01-31T00:00:00Z',
              'trialConsumed': false,
              'manuallyActivated': false,
            }),
          );
          expectAllowed(
            'founder claims the trial_owner profile',
            await userPatch('users/$uid', <String, dynamic>{
              ...userPayload(
                uid,
                email,
                org: 'org_trial_new',
                role: 'trial_owner',
                status: 'active',
                memberId: 'member_trial',
                createdAt: '2026-01-02T00:00:00Z',
                updatedAt: '2026-01-02T00:00:00Z',
              ),
              'memberId': 'member_trial',
            }),
          );
          expectAllowed(
            'founder writes the trial_owner member document',
            await userPatch(
              'organizations/org_trial_new/members/member_trial',
              memberPayload(
                'member_trial',
                uid: uid,
                email: email,
                role: 'trial_owner',
                status: 'active',
                version: 1,
                updatedBy: uid,
              ),
            ),
          );
          // Bound now: a second company is refused.
          expectDenied(
            'trial owner creates a second organization',
            await userPatch('organizations/org_trial_second', <String, dynamic>{
              'name': 'Second Co',
              'ownerUid': uid,
              'status': 'trial',
              'schemaVersion': 2,
              'version': 1,
              'trialStartedAt': '2026-01-01T00:00:00Z',
              'trialEndsAt': '2026-01-31T00:00:00Z',
              'trialConsumed': false,
              'manuallyActivated': false,
            }),
          );
        },
      );

      test('org creation without trial fields is rejected', () async {
        const email = 'nodates@trial.test';
        final uid = await createAuthUser(email);
        await signInAs(email);
        expectDenied(
          'trial organization without trialConsumed/manuallyActivated',
          await userPatch('organizations/org_trial_nodates', <String, dynamic>{
            'name': 'No Dates Co',
            'ownerUid': uid,
            'status': 'trial',
            'schemaVersion': 2,
            'version': 1,
          }),
        );
      });

      test(
        'org creation with status active is rejected (trial only)',
        () async {
          const email = 'activebypass@trial.test';
          final uid = await createAuthUser(email);
          await signInAs(email);
          expectDenied(
            'organization created directly as active',
            await userPatch(
              'organizations/org_trial_activebypass',
              <String, dynamic>{
                'name': 'Bypass Co',
                'ownerUid': uid,
                'status': 'active',
                'schemaVersion': 2,
                'version': 1,
                'trialStartedAt': '2026-01-01T00:00:00Z',
                'trialEndsAt': '2026-01-31T00:00:00Z',
                'trialConsumed': false,
                'manuallyActivated': false,
              },
            ),
          );
        },
      );
    });

    /// Trial lifecycle pinning: no client may change `status`,
    /// `trialStartedAt`, `trialEndsAt`, `trialConsumed` or `manuallyActivated`.
    /// `trial` → `suspended` (server cron) and `suspended` → `active` (manual
    /// activation by support) run through the Admin SDK, which bypasses rules.
    group('trial lifecycle', () {
      test('a trial org cannot be flipped to active from the client', () async {
        await seed('organizations/org_trial_flip', <String, dynamic>{
          'name': 'Flip Co',
          'ownerUid': adminUid,
          'status': 'trial',
          'schemaVersion': 2,
          'version': 1,
          'trialStartedAt': '2026-01-01T00:00:00Z',
          'trialEndsAt': '2026-01-31T00:00:00Z',
          'trialConsumed': false,
          'manuallyActivated': false,
        });
        await signInAs('admin@lab.test');
        expectDenied(
          'trial org promoted to active',
          await userPatch('organizations/org_trial_flip', <String, dynamic>{
            'name': 'Flip Co',
            'ownerUid': adminUid,
            'status': 'active',
            'schemaVersion': 2,
            'version': 1,
            'trialStartedAt': '2026-01-01T00:00:00Z',
            'trialEndsAt': '2026-01-31T00:00:00Z',
            'trialConsumed': true,
            'manuallyActivated': true,
          }),
        );
      });

      test('an admin cannot touch trialConsumed/manuallyActivated', () async {
        await signInAs('admin@lab.test');
        expectDenied(
          'admin forges trial flags',
          await userPatch('organizations/$_org', <String, dynamic>{
            'name': 'Acme',
            'ownerUid': 'seed_owner',
            'status': 'active',
            'schemaVersion': 2,
            'version': 1,
            'trialConsumed': true,
            'manuallyActivated': true,
          }),
        );
      });

      test('an admin can still rename the organization', () async {
        await signInAs('admin@lab.test');
        expectAllowed(
          'admin renames the org',
          await userPatch('organizations/$_org', <String, dynamic>{
            'name': 'Acme Renamed',
            'ownerUid': 'seed_owner',
            'status': 'active',
            'schemaVersion': 2,
            'version': 1,
          }),
        );
        // Restore the fixture name for the other groups.
        await seed('organizations/$_org', <String, dynamic>{'name': 'Acme'});
      });

      test('members of a suspended org read and write nothing', () async {
        const susEmail = 'suspended@lab.test';
        final susUid = await createAuthUser(susEmail);
        await seed('organizations/org_suspended', <String, dynamic>{
          'name': 'Suspended Co',
          'ownerUid': 'seed_owner',
          'status': 'suspended',
          'schemaVersion': 2,
          'version': 1,
          'trialConsumed': true,
          'manuallyActivated': false,
        });
        await seed('users/$susUid', <String, dynamic>{
          'email': susEmail,
          'organizationId': 'org_suspended',
          'role': 'lab',
          'status': 'active',
          'memberId': 'member_sus',
          'version': 1,
          'updatedBy': susUid,
        });
        await seed(
          'organizations/org_suspended/members/member_sus',
          memberPayload(
            'member_sus',
            uid: susUid,
            email: susEmail,
            role: 'lab',
            status: 'active',
            version: 1,
            updatedBy: susUid,
          ),
        );
        await signInAs(susEmail);
        // The gate read stays open so the app can show the trial-expired
        // screen with the support contacts.
        expectAllowed(
          'suspended member reads the org document',
          await userGet('organizations/org_suspended'),
        );
        expectDenied(
          'suspended member lists samples',
          await userList('organizations/org_suspended/samples'),
        );
        expectDenied(
          'suspended member writes a sample',
          await userPatch(
            'organizations/org_suspended/samples/s1',
            envelope(uid: susUid, org: 'org_suspended'),
          ),
        );
        expectDenied(
          'suspended member lists the roster',
          await userList('organizations/org_suspended/members'),
        );
      });
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
            // A user-facing write carries the whole document (see [userPatch]):
            // the binding is dropped by *omitting* `organizationId` and
            // `memberId`, exactly what the client's `FieldValue.delete()`
            // produces after the merge.
            await userPatch('users/$leaverUid', <String, dynamic>{
              'email': leaverEmail,
              'role': 'lab',
              'status': 'disabled',
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
            'email': leaverEmail,
            'role': 'admin',
            'status': 'disabled',
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
              'email': leaverEmail,
              'organizationId': _org,
              'role': 'lab',
              'status': 'disabled',
              'memberId': 'member_$leaverUid',
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
