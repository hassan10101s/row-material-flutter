import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/lab/domain/product_batch_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/product_batch_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/product_batch_state.dart';

class _BatchRepo implements ProductBatchRepository {
  var samples = <Map<String, dynamic>>[];
  final updates = <int, String>{};
  final deleted = <int>[];

  @override
  Future<List<Map<String, dynamic>>> listBatchSamples(int batchId) async =>
      samples;

  @override
  Future<Map<String, dynamic>> addBatchSample({
    required int batchId,
    String? sampleName,
    String sampleTaker = '',
    Map<String, String> physicalResults = const {},
    List<Map<String, String>> chemicalResults = const [],
    Map<String, dynamic>? user,
  }) async {
    final s = {
      'id': samples.length + 1,
      'decision_status': '',
      'sample_taker': sampleTaker,
    };
    samples = [...samples, s];
    return s;
  }

  @override
  Future<void> updateBatchSample(
    int sampleId, {
    String? sampleName,
    String? sampleTaker,
    Map<String, String>? physicalResults,
    List<Map<String, String>>? chemicalResults,
  }) async {}

  @override
  Future<void> setBatchSampleDecision(
    int sampleId, {
    required String status,
    String reason = '',
  }) async {
    updates[sampleId] = status;
  }

  @override
  Future<void> deleteBatchSample(int sampleId) async {
    deleted.add(sampleId);
  }

  @override
  Future<List<Map<String, dynamic>>> listSampleResults(int sampleId) async =>
      const [];
}

void main() {
  // Product batches carry no header quality decision: every decision lives
  // on its own sample row, so this cubit only counts/writes per-sample
  // decisions and never touches the header.
  group('ProductBatchState.decidedCount', () {
    test('counts samples carrying a per-sample decision', () {
      const s = ProductBatchState(
        samples: [
          {'decision_status': 'APPROVED'},
          {'decision_status': ''},
        ],
      );
      expect(s.decidedCount, 1);
    });
  });

  group('ProductBatchCubit', () {
    late _BatchRepo repo;

    setUp(() {
      repo = _BatchRepo();
    });

    ProductBatchCubit cubit() => ProductBatchCubit(
      batchId: 7,
      repo: repo,
      currentUser: () => const UserContext(fullName: 'QC', role: 'admin'),
    );

    test('load fills samples with their own results', () async {
      repo.samples = [
        {
          'id': 1,
          'decision_status': 'APPROVED',
          'sample_taker': 'Karim',
          'physical_results_json': '{"Color": "white"}',
          'chemical_results_json':
              '[{"name": "Protein", "result": "12", "unit": "%"}]',
        },
      ];
      final c = cubit();
      addTearDown(c.close);
      await c.load();
      expect(c.state.loading, isFalse);
      expect(c.state.samples, hasLength(1));
      expect(c.state.decidedCount, 1);
    });

    test('setSampleDecision writes the per-sample decision', () async {
      repo.samples = [
        {'id': 1, 'decision_status': ''},
      ];
      final c = cubit();
      addTearDown(c.close);
      await c.load();
      await c.setSampleDecision(
        1,
        status: 'FULL_REJECTION',
        reason: 'Off spec',
      );
      expect(repo.updates[1], 'FULL_REJECTION');
      expect(c.state.saving, isFalse);
    });

    test('successful add, edit and delete release the saving state', () async {
      final c = cubit();
      addTearDown(c.close);
      await c.addSample(name: 'Operational sample');
      expect(c.state.saving, isFalse);
      expect(c.state.samples, hasLength(1));
      await c.updateSample(1, name: 'Updated');
      expect(c.state.saving, isFalse);
      await c.deleteSample(1);
      expect(c.state.saving, isFalse);
      expect(repo.deleted, [1]);
    });
  });
}
