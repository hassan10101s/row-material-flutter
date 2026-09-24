import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';

void main() {
  group('formula engine operators', () {
    test('matches operators followed by operands', () {
      expect(evaluateFormula('2+2'), 4);
      expect(evaluateFormula('v1+v2', values: {'v1': 10, 'v2': 20}), 30);
      expect(evaluateFormula('1.4007*F/M', values: {'F': 5, 'M': 2}), closeTo(3.50175, 1e-9));
      expect(evaluateFormula('a<b', values: {'a': 1, 'b': 2}), 1);
      expect(
        evaluateFormula('(v2-v1)*0.1*1.4007*F/M',
            values: {'v1': 10, 'v2': 20, 'F': 5, 'M': 2}),
        closeTo((20 - 10) * 0.1 * 1.4007 * 5 / 2, 1e-9),
      );
      expect(evaluateFormula('2**3'), 8);
    });

    test('rejects malformed input', () {
      expect(() => evaluateFormula('2+'),
          throwsA(isA<ValidationError>()));
      expect(() => evaluateFormula('(2+3'),
          throwsA(isA<ValidationError>()));
      expect(() => evaluateFormula('unknownfn(2)'),
          throwsA(isA<ValidationError>()));
    });
  });
}