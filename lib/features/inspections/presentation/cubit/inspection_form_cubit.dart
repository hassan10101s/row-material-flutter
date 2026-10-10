import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
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

  Future<void> loadMaterials() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final materials = await reference.listMaterials();
      _listKind = 'raw';
      safeEmit(state.copyWith(materials: materials, loading: false));
      await loadHistoryOptions();
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// Product catalog for the product-inspection form, mapped onto the same
  /// row shape the material picker consumes.
  Future<void> loadProducts() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final products = await reference.listProductsForInspection();
      _listKind = 'product';
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
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
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
    if (id == null || _listKind == 'product') {
      if (!isClosed) safeEmit(state.copyWith(supplierOptions: const []));
      return;
    }
    try {
      final suppliers = await repo.listSupplierHistory(materialId: id);
      if (isClosed) return;
      // The selection may have moved while loading; stale options for
      // another material must never surface.
      if (state.materialId == id) {
        safeEmit(state.copyWith(supplierOptions: suppliers));
      }
    } catch (_) {}
  }

  Future<void> selectMaterial(int id, {required String date}) async {
    try {
      final material = await reference.getMaterial(id, inspectionDate: date);
      safeEmit(state.copyWith(
        materialId: id,
        materialCode: '${material['material_code'] ?? ''}',
        entryCode: '${material['next_entry_code'] ?? ''}',
        physicalReference: _asMap(material['physical_reference']),
        chemicalReference: _asMap(material['chemical_reference']),
        refRevision: state.refRevision + 1,
        error: null,
      ));
      await loadSupplierOptions();
    } on AppError catch (e) {
      safeEmit(state.copyWith(error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(error: '$e'));
    }
  }

  /// Product counterpart of [selectMaterial]: the reference grids rebuild
  /// from the product's analysis ranges instead of the material catalog.
  Future<void> selectProduct(int id, {required String date}) async {
    try {
      final product =
          await reference.getProductForInspection(id, inspectionDate: date);
      safeEmit(state.copyWith(
        materialId: id,
        materialCode: '${product['product_code'] ?? ''}',
        entryCode: '${product['next_entry_code'] ?? ''}',
        physicalReference: _asMap(product['physical_reference']),
        chemicalReference: _asMap(product['chemical_reference']),
        refRevision: state.refRevision + 1,
        error: null,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(error: '$e'));
    }
  }

  Future<void> regenerateEntryCode(String date) async {
    try {
      final code = await reference.generateEntryCode(state.materialCode, date);
      safeEmit(state.copyWith(entryCode: code));
    } catch (e) {
      safeEmit(state.copyWith(error: '$e'));
    }
  }

  void setDecision(String decision) {
    safeEmit(state.copyWith(decision: decision));
  }

  /// Id of the inspection being edited, or null when creating.
  int? _editingId;

  /// True after [loadForEdit]: [save] updates instead of creating.
  bool get isEditing => _editingId != null;

  /// Prepares the form to edit [inspection] (a row as read from the repo,
  /// e.g. the detail screen's map): ensures the right catalog list is loaded
  /// (materials vs products by the row's kind), selects its material/product
  /// so the reference grids rebuild, restores its stored entry code
  /// (selection would mint a fresh one) and its decision. Field values
  /// themselves stay in the widget, which fills them once the grids rebuild.
  Future<void> loadForEdit(Map<String, dynamic> inspection) async {
    _editingId =
        int.tryParse('${inspection['id'] ?? ''}');
    final date = '${inspection['inspection_date'] ?? ''}';
    if ('${inspection['inspection_kind'] ?? 'raw'}' == 'product') {
      if (_listKind != 'product') await loadProducts();
      final productId =
          int.tryParse('${inspection['product_id'] ?? ''}');
      if (productId != null) {
        await selectProduct(productId, date: date);
        if (!isClosed) {
          safeEmit(state.copyWith(
            entryCode: '${inspection['entry_code'] ?? ''}',
            decision: '${inspection['decision_status'] ?? 'APPROVED'}',
          ));
        }
      } else if (!isClosed) {
        safeEmit(state.copyWith(
          decision: '${inspection['decision_status'] ?? 'APPROVED'}',
        ));
      }
      return;
    }
    if (_listKind != 'raw') await loadMaterials();
    final materialId =
        int.tryParse('${inspection['material_id'] ?? ''}');
    if (materialId != null) {
      await selectMaterial(materialId, date: date);
      if (!isClosed) {
        safeEmit(state.copyWith(
          entryCode: '${inspection['entry_code'] ?? ''}',
          decision: '${inspection['decision_status'] ?? 'APPROVED'}',
        ));
      }
    } else if (!isClosed) {
      safeEmit(state.copyWith(
        decision: '${inspection['decision_status'] ?? 'APPROVED'}',
      ));
    }
  }

  /// Clears the selected material (returns the material picker to search mode).
  void clearMaterial() {
    safeEmit(state.copyWith(
      materialId: null,
      materialCode: '',
      entryCode: '',
      physicalReference: const {},
      chemicalReference: const {},
      supplierOptions: const [],
      refRevision: state.refRevision + 1,
    ));
  }

  /// Persists the inspection. Creates, or updates the [loadForEdit] row when
  /// editing. Returns `true` when saved (caller navigates back).
  Future<bool> save(Map<String, dynamic> payload, UserContext userContext) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final editingId = _editingId;
      if (editingId != null) {
        await repo.update(editingId, payload, userContext);
      } else {
        await repo.create(payload, userContext);
      }
      return true;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
      return false;
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
      return false;
    } finally {
      safeEmit(state.copyWith(saving: false));
    }
  }

  static Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
}