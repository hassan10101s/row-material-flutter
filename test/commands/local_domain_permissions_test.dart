import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/commands/local_domain_permissions.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';

void main() {
  const nutrition = AppSession(
    uid: 'u',
    organizationId: 'o',
    deviceId: 'd',
    role: 'nutritionist',
    status: 'active',
  );
  const lab = AppSession(
    uid: 'u',
    organizationId: 'o',
    deviceId: 'd',
    role: 'lab',
    status: 'active',
  );
  const definitions = {
    'nutritionFormulation': {
      'permission': 'formulations.update',
      'fields': ['organizationId', 'physicalResultsJson', 'amount'],
    },
    'sample': {
      'permission': 'samples.update',
      'fields': ['organizationId', 'quantityNumber', 'description'],
      'sqlFields': {
        'quantityNumber': {'type': 'INTEGER'},
        'description': {'type': 'TEXT'},
      },
    },
    'qualityCheck': {
      'permission': 'qc.approve',
      'appendOnly': true,
      'fields': ['newStatus'],
    },
    'qcTemplate': {
      'permission': 'qc.write',
      'fields': ['name'],
    },
    'member': {
      'permission': 'users.update',
      'fields': ['role', 'status'],
    },
  };
  Map<String, Object?> write(
    String type,
    String operation,
    Map<String, Object?> payload,
  ) => {
    'entityType': type,
    'entityId': 'record-1',
    'operation': operation,
    'expectedVersion': operation == 'create' ? 0 : 1,
    'payload': payload,
  };
  void check(AppSession user, Map<String, Object?> item) =>
      validateLocalDomainPermissions(
        session: user,
        definitions: definitions,
        writes: [item],
      );
  test('nutritionist can save a formulation but not edit an inspection', () {
    check(
      nutrition,
      write('nutritionFormulation', 'create', {'organizationId': 'o'}),
    );
    expect(
      () => check(nutrition, write('sample', 'update', {})),
      throwsA(isA<AuthorizationError>()),
    );
  });
  test('lab manages inspections and QC but cannot administer members', () {
    check(lab, write('sample', 'create', {}));
    check(lab, write('qualityCheck', 'create', {'newStatus': 'APPROVED'}));
    check(
      lab,
      write('qualityCheck', 'create', {'newStatus': 'FULL_REJECTION'}),
    );
    check(lab, write('qcTemplate', 'create', {'name': 'Quality template'}));
    for (final operation in ['create', 'update', 'tombstone']) {
      expect(
        () => check(lab, write('member', operation, {'role': 'admin'})),
        throwsA(isA<AuthorizationError>()),
      );
    }
  });
  test(
    'rejects wrong organization, unknown fields and append-only modification',
    () {
      expect(
        () =>
            check(lab, write('sample', 'create', {'organizationId': 'other'})),
        throwsA(isA<AuthorizationError>()),
      );
      expect(
        () => check(lab, write('sample', 'create', {'unexpected': 1})),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => check(lab, write('qualityCheck', 'update', {})),
        throwsA(isA<ValidationError>()),
      );
    },
  );
  test('rejects invalid numeric and JSON values', () {
    for (final value in [
      double.nan,
      double.infinity,
      9007199254740992,
      9007199254740992.0,
    ]) {
      expect(
        () => check(
          nutrition,
          write('nutritionFormulation', 'create', {'amount': value}),
        ),
        throwsA(isA<ValidationError>()),
      );
    }
    for (final value in ['invalid', '7', 7]) {
      expect(
        () => check(
          nutrition,
          write('nutritionFormulation', 'create', {
            'physicalResultsJson': value,
          }),
        ),
        throwsA(isA<ValidationError>()),
      );
    }
    check(
      nutrition,
      write('nutritionFormulation', 'create', {'physicalResultsJson': '{}'}),
    );
  });
  test('validates declared numeric and text field types', () {
    expect(
      () => check(lab, write('sample', 'create', {'quantityNumber': 1.5})),
      throwsA(isA<ValidationError>()),
    );
    expect(
      () => check(lab, write('sample', 'create', {'description': 1})),
      throwsA(isA<ValidationError>()),
    );
    check(
      lab,
      write('sample', 'create', {'quantityNumber': 1, 'description': 'ok'}),
    );
  });
  test('rejects invalid identity, version and duplicate effects', () {
    final invalid = write('sample', 'create', {})..['entityId'] = 'bad/id';
    expect(() => check(lab, invalid), throwsA(isA<ValidationError>()));
    final badVersion = write('sample', 'update', {})..['expectedVersion'] = 0;
    expect(() => check(lab, badVersion), throwsA(isA<ValidationError>()));
    final duplicate = write('sample', 'create', {});
    expect(
      () => validateLocalDomainPermissions(
        session: lab,
        definitions: definitions,
        writes: [duplicate, duplicate],
      ),
      throwsA(isA<ValidationError>()),
    );
  });
}
