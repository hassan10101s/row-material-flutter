import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/analysis_value_warning.dart';

void main() {
  test(
    'warns strictly above twice the actual maximum in legacy reference shapes',
    () {
      for (final reference in <Object>[
        {'min': 5, 'max': 14},
        {
          'value': {'min': 5, 'max': 14},
          'unit': '%',
        },
        {'value': '5-14', 'unit': '%'},
        '{"min":5,"max":14}',
        'Min 5 Max 14',
        'Maximum: 14 %',
        '<= 14',
        '≤ 14',
        '< 14',
        '5 – 14',
        '5 to 14',
        'الحد الأعلى: ١٤',
        '14',
        14,
      ]) {
        expect(analysisUpperBound(reference), 14, reason: '$reference');
        expect(exceedsDoubleAnalysisMaximum('28', reference), isFalse);
        expect(exceedsDoubleAnalysisMaximum('28.001', reference), isTrue);
        expect(exceedsDoubleAnalysisMaximum('20', reference), isFalse);
      }
    },
  );
  test('supports Arabic/Persian decimals, zero and finite signed bounds', () {
    expect(
      exceedsDoubleAnalysisMaximum('٢٨٫١ %', {'max': 14, 'unit': '%'}),
      isTrue,
    );
    expect(exceedsDoubleAnalysisMaximum('۲۸,۱', {'max': '۱۴'}), isTrue);
    expect(exceedsDoubleAnalysisMaximum(0, {'max': 0}), isFalse);
    expect(exceedsDoubleAnalysisMaximum(.1, {'max': 0}), isTrue);
    expect(analysisUpperBound('-10 - -5'), -5);
    expect(exceedsDoubleAnalysisMaximum(3, {'max': 1.5}), isFalse);
  });
  test(
    'missing, minimum-only, textual and invalid inputs never invent maxima',
    () {
      for (final reference in <Object?>[
        null,
        '',
        'Min 5',
        '>= 5',
        '≥ 5',
        {'min': 5},
        'Good|Excellent',
        'climax 14',
        'max 14broken',
        {'max': double.infinity},
        {'max': 'invalid'},
        '14-5',
        '{invalid}',
      ]) {
        expect(analysisUpperBound(reference), isNull, reason: '$reference');
        expect(exceedsDoubleAnalysisMaximum(10000, reference), isFalse);
      }
      for (final value in [
        '',
        'FAILURE',
        '12kg5',
        '< 100',
        double.nan,
        double.infinity,
      ]) {
        expect(exceedsDoubleAnalysisMaximum(value, {'max': 14}), isFalse);
      }
      expect(
        exceedsDoubleAnalysisMaximum('1000 ppm', {
          'value': 'Max 14',
          'unit': '%',
        }),
        isFalse,
      );
      expect(exceedsDoubleAnalysisMaximum('1000 ppm', 'Max 14%'), isFalse);
    },
  );
  test(
    'looks up the selected material/product snapshot by its analysis name',
    () {
      final snapshot = {
        'chemical_reference_json': '{"Moisture":{"min":1,"max":14}}',
        'physical_reference': {
          'Density': {'max': 2},
        },
      };
      expect(
        analysisUpperBound(
          inspectionAnalysisReference(snapshot, [' moisture ']),
        ),
        14,
      );
      expect(
        analysisUpperBound(inspectionAnalysisReference(snapshot, ['Density'])),
        2,
      );
      expect(inspectionAnalysisReference(snapshot, ['Weight']), isNull);
    },
  );
}
