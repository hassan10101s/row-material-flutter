import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../reports/data/report_service.dart';
import '../../data/inspection_repo.dart';
import 'inspection_detail_state.dart';

/// Loads a single inspection for the detail screen and drives PDF exports.
/// Delete/decision errors are surfaced by the caller via app feedback.
class InspectionDetailCubit extends AppCubit<InspectionDetailState> {
  InspectionDetailCubit({
    required this.inspectionId,
    required this.repo,
    required this.reports,
  }) : super(const InspectionDetailState());

  final int inspectionId;
  final InspectionRepo repo;
  final ReportService reports;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final inspection = await repo.getById(inspectionId);
      safeEmit(state.copyWith(
        loading: false,
        inspection: inspection,
        history: List<Map<String, dynamic>>.from(inspection['status_history'] ?? []),
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// Returns the saved PDF path. Errors rethrow so the caller can show a
  /// snackbar without disturbing the detail layout.
  Future<String?> exportPdf(String kind) async {
    safeEmit(state.copyWith(busy: kind));
    try {
      final doc = kind == 'label'
          ? await reports.sampleLabelPdf(inspectionId)
          : await reports.inspectionReport(inspectionId);
      final date = parseIsoDate('${state.inspection?['inspection_date'] ?? ''}');
      final file = await reports.saveReport(doc, date: date);
      return file.path;
    } finally {
      safeEmit(state.copyWith(busy: ''));
    }
  }

  Future<void> delete() => repo.delete(inspectionId);
}