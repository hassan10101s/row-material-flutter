import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/security/secure_field_policy.dart';
import 'package:material_lab/core/utils/app_format.dart';

AppSession actor(String role) => AppSession(
  uid: 'u',
  organizationId: 'o',
  deviceId: 'd',
  status: MemberStatus.active,
  role: role,
);

void main() {
  test(
    'Secure toggles preserve structured numeric bounds without stringifying them',
    () {
      final bounds = {'min': '0', 'max': '0.5'};
      expect(withReferenceSecure(bounds, false), bounds);
      final protected = withReferenceSecure(bounds, true);
      expect(unwrapReferenceValue(protected), bounds);
      expect(withReferenceSecure(protected, false), bounds);
    },
  );

  test(
    'every existing/plain/new parameter defaults to public, including reports',
    () {
      for (final role in AppRoles.all) {
        final policy = SecureFieldPolicy(session: actor(role));
        for (final value in [
          null,
          '10-12',
          12,
          {'value': 12},
          {'value': 12, 'secure': false},
        ]) {
          expect(isReferenceSecure(value), false);
          for (final purpose in SecureFieldPurpose.values) {
            expect(
              policy.visible(value, purpose),
              true,
              reason: '$role $value $purpose',
            );
          }
        }
      }
    },
  );
  test(
    'saved Secure names and values disappear for the inputter and all other roles',
    () {
      final ref = withReferenceSecure('10-12', true);
      for (final role in AppRoles.all) {
        final policy = SecureFieldPolicy(session: actor(role));
        expect(policy.visible(ref, SecureFieldPurpose.savedRecord), false);
        expect(policy.visible(ref, SecureFieldPurpose.report), false);
      }
    },
  );
  test(
    'only owner/quality manager with explicit reveal can see saved Secure',
    () {
      for (final role in AppRoles.all) {
        final policy = SecureFieldPolicy(session: actor(role), reveal: true);
        expect(
          policy.visible({'secure': true}, SecureFieldPurpose.savedRecord),
          [
            AppRoles.admin,
            AppRoles.trialOwner,
            AppRoles.qualityManager,
          ].contains(role),
        );
        expect(
          policy.visible({'secure': true}, SecureFieldPurpose.report),
          false,
        );
      }
    },
  );
  test(
    'specialist can enter once before approval; saved editing is not first entry',
    () {
      final policy = SecureFieldPolicy(session: actor(AppRoles.lab));
      expect(
        policy.visible(
          {'secure': true},
          SecureFieldPurpose.firstEntry,
          isNewUnsavedRecord: true,
          canEnter: true,
        ),
        true,
      );
      expect(
        policy.visible(
          {'secure': true},
          SecureFieldPurpose.firstEntry,
          isNewUnsavedRecord: false,
          canEnter: true,
        ),
        false,
      );
      expect(
        SecureFieldPolicy(session: actor(AppRoles.viewer)).visible(
          {'secure': true},
          SecureFieldPurpose.firstEntry,
          isNewUnsavedRecord: true,
          canEnter: true,
        ),
        false,
      );
    },
  );
  test('suspension and membership disable prevent management and reveal', () {
    final session = actor(AppRoles.admin);
    for (final restricted in [
      session.copyWith(status: MemberStatus.disabled),
      session.copyWith(organizationStatus: OrgStatus.suspended),
    ]) {
      final policy = SecureFieldPolicy(session: restricted, reveal: true);
      expect(policy.mayManage, false);
      expect(
        policy.visible({'secure': true}, SecureFieldPurpose.savedRecord),
        false,
      );
    }
  });
  test('required, Secure, unit and bounds survive independent toggles', () {
    Object? ref = withReferenceSecure(
      withReferenceRequired('10-12', true, '%'),
      true,
    );
    ref = withReferenceUnit(ref, 'g');
    expect(isReferenceRequired(ref), true);
    expect(isReferenceSecure(ref), true);
    expect(referenceValueText(ref), '10-12');
    expect(referenceUnitText(ref), 'g');
    ref = withReferenceRequired(ref, false);
    expect(isReferenceRequired(ref), false);
    expect(isReferenceSecure(ref), true);
    ref = withReferenceSecure(ref, false);
    expect(isReferenceSecure(ref), false);
    expect(referenceValueText(ref), '10-12');
    expect(referenceUnitText(ref), 'g');
  });
  test(
    'omits the whole protected field without a masked label or placeholder',
    () {
      final visible = SecureFieldPolicy(session: actor(AppRoles.lab))
          .visibleParameters(
            {'Moisture': 17, 'Fat': 3},
            {
              'Moisture': {'secure': true},
            },
            SecureFieldPurpose.savedRecord,
          );
      expect(visible, {'Fat': 3});
    },
  );
}
