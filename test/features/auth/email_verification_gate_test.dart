import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/sync/remote/auth_remote_data_source.dart';
import 'package:material_lab/core/sync/remote/firestore_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/commands/command_contract.dart'
    show commandSchemaVersion;
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';
import 'package:material_lab/features/auth/presentation/cubit/create_organization_cubit.dart';
import 'package:material_lab/features/organizations/data/firestore_organization_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockFds extends Mock implements FirestoreDataSource {}

class _MockGoogle extends Mock implements GoogleAuthDataSource {}

class _MockAuthRemote extends Mock implements AuthRemoteDataSource {}

class _MockGuard extends Mock implements MemberWriteGuard {}

class _MockOrgRemoteRepo extends Mock implements OrganizationRepository {}

class _MockAuthRepo extends Mock implements AuthRepository {}

class _MockGate extends Mock implements AuthGate {}

// These two are sealed in cloud_firestore, but faking a document handle is the
// only way to test `loadOrganization`'s missing-document path without spinning
// up the Firestore emulator.
// ignore: subtype_of_sealed_class
class _MockDocRef extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

// ignore: subtype_of_sealed_class
class _MockSnapshot extends Mock
    implements DocumentSnapshot<Map<String, dynamic>> {}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('organization creation gates', () {
    late _MockAuthRemote remote;

    setUp(() {
      remote = _MockAuthRemote();
    });

    FirestoreOrganizationRepository build() =>
        FirestoreOrganizationRepository(remote: remote, guard: _MockGuard());

    test('an unverified e-mail never reaches the genesis batch', () async {
      when(() => remote.isConfigured).thenReturn(true);
      when(() => remote.currentUser()).thenAnswer(
        (_) async => const RemoteUser(
          uid: 'uid-1',
          email: 'm@example.com',
          emailVerified: false,
        ),
      );

      await expectLater(
        build().createOrganization(name: 'Acme'),
        throwsA(
          isA<OrganizationFailure>()
              .having((f) => f.code, 'code', 'email_unverified')
              .having(
                (f) => f.message,
                'message',
                'وثّق بريدك الإلكتروني أولاً — أرسلنا رابط التوثيق إلى بريدك عند إنشاء الحساب. افتح الرابط ثم اضغط «تحققت الآن».',
              ),
        ),
      );
      verifyNever(
        () => remote.createOrganization(
          uid: any(named: 'uid'),
          email: any(named: 'email'),
          displayName: any(named: 'displayName'),
          organizationName: any(named: 'organizationName'),
        ),
      );
    });

    test(
      'a verified account maps a rules denial to a readable message',
      () async {
        when(() => remote.isConfigured).thenReturn(true);
        when(() => remote.currentUser()).thenAnswer(
          (_) async => const RemoteUser(
            uid: 'uid-1',
            email: 'm@example.com',
            emailVerified: true,
          ),
        );
        when(() => remote.loadProfile('uid-1')).thenAnswer((_) async => null);
        when(
          () => remote.createOrganization(
            uid: 'uid-1',
            email: 'm@example.com',
            displayName: '',
            organizationName: 'Acme',
          ),
        ).thenThrow(
          FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
            message: 'Missing or insufficient permissions.',
          ),
        );

        await expectLater(
          build().createOrganization(name: 'Acme'),
          throwsA(
            isA<OrganizationFailure>().having(
              (f) => f.message,
              'message',
              'تم الرفض من الخادم — تحقق من صلاحياتك وحدّث القائمة.',
            ),
          ),
        );
      },
    );

    test('an existing company keeps its specific message', () async {
      when(() => remote.isConfigured).thenReturn(true);
      when(() => remote.currentUser()).thenAnswer(
        (_) async => const RemoteUser(
          uid: 'uid-1',
          email: 'm@example.com',
          emailVerified: true,
        ),
      );
      when(() => remote.loadProfile('uid-1')).thenAnswer((_) async => null);
      when(
        () => remote.createOrganization(
          uid: 'uid-1',
          email: 'm@example.com',
          displayName: '',
          organizationName: 'Acme',
        ),
      ).thenThrow(
        const RemoteAuthException(
          'Organization already exists.',
          code: 'organization_exists',
        ),
      );

      await expectLater(
        build().createOrganization(name: 'Acme'),
        throwsA(
          isA<OrganizationFailure>()
              .having((f) => f.code, 'code', 'organization_exists')
              .having((f) => f.message, 'message', 'الشركة موجودة بالفعل.'),
        ),
      );
    });
  });

  group('loadOrganization returns null for a missing document', () {
    late _MockFds fds;
    late _MockDocRef docRef;

    setUp(() {
      fds = _MockFds();
      docRef = _MockDocRef();
      when(() => fds.organizationRef('org_x')).thenReturn(docRef);
    });

    test('data() == null becomes a null profile instead of a crash', () async {
      final snapshot = _MockSnapshot();
      when(() => snapshot.data()).thenReturn(null);
      when(() => docRef.get()).thenAnswer((_) async => snapshot);
      final source = AuthRemoteDataSourceImpl(
        firestore: fds,
        google: _MockGoogle(),
      );
      expect(await source.loadOrganization('org_x'), isNull);
    });

    test('an existing document parses into a profile', () async {
      final snapshot = _MockSnapshot();
      when(() => snapshot.data()).thenReturn(<String, dynamic>{
        'name': 'Trial Co',
        'ownerUid': 'uid-1',
        'status': 'trial',
        'schemaVersion': commandSchemaVersion,
        'trialStartedAt': '2026-10-01T00:00:00Z',
        'trialEndsAt': '2026-10-31T00:00:00Z',
        'trialConsumed': false,
        'manuallyActivated': false,
      });
      when(() => docRef.get()).thenAnswer((_) async => snapshot);
      final source = AuthRemoteDataSourceImpl(
        firestore: fds,
        google: _MockGoogle(),
      );
      final org = await source.loadOrganization('org_x');
      expect(org, isNotNull);
      expect(org!.status, 'trial');
      expect(org.trialEndsAt, '2026-10-31T00:00:00Z');
    });
  });

  group('CreateOrganizationCubit verification gate', () {
    late _MockAuthRepo auth;
    late _MockGate gate;
    late _MockOrgRemoteRepo orgs;
    late CreateOrganizationCubit cubit;

    setUp(() {
      auth = _MockAuthRepo();
      gate = _MockGate();
      orgs = _MockOrgRemoteRepo();
      when(() => gate.updated()).thenReturn(null);
      when(auth.resolveProfile).thenAnswer((_) async => AuthState.ready);
      cubit = CreateOrganizationCubit(
        auth: auth,
        organizations: orgs,
        gate: gate,
      );
    });

    tearDown(() => cubit.close());

    test('loadEmailVerified surfaces the unverified flag', () async {
      when(() => auth.refreshEmailVerified()).thenAnswer((_) async => false);

      await cubit.loadEmailVerified();

      expect(cubit.state.emailVerified, isFalse);
      verify(() => auth.refreshEmailVerified()).called(1);
    });

    test('a second probe never re-reads the flag', () async {
      when(() => auth.refreshEmailVerified()).thenAnswer((_) async => false);
      await cubit.loadEmailVerified();
      await cubit.loadEmailVerified();
      verify(() => auth.refreshEmailVerified()).called(1);
    });

    test('resend stores the confirmation notice', () async {
      when(auth.sendEmailVerification).thenAnswer((_) async {});

      await cubit.resendVerificationEmail();

      expect(cubit.state.error, isNull);
      expect(
        cubit.state.notice,
        'أُرسل رابط التوثيق من جديد — افتح بريدك واضغط الرابط.',
      );
      expect(cubit.state.verificationBusy, isFalse);
    });

    test('a failed resend lands as a readable error', () async {
      when(auth.sendEmailVerification).thenThrow(
        const AuthFailure(
          'تعذر إرسال رابط التوثيق. تحقق من الاتصال وحاول مرة أخرى.',
          code: 'network_failed',
        ),
      );

      await cubit.resendVerificationEmail();

      expect(
        cubit.state.error,
        'تعذر إرسال رابط التوثيق. تحقق من الاتصال وحاول مرة أخرى.',
      );
      expect(cubit.state.verificationBusy, isFalse);
    });

    test('refresh flips the flag and clears the required notice', () async {
      when(() => auth.refreshEmailVerified()).thenAnswer((_) async => false);
      await cubit.loadEmailVerified();
      when(() => auth.refreshEmailVerified()).thenAnswer((_) async => true);

      await cubit.refreshEmailVerified();

      expect(cubit.state.emailVerified, isTrue);
      expect(cubit.state.notice, isNull);
      expect(cubit.state.error, isNull);
    });

    test('refresh that still finds an unverified flag explains itself', () async {
      when(() => auth.refreshEmailVerified()).thenAnswer((_) async => false);

      await cubit.refreshEmailVerified();

      expect(cubit.state.emailVerified, isFalse);
      expect(
        cubit.state.notice,
        'لم نرصد التوثيق بعد — تأكد من فتح الرابط وانتظر بضع ثوان ثم أعد الفحص.',
      );
      expect(cubit.state.error, isNull);
    });
  });
}
