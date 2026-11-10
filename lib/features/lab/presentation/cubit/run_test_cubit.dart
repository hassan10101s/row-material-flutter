import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/constants/app_strings.dart';
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
    this.editRow,
  }) : super(const RunTestState());

  final LabConfigurationRepository config;
  final LabResultRepository results;
  final LabLocalRepository local;

  /// When non-null the cubit drives an *edit* of this existing
  /// `lab_sample_tests` row instead of a new run: the analysis and source are
  /// history and stay fixed, only sample/result/dynamic values are re-saved.
  final Map<String, dynamic>? editRow;

  // Invalidate both successful and failed reads when the source changes.
  int _selectionRequest = 0;
  int _entryLookup = 0;

  bool get isEditing => editRow != null;

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
      final row = editRow;
      if (row == null) {
        safeEmit(
          state.copyWith(
            loading: false,
            analyses: analyses,
            products: products,
            rawMaterials: rawMaterials,
            analysisId: analysisId,
          ),
        );
        return;
      }
      // Edit mode: point the (fixed) form at the row's analysis/source and
      // resolve its linked inspection so the sample picker mirrors a run.
      analysisId = int.tryParse('${row['analysis_id'] ?? ''}') ?? analysisId;
      final sourceType = '${row['source_type'] ?? 'raw_material'}';
      final sourceName = '${row['source_name'] ?? ''}';
      final refId = int.tryParse('${row['source_ref_id'] ?? ''}');
      var sampleName = '${row['sample_name'] ?? ''}'.trim();
      var inspection = <String, dynamic>{};
      var inspections = <Map<String, dynamic>>[];
      final entry = '${row['entry_code'] ?? ''}'.trim();
      if (refId != null && refId > 0) {
        inspections = sourceType == 'product'
            ? await local.listProductInspectionRecords(refId)
            : await local.listInspectionRecords(refId);
        if (entry.isNotEmpty) {
          inspection =
              inspections
                  .where((r) => '${r['entry_code'] ?? ''}' == entry)
                  .firstOrNull ??
              const {};
          if (sampleName.isEmpty && inspection.isNotEmpty) {
            final samples = _sampleNamesOf(inspection);
            if (samples.isNotEmpty) sampleName = samples.first;
          }
        }
      }
      safeEmit(
        state.copyWith(
          loading: false,
          analyses: analyses,
          products: products,
          rawMaterials: rawMaterials,
          analysisId: analysisId,
          sourceType: sourceType,
          sourceName: sourceName,
          rawMaterialId: sourceType == 'product' ? null : refId,
          productId: sourceType == 'product' ? refId : null,
          inspections: inspections,
          selectedInspection: inspection,
          selectedSampleName: sampleName,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  void selectAnalysis(int id) {
    if (id == state.analysisId) return;
    safeEmit(state.copyWith(analysisId: id));
  }

  /// `copyWith` cannot null a field (`?? this.x`), so clears build the state
  /// explicitly. Without these, the autocomplete pickers lock on their first
  /// committed value (read-only + no clear button) and the user can never
  /// pick another analysis/material/record for the next test.
  void clearAnalysis() {
    if (state.analysisId == null) return;
    safeEmit(
      RunTestState(
        loading: state.loading,
        error: state.error,
        analyses: state.analyses,
        products: state.products,
        rawMaterials: state.rawMaterials,
        inspections: state.inspections,
        sourceType: state.sourceType,
        sourceName: state.sourceName,
        rawMaterialId: state.rawMaterialId,
        selectedInspection: state.selectedInspection,
        selectedSampleName: state.selectedSampleName,
        productId: state.productId,
        loadingInspections: state.loadingInspections,
        running: state.running,
      ),
    );
  }

  void clearRawMaterial() {
    if (state.rawMaterialId == null) return;
    _selectionRequest++;
    safeEmit(
      RunTestState(
        loading: state.loading,
        error: state.error,
        analyses: state.analyses,
        products: state.products,
        rawMaterials: state.rawMaterials,
        sourceType: state.sourceType,
        sourceName: '',
        selectedSampleName: '',
        productId: state.productId,
        analysisId: state.analysisId,
        loadingInspections: false,
        running: state.running,
      ),
    );
  }

  void clearProduct() {
    if (state.productId == null) return;
    _selectionRequest++;
    safeEmit(
      RunTestState(
        loading: state.loading,
        error: state.error,
        analyses: state.analyses,
        products: state.products,
        rawMaterials: state.rawMaterials,
        sourceType: state.sourceType,
        sourceName: '',
        rawMaterialId: state.rawMaterialId,
        selectedSampleName: '',
        analysisId: state.analysisId,
        loadingInspections: false,
        running: state.running,
      ),
    );
  }

  void clearInspection() {
    if (state.selectedInspection.isEmpty) return;
    _selectionRequest++;
    safeEmit(
      state.copyWith(selectedInspection: const {}, selectedSampleName: ''),
    );
  }

  void clearInspectionSample() {
    if (state.selectedSampleName.isEmpty) return;
    safeEmit(state.copyWith(selectedSampleName: ''));
  }

  void setSourceType(String type) {
    if (type == state.sourceType) return;
    _selectionRequest++;
    safeEmit(
      RunTestState(
        loading: state.loading,
        analyses: state.analyses,
        products: state.products,
        rawMaterials: state.rawMaterials,
        analysisId: state.analysisId,
        sourceType: type,
        running: state.running,
      ),
    );
  }

  /// Product path mirrors the raw-material path: picking a product loads
  /// its product-inspection records, then a record and one of its samples.
  Future<void> selectProduct(int id) async {
    if (id == state.productId && state.inspections.isNotEmpty) return;
    final request = ++_selectionRequest;
    safeEmit(
      state.copyWith(
        productId: id,
        sourceName: _productName(id),
        inspections: const [],
        selectedInspection: const {},
        selectedSampleName: '',
        loadingInspections: true,
        error: null,
      ),
    );
    try {
      final inspections = await local.listProductInspectionRecords(id);
      if (request != _selectionRequest) return;
      safeEmit(
        state.copyWith(inspections: inspections, loadingInspections: false),
      );
    } on AppError catch (e) {
      if (request != _selectionRequest) return;
      safeEmit(
        state.copyWith(loadingInspections: false, error: AppError.friendly(e)),
      );
    } catch (e) {
      if (request != _selectionRequest) return;
      safeEmit(
        state.copyWith(loadingInspections: false, error: AppError.friendly(e)),
      );
    }
  }

  Future<void> selectRawMaterial(int materialId) async {
    final request = ++_selectionRequest;
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
      if (request != _selectionRequest) return;
      safeEmit(
        state.copyWith(inspections: inspections, loadingInspections: false),
      );
    } on AppError catch (e) {
      if (request != _selectionRequest) return;
      safeEmit(
        state.copyWith(loadingInspections: false, error: AppError.friendly(e)),
      );
    } catch (e) {
      if (request != _selectionRequest) return;
      safeEmit(
        state.copyWith(loadingInspections: false, error: AppError.friendly(e)),
      );
    }
  }

  void selectInspection(int inspectionId) {
    final inspection = state.inspections
        .where((row) => '${row['id']}' == '$inspectionId')
        .firstOrNull;
    if (inspection == null) return;
    _selectionRequest++;
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

  /// Resolves an inspection by entry code (QR scan or manual lookup).
  ///
  /// Returns true when found and points the form at the resolved record
  /// (source name, material and inspection); false leaves state untouched
  /// so the caller can report "unknown code".
  Future<bool> lookupEntry(String code) async {
    final request = _selectionRequest;
    final lookup = ++_entryLookup;
    final row = await local.resolveInspection(code.trim());
    if (request != _selectionRequest || lookup != _entryLookup) return false;
    if (row == null) return false;
    _selectionRequest++;
    final samples = _sampleNamesOf(row);
    final isProduct = '${row['inspection_kind'] ?? 'raw'}' == 'product';
    safeEmit(
      state.copyWith(
        sourceName: '${row['material_name'] ?? ''}',
        sourceType: isProduct ? 'product' : 'raw_material',
        rawMaterialId: isProduct
            ? null
            : int.tryParse('${row['material_id'] ?? ''}'),
        productId: isProduct
            ? int.tryParse('${row['product_id'] ?? ''}')
            : null,
        inspections: [row],
        loadingInspections: false,
        error: null,
        selectedInspection: row,
        selectedSampleName: samples.isEmpty ? '' : samples.first,
      ),
    );
    return true;
  }

  /// Runs the sample test. On success returns the result payload (test,
  /// consumption, range check, etc.) so the caller can render the dialog.
  /// Errors rethrow; the running flag is cleared in finally.
  ///
  /// [sampleName]: an explicitly typed name wins; empty falls back to the
  /// record's selected sample (raw materials) or is sent as-is (products).
  /// The sample field is only shown for products, so raw-material callers
  /// pass '' and keep today's record-driven behaviour.
  /// [entryCode]: explicit code wins (QR/manual lookup); empty falls back
  /// to the selected inspection's code.
  Future<Map<String, dynamic>> run({
    required String sampleName,
    required String resultText,
    required Map<String, dynamic> dynamicValues,
    bool manualResult = false,
    Map<String, dynamic>? user,
    String? entryCode,
    bool draftOnly = false,
  }) async {
    if (state.analysisId == null) {
      throw ValidationError(
        AppText.t('اختر التحليل أولًا.', 'Select an analysis first.'),
      );
    }
    safeEmit(state.copyWith(running: true, error: null));
    try {
      final isProduct = state.sourceType == 'product';
      final isSample = state.sourceType == 'sample';
      final typed = sampleName.trim();
      // A free-text sample is its own source: the source name mirrors the
      // typed sample name and there is no catalog row to reference.
      final effectiveSample = typed.isEmpty ? state.selectedSampleName : typed;
      final sourceName = isSample
          ? effectiveSample
          : isProduct
          ? '${state.selectedInspection['material_name'] ?? _productName(state.productId)}'
          : '${state.selectedInspection['material_name'] ?? state.sourceName}';
      final resolvedEntry = (entryCode ?? '').trim();
      // Both paths are record-driven now: an explicitly typed sample name
      // wins, otherwise the record's selected sample; same for the entry code.
      final effectiveEntry = resolvedEntry.isNotEmpty
          ? resolvedEntry
          : '${state.selectedInspection['entry_code'] ?? ''}';
      return await results.runSampleTest(
        analysisId: state.analysisId!,
        sourceType: state.sourceType,
        sourceRefId: isSample
            ? null
            : isProduct
            ? state.productId
            : state.rawMaterialId,
        sourceName: sourceName,
        sampleName: effectiveSample,
        resultText: resultText.trim(),
        dynamicValues: dynamicValues,
        user: user,
        entryCode: effectiveEntry,
        manualResult: manualResult,
        draftOnly: draftOnly,
      );
    } finally {
      safeEmit(state.copyWith(running: false));
    }
  }

  /// Saves an *edit* of [editRow]: only the fillable fields travel (sample,
  /// result and dynamic values) — the analysis, source and entry code are
  /// history and never change. Corrected dynamic values re-derive the stock
  /// consumption through the same delta pipeline as a run.
  Future<Map<String, dynamic>> saveEdit({
    required String sampleName,
    required String resultText,
    required Map<String, dynamic> dynamicValues,
    Map<String, dynamic>? user,
    bool updateBasicDetails = false,
  }) async {
    final id = int.tryParse('${editRow?['id'] ?? ''}');
    if (id == null) throw const AppError('تعذّر حفظ التعديل');
    safeEmit(state.copyWith(running: true, error: null));
    try {
      return await results.updateSampleTest(
        id,
        analysisId: updateBasicDetails ? state.analysisId : null,
        sourceType: updateBasicDetails ? state.sourceType : null,
        sourceRefId: updateBasicDetails
            ? state.sourceType == 'sample'
                  ? null
                  : state.sourceType == 'product'
                  ? state.productId
                  : state.rawMaterialId
            : null,
        sourceName: updateBasicDetails
            ? state.sourceType == 'sample'
                  ? sampleName.trim()
                  : state.selectedInspection['material_name'] ??
                        state.sourceName
            : null,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        user: user,
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
