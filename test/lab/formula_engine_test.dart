import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';

void main() {
  group('finite formula numbers', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      'NaN',
      'Infinity',
    ]) {
      test('rejects the nonfinite input $value', () {
        expect(
          () => evaluateFormula('X', values: {'X': value}),
          throwsA(isA<ValidationError>()),
        );
        expect(
          () => resolveConstants({'X': value}),
          throwsA(isA<ValidationError>()),
        );
      });
    }
    for (final expression in [
      'X * X',
      'X + X',
      '-X - X',
      'X / Y',
      '1 % 0',
      '(X * X) > 0',
    ]) {
      test('rejects an invalid intermediate result in $expression', () {
        expect(
          () => evaluateFormula(expression, values: {'X': 1e308, 'Y': 1e-308}),
          throwsA(isA<ValidationError>()),
        );
      });
    }
    test('rejects overflow literals and invalid constant bounds/precision', () {
      expect(
        () => FormulaParser.parse(List.filled(400, '9').join()),
        throwsA(isA<ValidationError>()),
      );
      for (final bound in ['NaN', 'Infinity', 'invalid']) {
        expect(
          () => resolveConstants({
            'X': {'value': 2, 'min_value': bound},
          }),
          throwsA(isA<ValidationError>()),
        );
        expect(
          () => resolveConstants({
            'X': {'value': 2, 'max_value': bound},
          }),
          throwsA(isA<ValidationError>()),
        );
      }
      expect(
        () => resolveConstants({
          'X': {'value': 2, 'precision': 400},
        }),
        throwsA(isA<ValidationError>()),
      );
    });
    test('finite signed results and decimal constants still work', () {
      expect(evaluateFormula('X - 5', constants: {'X': '1,5'}), -3.5);
      expect(
        evaluateFormula(
          'X',
          constants: {
            'X': {
              'value': 2.25,
              'min_value': 0,
              'max_value': 3,
              'precision': 1,
            },
          },
        ),
        closeTo(2.3, 1e-12),
      );
      expect(
        resolveConstants({
          'X': {'value': 1e308, 'precision': 2},
        })['X'],
        1e308,
      );
    });
  });
  group('formula engine operators', () {
    test('matches operators followed by operands', () {
      expect(evaluateFormula('2+2'), 4);
      expect(evaluateFormula('v1+v2', values: {'v1': 10, 'v2': 20}), 30);
      expect(
        evaluateFormula('1.4007*F/M', values: {'F': 5, 'M': 2}),
        closeTo(3.50175, 1e-9),
      );
      expect(evaluateFormula('a<b', values: {'a': 1, 'b': 2}), 1);
      expect(
        evaluateFormula(
          '(v2-v1)*0.1*1.4007*F/M',
          values: {'v1': 10, 'v2': 20, 'F': 5, 'M': 2},
        ),
        closeTo((20 - 10) * 0.1 * 1.4007 * 5 / 2, 1e-9),
      );
      expect(evaluateFormula('2**3'), 8);
    });

    test('rejects malformed input', () {
      expect(() => evaluateFormula('2+'), throwsA(isA<ValidationError>()));
      expect(() => evaluateFormula('(2+3'), throwsA(isA<ValidationError>()));
      expect(
        () => evaluateFormula('unknownfn(2)'),
        throwsA(isA<ValidationError>()),
      );
    });
  });
}
