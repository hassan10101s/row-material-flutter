import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/lab_local_repository.dart';
import '../../domain/lab_result_repository.dart';
import 'run_test_state.dart';

/// Drives the "Run a test" form: loads analyses/products/raw materials,
/// resolves inspection records and executes sample tests.
/// Text-field values live in the tab (pure UI); this cubit owns data and
/// business state. Errors from [run] rethrow so the caller can show a dialog
/// with the result or a feedback snackbar.
///
/// Running a test genuinely spans the three lab contracts - the *definition* of
/// the analysis replicates, the *result* replicates, and the raw-material lookup
/// is local - so this cubit takes all three rather than pretending one of them
/// covers the job.
class RunTestCubit extends AppCubit<RunTestState> {
  RunTestCubit({
    required this.config,
    required this.results,
    required this.local,
  }) : super(const RunTestState());

  final LabConfigurationRepository config;
  final LabResultRepository results;
  final LabLocalRepository local;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final loaded = await Future.wait<Object>([
        config.listAnalyses(),
        config.listProducts(),
        local.listInspectionMaterials(),
      ]);
      final analyses = loaded[0] as List<Map<String, dynamic>>;
      final products = loaded[1] as List<Map<String, dynamic>>;
      final rawMaterials = loaded[2] as List<Map<String, dynamic>>;
      int? analysisId = state.analysisId;
      if (analysisId == null && analyses.isNotEmpty) {
        analysisId = (analyses.first['id'] as num).toInt();
      }
      safeEmit(
        state.copyWith(
          loading: false,
          analyses: analyses,
          products: products,
          rawMaterials: rawMaterials,
          analysisId: analysisId,
        ),
      );
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

  Future<void> selectRawMaterial(int materialId) async {
    safeEmit(
      state.copyWith(
        rawMaterialId: materialId,
        sourceName: _rawMaterialName(materialId),
        inspections: const [],
        selectedInspection: const {},
        selectedSampleName: '',
        loadingInspections: true,
        error: null,
      ),
    );
    try {
      final inspections = await local.listInspectionRecords(materialId);
      if (state.rawMaterialId != materialId) return;
      safeEmit(
        state.copyWith(
          inspections: inspections,
          loadingInspections: false,
        ),
      );
    } on AppError catch (e) {
      safeEmit(
        state.copyWith(loadingInspections: false, error: e.message),
      );
    } catch (e) {
      safeEmit(
        state.copyWith(loadingInspections: false, error: '$e'),
      );
    }
  }

  void selectInspection(int inspectionId) {
    final inspection = state.inspections
        .where((row) => '${row['id']}' == '$inspectionId')
        .firstOrNull;
    if (inspection == null) return;
    final sampleNames = _sampleNamesOf(inspection);
    safeEmit(
      state.copyWith(
        selectedInspection: inspection,
        selectedSampleName: sampleNames.isEmpty ? '' : sampleNames.first,
      ),
    );
  }

  void selectInspectionSample(String sampleName) {
    if (_sampleNamesOf(state.selectedInspection).contains(sampleName)) {
      safeEmit(state.copyWith(selectedSampleName: sampleName));
    }
  }

  /// Runs the sample test. On success returns the result payload (test,
  /// consumption, range check, etc.) so the caller can render the dialog.
  /// Errors rethrow; the running flag is cleared in finally.
  Future<Map<String, dynamic>> run({
    required String sampleName,
    required String resultText,
    required Map<String, dynamic> dynamicValues,
    bool manualResult = false,
    Map<String, dynamic>? user,
  }) async {
    safeEmit(state.copyWith(running: true, error: null));
    try {
      final sourceName = state.sourceType == 'product'
          ? _productName(state.productId)
          : '${state.selectedInspection['material_name'] ?? state.sourceName}';
      return await results.runSampleTest(
        analysisId: state.analysisId!,
        sourceType: state.sourceType,
        sourceRefId: state.sourceType == 'product'
            ? state.productId
            : state.rawMaterialId,
        sourceName: sourceName,
        sampleName: state.sourceType == 'raw_material'
            ? state.selectedSampleName
            : sampleName.trim(),
        resultText: resultText.trim(),
        dynamicValues: dynamicValues,
        user: user,
        entryCode: state.sourceType == 'raw_material'
            ? '${state.selectedInspection['entry_code'] ?? ''}'
            : '',
        manualResult: manualResult,
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

  String _rawMaterialName(int materialId) {
    final material = state.rawMaterials
        .where((row) => '${row['id']}' == '$materialId')
        .firstOrNull;
    return '${material?['material_name'] ?? ''}';
  }

  List<String> _sampleNamesOf(Map<String, dynamic> inspection) => [
    for (final value in (inspection['sample_names'] as List? ?? const []))
      if ('$value'.trim().isNotEmpty) '$value'.trim(),
  ];
}
