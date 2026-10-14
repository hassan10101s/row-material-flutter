import 'dart:async';

import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../inspections/domain/inspection_repository.dart';
import '../../domain/product_batch_repository.dart';
import 'product_batch_state.dart';

/// Drives the "table inside the report" for one product batch.
///
/// Reads/writes go through [ProductBatchRepository] (sample rows with their
/// own results — fully independent of the lab pipeline). Product batches
/// carry no header quality decision: each sample is decided on its own row.
class ProductBatchCubit extends AppCubit<ProductBatchState> {
  ProductBatchCubit({
    required this.batchId,
    required this.repo,
    required this.currentUser,
  }) : super(const ProductBatchState());

  final int batchId;
  final ProductBatchRepository repo;

  /// Read at call time (session may change); null = signed out.
  final FutureOr<UserContext?> Function() currentUser;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final samples = await repo.listBatchSamples(batchId);
      safeEmit(state.copyWith(loading: false, samples: samples));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> refresh() => load();

  /// Appends the next sample row with its own taker + results.
  Future<Map<String, dynamic>?> addSample({
    String? name,
    String sampleTaker = '',
    Map<String, String> physicalResults = const {},
    List<Map<String, String>> chemicalResults = const [],
  }) async {
    safeEmit(state.copyWith(saving: true, clearError: true));
    try {
      final user = await currentUser();
      final sample = await repo.addBatchSample(
        batchId: batchId,
        sampleName: name,
        sampleTaker: sampleTaker,
        physicalResults: physicalResults,
        chemicalResults: chemicalResults,
        user: user == null
            ? null
            : {'id': user.id, 'uid': user.uid, 'fullName': user.fullName},
      );
      await load();
      return sample;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
      return null;
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
      return null;
    }
  }

  /// Edits a sample's identity and/or its own results (null = unchanged).
  Future<void> updateSample(
    int sampleId, {
    String? name,
    String? sampleTaker,
    Map<String, String>? physicalResults,
    List<Map<String, String>>? chemicalResults,
  }) async {
    safeEmit(state.copyWith(saving: true, clearError: true));
    try {
      await repo.updateBatchSample(
        sampleId,
        sampleName: name,
        sampleTaker: sampleTaker,
        physicalResults: physicalResults,
        chemicalResults: chemicalResults,
      );
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> setSampleDecision(
    int sampleId, {
    required String status,
    String reason = '',
  }) async {
    safeEmit(state.copyWith(saving: true, clearError: true));
    try {
      await repo.setBatchSampleDecision(
        sampleId,
        status: status,
        reason: reason,
      );
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> deleteSample(int sampleId) async {
    safeEmit(state.copyWith(saving: true, clearError: true));
    try {
      await repo.deleteBatchSample(sampleId);
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }
}
