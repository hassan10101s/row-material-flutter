import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../reference/data/reference_repo.dart';
import '../../data/inspection_repo.dart';
import 'inspection_form_state.dart';

/// Drives the inspectable data behind the new-inspection form: material
/// loading/selection (rebuilding the result grids via [InspectionFormState/
/// refRevision]) and the save flow. Text-field controllers stay in the widget.
class InspectionFormCubit extends AppCubit<InspectionFormState> {
  InspectionFormCubit({required this.repo, required this.reference})
      : super(const InspectionFormState());

  final InspectionRepo repo;
  final ReferenceRepo reference;

  Future<void> loadMaterials() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final materials = await reference.listMaterials();
      safeEmit(state.copyWith(materials: materials, loading: false));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
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

  /// Clears the selected material (returns the material picker to search mode).
  void clearMaterial() {
    safeEmit(state.copyWith(
      materialId: null,
      materialCode: '',
      entryCode: '',
      physicalReference: const {},
      chemicalReference: const {},
      refRevision: state.refRevision + 1,
    ));
  }

  /// Persists the inspection. Returns `true` when saved (caller navigates back).
  Future<bool> save(Map<String, dynamic> payload, UserContext userContext) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.create(payload, userContext);
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