import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/commands/central_authoring_gateway.dart';
import '../../../reference/domain/reference_repository.dart';
import '../../domain/inspection_repository.dart';
import 'inspection_form_state.dart';

/// Drives the inspectable data behind the new-inspection form: material /
/// product loading/selection (rebuilding the result grids via
/// [InspectionFormState/ refRevision]) and the save flow. Text-field
/// controllers stay in the widget.
///
/// Product mode reuses the same state shape: [InspectionFormState.materials]
/// holds mapped product rows (`material_name`/`material_code`) and
/// [InspectionFormState.materialId] holds the selected product id, so the
/// pickers and grids work unchanged — only the source list and the reference
/// builder differ.
class InspectionFormCubit extends AppCubit<InspectionFormState> {
  InspectionFormCubit({required this.repo, required this.reference})
    : super(const InspectionFormState());

  final InspectionRepository repo;
  final ReferenceRepository reference;

  /// Which list [state.materials] currently holds (`raw`, `product` or '').
  String _listKind = '';
  int _catalogRequest = 0;
  int _selectionRequest = 0;
  int _entryCodeRequest = 0;
  String? _entryCodeDate;

  void _invalidateReferenceRequests() {
    _selectionRequest++;
    _entryCodeRequest++;
    _entryCodeDate = null;
  }

  bool _currentSelection(int request) =>
      !isClosed && !isEditing && request == _selectionRequest;

  void _selectionFailed(Object error) {
    safeEmit(
      state.copyWith(
        selectingReference: false,
        physicalReference: const {},
        chemicalReference: const {},
        refRevision: state.refRevision + 1,
        error: AppError.friendly(error),
      ),
    );
  }

  Future<String?> _selectionEntryCode(
    int request,
    String code,
    String materialCode,
    String date,
  ) async {
    var codeDate = date;
    while (_currentSelection(request) && _entryCodeDate != codeDate) {
      codeDate = _entryCodeDate ?? date;
      code = await reference.generateEntryCode(materialCode, codeDate);
    }
    return _currentSelection(request) ? code : null;
  }

