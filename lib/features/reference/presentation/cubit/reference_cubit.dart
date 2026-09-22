import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/reference_repo.dart';
import 'reference_state.dart';

/// Loads the reference materials catalog for the Reference screen.
class ReferenceCubit extends AppCubit<ReferenceState> {
  ReferenceCubit({required this.repo}) : super(const ReferenceState());

  final ReferenceRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final materials = await repo.listMaterials();
      safeEmit(state.copyWith(loading: false, materials: materials));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> update(int id, {required String name, required String code}) async {
    await repo.updateMaterial(id, materialName: name, materialCode: code);
    await load();
  }
}