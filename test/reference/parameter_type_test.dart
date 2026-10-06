import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/reference/domain/parameter_type.dart';

/// The single definition of the two parameter kinds: chemical and physical
/// are disjoint, and nothing may silently file a row under physical.
void main() {
  group('parse (writers are explicit)', () {
    test('accepts both kinds case-insensitively', () {
      expect(ParameterType.parse('chemical'), ParameterType.chemical);
      expect(ParameterType.parse('Physical'), ParameterType.physical);
      expect(ParameterType.parse('  CHEMICAL  '), ParameterType.chemical);
    });

    test('rejects anything else instead of defaulting', () {
      expect(
        () => ParameterType.parse('phys'),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => ParameterType.parse(''),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('ofDb (readers of legacy data)', () {
    test('null, empty and unknown read as chemical, never physical', () {
      expect(ParameterType.ofDb(null), ParameterType.chemical);
      expect(ParameterType.ofDb(''), ParameterType.chemical);
      expect(ParameterType.ofDb('whatever'), ParameterType.chemical);
    });

    test('physical survives the round trip', () {
      expect(ParameterType.ofDb('physical'), ParameterType.physical);
      expect(ParameterType.ofDb('chemical'), ParameterType.chemical);
    });
  });

  group('matches', () {
    test('filters one vocabulary at a time', () {
      const rows = [
        {'parameter_type': 'chemical'},
        {'parameter_type': 'physical'},
        {'parameter_type': null},
      ];
      expect(
        rows.where((r) => ParameterType.chemical.matches(r['parameter_type'])),
        hasLength(2),
      );
      expect(
        rows.where((r) => ParameterType.physical.matches(r['parameter_type'])),
        hasLength(1),
      );
    });
  });
}
