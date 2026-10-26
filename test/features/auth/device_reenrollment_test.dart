import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/device_identity_store.dart';
import 'package:material_lab/core/auth/session_store.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/firebase/firebase_bootstrap.dart';
import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/sync/device_registry.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/features/auth/data/offline_first_auth_repository.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';

class _Db extends Mock implements DatabaseHelper {}

class _Store extends Mock implements SessionStore {}

class _Network extends Mock implements ConnectivityService {}

class _Metadata extends Mock implements SyncMetadata {}

class _Remote extends Mock implements AuthRemoteDataSource {}

class _Devices extends Mock implements DeviceRegistry {}

class _DataRemote extends Mock implements RemoteDataSource {}

class _Audit extends Mock implements AuditLogger {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const AppSession()));
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'enrollment lookup distinguishes missing, active, revoked and foreign identities without writes',
    () async {
      final remote = _DataRemote();
      final registry = DeviceRegistry(
        remote: remote,
        metadata: _Metadata(),
        audit: _Audit(),
        source: SessionSource.empty(() => const AppSession()),
      );
      when(() => remote.isSignedIn).thenReturn(true);
      Future<bool> check() => registry.requiresNewEnrollment(
        organizationId: 'org',
        uid: 'u',
        deviceId: 'device',
      );
      for (final item in [
        (RemoteDocument.missing, false),
        (
          const RemoteDocument(id: 'device', data: {'uid': 'u'}, version: 1),
          false,
        ),
        (
          const RemoteDocument(
            id: 'device',
            data: {'uid': 'u', 'status': 'revoked'},
            version: 2,
          ),
          true,
        ),
        (
          const RemoteDocument(
            id: 'device',
            data: {'uid': 'other'},
            version: 1,
          ),
          true,
        ),
      ]) {
        when(
          () => remote.getDocument(
            organizationId: 'org',
            collection: SyncCollection.devices,
            documentId: 'device',
          ),
        ).thenAnswer((_) async => item.$1);
        expect(await check(), item.$2);
      }
      when(
        () => remote.getDocument(
          organizationId: 'org',
          collection: SyncCollection.devices,
          documentId: 'device',
        ),
      ).thenThrow(StateError('permission-denied'));
      expect(await check(), isTrue);
      when(
        () => remote.getDocument(
          organizationId: 'org',
          collection: SyncCollection.devices,
          documentId: 'device',
        ),
      ).thenThrow(StateError('network unavailable'));
      expect(await check(), isFalse);
      // This path only reads the device document, never reactivates it.
      expect(
        verify(
          () => remote.getDocument(
            organizationId: 'org',
            collection: SyncCollection.devices,
            documentId: 'device',
          ),
        ).callCount,
        6,
      );
    verify(() => remote.isSignedIn).called(6);
    verifyNoMoreInteractions(remote);
    },
  );

  test(
    'installation identity preserves legacy id across stores and rotates explicitly',
    () async {
      final first = DeviceIdentityStore(generate: () => 'fresh-id');
      expect(await first.loadOrMigrate('legacy-id'), 'legacy-id');
      final reopened = DeviceIdentityStore(generate: () => 'fresh-id');
      expect(await reopened.loadOrMigrate('other-org-id'), 'legacy-id');
      expect(await reopened.rotate(), 'fresh-id');
      expect(
        await DeviceIdentityStore().loadOrMigrate('legacy-id'),
        'fresh-id',
      );
      expect(DeviceIdentityStore.newId(), isNot(DeviceIdentityStore.newId()));
    },
  );

  group('authenticated reenrollment', () {
    late _Remote remote;
    late _Db db;
    late _Store store;
    late _Network network;
    late _Metadata metadata;
    late _Devices devices;
    late OfflineFirstAuthRepository auth;
    late DeviceIdentityStore identities;
    late String? boundOrg;
    late Map<String, String> values;
    var memberStatus = 'active';
    var revoked = true;

    setUp(() {
      remote = _Remote();
      db = _Db();
      store = _Store();
      network = _Network();
      metadata = _Metadata();
      devices = _Devices();
      identities = DeviceIdentityStore(generate: () => 'new-installation');
      boundOrg = null;
      memberStatus = 'active';
      revoked = true;
      values = {
        SyncMetadata.deviceIdKey: 'old-revoked',
        DeviceRegistry.lastRegisteredAtKey: DateTime.now().toIso8601String(),
        'device_registered_org': 'org',
      };
      when(() => remote.isConfigured).thenReturn(true);
      when(() => network.isOnline).thenReturn(true);
      when(() => remote.currentUser()).thenAnswer(
        (_) async => const RemoteUser(uid: 'u', email: 'u@example.com'),
      );
      when(() => remote.loadProfile('u')).thenAnswer(
        (_) async => UserProfile(
          uid: 'u',
          email: 'u@example.com',
          organizationId: 'org',
          role: 'admin',
          status: memberStatus,
          memberId: 'm',
        ),
      );
      when(() => remote.loadOrganization('org')).thenAnswer((_) async => null);
      when(() => remote.signInWithGoogle()).thenAnswer((_) async {});
      when(() => remote.signOut()).thenAnswer((_) async {});
      when(() => store.save(any())).thenAnswer((_) async {});
      when(() => store.clear()).thenAnswer((_) async {});
      when(
        () => metadata.ensureDeviceId(any()),
      ).thenAnswer((_) async => 'old-revoked');
      when(
        () => metadata.get(any()),
      ).thenAnswer((i) async => values[i.positionalArguments[0]] ?? '');
      when(() => metadata.set(any(), any())).thenAnswer((i) async {
        values[i.positionalArguments[0] as String] =
            i.positionalArguments[1] as String;
      });
      when(() => metadata.remove(any())).thenAnswer((i) async {
        values.remove(i.positionalArguments[0]);
      });
      when(() => db.boundOrgId).thenAnswer((_) => boundOrg);
      when(() => db.bindOrg(any())).thenAnswer((i) async {
        boundOrg = i.positionalArguments[0] as String?;
        return boundOrg ?? '';
      });
      when(
        () => devices.requiresNewEnrollment(
          organizationId: 'org',
          uid: 'u',
          deviceId: 'old-revoked',
        ),
      ).thenAnswer((_) async => revoked);
      auth = OfflineFirstAuthRepository(
        remote: remote,
        sessionStore: store,
        dbHelper: db,
        connectivity: network,
        metadata: metadata,
        bootstrap: const FirebaseBootstrapResult(status: FirebaseStatus.ready),
        devices: devices,
        identities: identities,
      );
    });

    test(
      'cached restore signs out a revoked device without rotating or registering',
      () async {
        expect(await auth.restoreSession(), AuthState.signedOut);
        expect(boundOrg, isNull);
        expect(await identities.loadOrMigrate(''), 'old-revoked');
        verify(() => remote.signOut()).called(1);
        verifyNever(() => devices.ensureRegistered(force: any(named: 'force')));
      },
    );

    test(
      'fresh login uses a new identity and clears the old registration throttle',
      () async {
        await auth.restoreSession();
        String? registeredIdentity;
        auth.onOrganizationBound = (_) async {
          registeredIdentity = auth.session.deviceId;
        };
        await auth.signInWithGoogle();
        expect(auth.state, AuthState.ready);
        expect(registeredIdentity, 'new-installation');
        expect(values[SyncMetadata.deviceIdKey], 'new-installation');
        expect(values.containsKey(DeviceRegistry.lastRegisteredAtKey), isFalse);
        expect(
          await DeviceIdentityStore().loadOrMigrate('old-revoked'),
          'new-installation',
        );
        verifyNever(() => devices.revoke(any(), reason: any(named: 'reason')));
      },
    );

    test('active installations keep their existing identity', () async {
      revoked = false;
      expect(await auth.restoreSession(), AuthState.ready);
      expect(auth.session.deviceId, 'old-revoked');
      expect(await identities.loadOrMigrate(''), 'old-revoked');
    });

    test(
      'inactive members keep the activation gate without enrollment reads',
      () async {
        memberStatus = 'disabled';
        expect(await auth.restoreSession(), AuthState.awaitingActivation);
        expect(boundOrg, isNull);
        verifyNever(
          () => devices.requiresNewEnrollment(
            organizationId: 'org',
            uid: 'u',
            deviceId: 'old-revoked',
          ),
        );
      },
    );
  });
}