  Future<void> loadMaterials() async {
    if (isEditing || isClosed) return;
    final request = ++_catalogRequest;
    _invalidateReferenceRequests();
    _listKind = 'raw';
    safeEmit(
      state.copyWith(
        loading: true,
        selectingReference: false,
        clearError: true,
      ),
    );
    try {
      final materials = await reference.listMaterials();
      if (isClosed || isEditing || request != _catalogRequest) return;
      safeEmit(state.copyWith(materials: materials, loading: false));
      await loadHistoryOptions();
    } on AppError catch (e) {
      if (isClosed || isEditing || request != _catalogRequest) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    } catch (e) {
      if (isClosed || isEditing || request != _catalogRequest) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  /// Product catalog for the product-inspection form, mapped onto the same
  /// row shape the material picker consumes.
  Future<void> loadProducts() async {
    if (isEditing || isClosed) return;
    final request = ++_catalogRequest;
    _invalidateReferenceRequests();
    _listKind = 'product';
    safeEmit(
      state.copyWith(
        loading: true,
        selectingReference: false,
        clearError: true,
      ),
    );
    try {
      final products = await reference.listProductsForInspection();
      if (isClosed || isEditing || request != _catalogRequest) return;
      safeEmit(
        state.copyWith(
          materials: [
            for (final p in products)
              {
                'id': p['id'],
                'material_name': '${p['name'] ?? ''}',
                'material_code': '${p['product_code'] ?? ''}',
              },
          ],
          loading: false,
        ),
      );
      await loadHistoryOptions();
    } on AppError catch (e) {
      if (isClosed || isEditing || request != _catalogRequest) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    } catch (e) {
      if (isClosed || isEditing || request != _catalogRequest) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  /// History autocomplete options (Vue parity): sample takers always
  /// (global technicians log); suppliers scoped to the selected material
  /// when one is picked. Never throws — an empty list simply means no
  /// suggestions; typing stays free.
  Future<void> loadHistoryOptions() async {
    try {
      final takers = await repo.listSampleTakerHistory();
      if (isClosed) return;
      safeEmit(state.copyWith(sampleTakerOptions: takers));
    } catch (_) {}
    await loadSupplierOptions();
  }

  Future<void> loadSupplierOptions() async {
    final id = state.materialId;
    final request = _selectionRequest;
    if (id == null || _listKind == 'product') {
      if (!isClosed) safeEmit(state.copyWith(supplierOptions: const []));
      return;
    }
    try {
      final suppliers = await repo.listSupplierHistory(materialId: id);
      if (isClosed) return;
      // The selection may have moved while loading; stale options for
      // another material must never surface.
      if (state.materialId == id &&
          request == _selectionRequest &&
          _listKind != 'product') {
        safeEmit(state.copyWith(supplierOptions: suppliers));
      }
    } catch (_) {}
  }

  Future<void> selectMaterial(int id, {required String date}) async {
    if (isEditing || isClosed) return;
    final request = ++_selectionRequest;
    _entryCodeRequest++;
    _entryCodeDate = date;
    safeEmit(
      state.copyWith(
        selectingReference: true,
        clearMaterialId: true,
        materialCode: '',
        entryCode: '',
        supplierOptions: const [],
        clearError: true,
      ),
    );
    try {
      final material = await reference.getMaterial(id, inspectionDate: date);
      if (!_currentSelection(request)) return;
      final code = await _selectionEntryCode(
        request,
        '${material['next_entry_code'] ?? ''}',
        '${material['material_code'] ?? ''}',
        date,
      );
      if (code == null || !_currentSelection(request)) return;
      safeEmit(
        state.copyWith(
          materialId: id,
          materialCode: '${material['material_code'] ?? ''}',
          entryCode: code,
          physicalReference: _asMap(material['physical_reference']),
          chemicalReference: _asMap(material['chemical_reference']),
          refRevision: state.refRevision + 1,
          selectingReference: false,
          clearError: true,
        ),
      );
      await loadSupplierOptions();
    } on AppError catch (e) {
      if (!_currentSelection(request)) return;
      _selectionFailed(e);
    } catch (e) {
      if (!_currentSelection(request)) return;
      _selectionFailed(e);
    }
  }

  /// Product counterpart of [selectMaterial]: the reference grids rebuild
  /// from the product's analysis ranges instead of the material catalog.
  Future<void> selectProduct(int id, {required String date}) async {
    if (isEditing || isClosed) return;
    final request = ++_selectionRequest;
    _entryCodeRequest++;
    _entryCodeDate = date;
    safeEmit(
      state.copyWith(
        selectingReference: true,
        clearMaterialId: true,
        materialCode: '',
        entryCode: '',
        supplierOptions: const [],
        clearError: true,
      ),
    );
    try {
      final product = await reference.getProductForInspection(
        id,
        inspectionDate: date,
      );
      if (!_currentSelection(request)) return;
      final code = await _selectionEntryCode(
        request,
        '${product['next_entry_code'] ?? ''}',
        '${product['product_code'] ?? ''}',
        date,
      );
      if (code == null || !_currentSelection(request)) return;
      safeEmit(
        state.copyWith(
          materialId: id,
          materialCode: '${product['product_code'] ?? ''}',
          entryCode: code,
          physicalReference: _asMap(product['physical_reference']),
          chemicalReference: _asMap(product['chemical_reference']),
          refRevision: state.refRevision + 1,
          selectingReference: false,
          clearError: true,
        ),
      );
    } on AppError catch (e) {
      if (!_currentSelection(request)) return;
      _selectionFailed(e);
    } catch (e) {
      if (!_currentSelection(request)) return;
      _selectionFailed(e);
    }
  }

  Future<void> regenerateEntryCode(String date) async {
    if (isEditing) return;
    _entryCodeDate = date;
    final request = ++_entryCodeRequest;
    if (state.selectingReference) return;
    final materialCode = state.materialCode;
    final materialId = state.materialId;
    try {
      final code = await reference.generateEntryCode(materialCode, date);
      if (request != _entryCodeRequest ||
          isEditing ||
          state.materialId != materialId ||
          state.materialCode != materialCode) {
        return;
      }
      safeEmit(state.copyWith(entryCode: code));
    } catch (e) {
      if (isClosed ||
          request != _entryCodeRequest ||
          isEditing ||
          state.materialId != materialId ||
          state.materialCode != materialCode) {
        return;
      }
      safeEmit(state.copyWith(error: AppError.friendly(e)));
    }
  }

  void setDecision(String decision) {
    safeEmit(state.copyWith(decision: decision));
  }

  /// Id of the inspection being edited, or null when creating.
  int? _editingId;

  /// True after [loadForEdit]: [save] updates instead of creating.
  bool get isEditing => _editingId != null;

  /// Editing uses the approved inspection's identity and reference snapshot.
  /// Never re-select from the current catalogue or mint another entry code:
  /// archived/unavailable catalogue rows must not erase an existing selection.
  Future<void> loadForEdit(Map<String, dynamic> inspection) async {
    _catalogRequest++;
    _invalidateReferenceRequests();
    _editingId = int.tryParse('${inspection['id'] ?? ''}');
    final product = '${inspection['inspection_kind'] ?? 'raw'}' == 'product';
    _listKind = product ? 'product' : 'raw';
    final selectedId = int.tryParse(
      '${inspection[product ? 'product_id' : 'material_id'] ?? ''}',
    );
    final code = '${inspection['material_code'] ?? ''}';
    safeEmit(
      state.copyWith(
        materials: [
          if (selectedId != null)
            {
              'id': selectedId,
              'material_name': '${inspection['material_name'] ?? ''}',
              'material_code': code,
            },
        ],
        materialId: selectedId,
        clearMaterialId: selectedId == null,
        materialCode: code,
        entryCode: '${inspection['entry_code'] ?? ''}',
        physicalReference: _asMap(inspection['physical_reference']),
        chemicalReference: _asMap(inspection['chemical_reference']),
        decision: '${inspection['decision_status'] ?? 'APPROVED'}',
        refRevision: state.refRevision + 1,
        loading: false,
        selectingReference: false,
        clearError: true,
      ),
    );
    await loadHistoryOptions();
  }

  /// Clears the selected material (returns the material picker to search mode).
  void clearMaterial() {
    if (isEditing) return;
    _invalidateReferenceRequests();
    safeEmit(
      state.copyWith(
        clearMaterialId: true,
        selectingReference: false,
        clearError: true,
        materialCode: '',
        entryCode: '',
        physicalReference: const {},
        chemicalReference: const {},
        supplierOptions: const [],
        refRevision: state.refRevision + 1,
      ),
    );
  }

  /// Persists the inspection. Creates, or updates the [loadForEdit] row when
  /// editing. Returns `true` when saved (caller navigates back).
  Future<bool> save(
    Map<String, dynamic> payload,
    UserContext userContext,
  ) async {
    if (state.selectingReference) return false;
    safeEmit(
      state.copyWith(saving: true, clearError: true, pendingApproval: false),
    );
    try {
      final editingId = _editingId;
      if (editingId != null) {
        await repo.update(editingId, payload, userContext);
      } else {
        await repo.create(payload, userContext);
      }
      return true;
    } on CentralDraftPending {
      // The durable draft/outbox row exists; leaving this form open invites a
      // duplicate submission. Close it like a saved form and distinguish the
      // pending approval in the confirmation feedback.
      safeEmit(
        state.copyWith(saving: false, clearError: true, pendingApproval: true),
      );
      return true;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(e)));
      return false;
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(e)));
      return false;
    } finally {
      safeEmit(state.copyWith(saving: false));
    }
  }

  static Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
}
