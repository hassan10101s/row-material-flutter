import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/lab/domain/nir_validation_repository.dart';
import 'package:material_lab/features/lab/data/nir_validation_repo.dart';

void main() {
  group('NIR validation math', () {
    test('bias is the average signed deviation', () {
      final stats = NirParameterStats(
        scope: NirScope.rawMaterial,
        entityId: 1,
        entityName: 'wheat',
        parameter: 'protein',
        unit: '%',
        points: const [
          NirValidationPoint(
            inspectionId: 1,
            entryCode: 'E1',
            inspectionDate: '2026-01-01',
            sampleName: '',
            nirValue: 5,
            labValue: 4,
          ),
          NirValidationPoint(
            inspectionId: 2,
            entryCode: 'E2',
            inspectionDate: '2026-01-02',
            sampleName: '',
            nirValue: 3,
            labValue: 4,
          ),
        ],
      );
      expect(stats.count, 2);
      expect(stats.bias, 0); // (+1 − 1) / 2
      expect(stats.maxDeviation, 1);
    });

    test('perfect linear data fits lab = slope·nir + intercept exactly', () {
      // lab = 2·nir − 1: nir 2,3,4,5 → lab 3,5,7,9
      NirValidationPoint p(double nir, double lab) => NirValidationPoint(
            inspectionId: 0,
            entryCode: 'x',
            inspectionDate: '2026-01-01',
            sampleName: '',
            nirValue: nir,
            labValue: lab,
          );
      final stats = NirParameterStats(
        scope: NirScope.rawMaterial,
        entityId: 1,
        entityName: 'wheat',
        parameter: 'protein',
        unit: '%',
        points: [p(2, 3), p(3, 5), p(4, 7), p(5, 9)],
      );
      expect(stats.slope, closeTo(2, 1e-9));
      expect(stats.intercept, closeTo(-1, 1e-9));
      expect(stats.r2, closeTo(1, 1e-9));
      expect(stats.rmse, closeTo(0, 1e-9));
    });

    test('reliability thresholds follow point count and R²', () {
      NirParameterStats stats(List<NirValidationPoint> points) =>
          NirParameterStats(
            scope: NirScope.product,
            entityId: 1,
            entityName: 'bread',
            parameter: 'moisture',
            unit: '%',
            points: points,
          );
      expect(stats([]).reliability, NirReliability.insufficientData);
      // Only one point: insufficient even with a perfect score.
      expect(
        stats([
          NirValidationPoint(
            inspectionId: 1,
            entryCode: 'x',
            inspectionDate: '2026-01-01',
            sampleName: '',
            nirValue: 1,
            labValue: 1,
          ),
        ]).reliability,
        NirReliability.insufficientData,
      );
    });

    test('slope-only is the through-origin least-squares slope', () {
      NirValidationPoint p(double nir, double lab) => NirValidationPoint(
            inspectionId: 0,
            entryCode: 'x',
            inspectionDate: '2026-01-01',
            sampleName: '',
            nirValue: nir,
            labValue: lab,
          );
      // lab = 2·nir exactly: a₀ = Σxy/Σx² = (2+8+18+32+50)/(1+4+9+16+25) = 2.
      final stats = NirParameterStats(
        scope: NirScope.rawMaterial,
        entityId: 1,
        entityName: 'wheat',
        parameter: 'protein',
        unit: '%',
        points: [p(1, 2), p(2, 4), p(3, 6), p(4, 8), p(5, 10)],
      );
      expect(stats.slopeOnly, closeTo(2, 1e-9));
      expect(stats.rmseOf(NirAdjustmentMode.slopeOnly), closeTo(0, 1e-9));
      expect(stats.biasOf(NirAdjustmentMode.slopeOnly), closeTo(0, 1e-9));
      // The intercept of the full fit is 0 → not significant → slope only.
      expect(stats.interceptTestT, closeTo(0, 1e-9));
      expect(
        stats.adjustmentAdvice.recommended,
        NirAdjustmentMode.slopeOnly,
      );
    });

    test('significant intercept pushes the advice to slope + intercept', () {
      NirValidationPoint p(double nir, double lab) => NirValidationPoint(
            inspectionId: 0,
            entryCode: 'x',
            inspectionDate: '2026-01-01',
            sampleName: '',
            nirValue: nir,
            labValue: lab,
          );
      // lab = 2·nir − 1: the constant −1 offset can only be corrected with an
      // intercept; the through-origin fit leaves a systematic residual bias.
      final stats = NirParameterStats(
        scope: NirScope.product,
        entityId: 1,
        entityName: 'bread',
        parameter: 'moisture',
        unit: '%',
        points: [
          p(2, 3),
          p(3, 5),
          p(4, 7),
          p(5, 9),
          p(6, 11),
        ],
      );
      expect(stats.slopeOnly, closeTo(160 / 90, 1e-9));
      expect(
        stats.biasOf(NirAdjustmentMode.slopeOnly).abs(),
        greaterThan(0.1),
      );
      expect(stats.biasOf(NirAdjustmentMode.slopeAndIntercept),
          closeTo(0, 1e-9));
      expect(stats.interceptTestT.abs(), greaterThan(2));
      expect(
        stats.adjustmentAdvice.recommended,
        NirAdjustmentMode.slopeAndIntercept,
      );
    });

    test('too few points advise slope + intercept by default', () {
      final stats = NirParameterStats(
        scope: NirScope.rawMaterial,
        entityId: 1,
        entityName: 'wheat',
        parameter: 'protein',
        unit: '%',
        points: const [
          NirValidationPoint(
            inspectionId: 1,
            entryCode: 'x',
            inspectionDate: '2026-01-01',
            sampleName: '',
            nirValue: 4,
            labValue: 7,
          ),
          NirValidationPoint(
            inspectionId: 2,
            entryCode: 'y',
            inspectionDate: '2026-01-02',
            sampleName: '',
            nirValue: 5,
            labValue: 9,
          ),
        ],
      );
      final advice = stats.adjustmentAdvice;
      expect(advice.recommended, NirAdjustmentMode.slopeAndIntercept);
      expect(advice.interceptT, 0);
      expect(advice.reasons, isNotEmpty);
    });

    test('parseNumeric keeps the leading number out of suffix text', () {
      expect(parseNumeric('12.3%'), 12.3);
      expect(parseNumeric('- 0.5'), -0.5);
      expect(parseNumeric('-0.5'), -0.5);
      expect(parseNumeric('  '), null);
      expect(parseNumeric('abc'), null);
      expect(parseNumeric('7'), 7.0);
    });
  });
}
