import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/lab_repo.dart';
import 'run_test_state.dart';

/// Drives the "Run a test" form: loads analyses/products, holds the current
/// selection, looks up raw-material entry codes and executes sample tests.
/// Text-field values live in the tab (pure UI); this cubit owns data and
/// business state. Errors from [run] rethrow so the caller can show a dialog
/// with the result or a feedback snackbar.
class RunTestCubit extends AppCubit<RunTestState> {
  RunTestCubit({required this.repo}) : super(const RunTestState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final analyses = await repo.listAnalyses();
      final products = await repo.listProducts();
      int? analysisId = state.analysisId;
      if (analysisId == null && analyses.isNotEmpty) {
        analysisId = (analyses.first['id'] as num).toInt();
      }
      safeEmit(state.copyWith(
        loading: false,
        analyses: analyses,
        products: products,
        analysisId: analysisId,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  void selectAnalysis(int id) {
    if (id == state.analysisId) return;
    safeEmit(state.copyWith(analysisId: id));
  }

  void setSourceType(String type) {
    if (type == state.sourceType) return;
    safeEmit(state.copyWith(sourceType: type));
  }

  void selectProduct(int id) {
    if (id == state.productId) return;
    safeEmit(state.copyWith(productId: id));
  }

  /// Resolves a raw-material entry code and, when found, records the
  /// material name as the test source. Returns true when resolved.
  Future<bool> lookupEntry(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return false;
    final inspection = await repo.resolveInspection(trimmed);
    if (inspection == null) return false;
    safeEmit(state.copyWith(sourceName: '${inspection['material_name'] ?? ''}'));
    return true;
  }

  /// Runs the sample test. On success returns the result payload (test,
  /// consumption, range check, etc.) so the caller can render the dialog.
  /// Errors rethrow; the running flag is cleared in finally.
  Future<Map<String, dynamic>> run({
    required String sampleName,
    required String resultText,
    required Map<String, dynamic> dynamicValues,
    required String entryCode,
    Map<String, dynamic>? user,
  }) async {
    safeEmit(state.copyWith(running: true, error: null));
    try {
      final sourceName = state.sourceType == 'product'
          ? _productName(state.productId)
          : state.sourceName;
      return await repo.runSampleTest(
        analysisId: state.analysisId!,
        sourceType: state.sourceType,
        sourceRefId: state.sourceType == 'product' ? state.productId : null,
        sourceName: sourceName,
        sampleName: sampleName.trim(),
        resultText: resultText.trim(),
        dynamicValues: dynamicValues,
        user: user,
        entryCode: state.sourceType == 'raw_material' ? entryCode.trim() : '',
      );
    } finally {
      safeEmit(state.copyWith(running: false));
    }
  }

  String _productName(int? productId) {
    if (productId == null) return '';
    for (final p in state.products) {
      if (p['id'] == productId) return '${p['name'] ?? ''}';
    }
    return '';
  }
}