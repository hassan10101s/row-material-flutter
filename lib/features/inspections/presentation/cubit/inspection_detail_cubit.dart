import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../reports/domain/report_repository.dart';
import '../../../lab/domain/lab_result_repository.dart';
import '../../domain/inspection_repository.dart';
import 'inspection_detail_state.dart';

/// Loads a single inspection for the detail screen and drives PDF exports.
/// Delete/decision errors are surfaced by the caller via app feedback.
class InspectionDetailCubit extends AppCubit<InspectionDetailState> {
  InspectionDetailCubit({
    required this.inspectionId,
    required this.repo,
    required this.reports,
    this.labResults,
  }) : super(const InspectionDetailState());

  final int inspectionId;
  final InspectionRepository repo;
  final ReportRepository reports;
  final LabResultRepository? labResults;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      // Fetch the inspection row first (need entry_code), then load
      // status history (already inside getById) + lab tests in parallel
      // where possible. getById = row + history (1+1, expected on detail).
      final inspection = await repo.getById(inspectionId);
      final entryCode = '${inspection['entry_code'] ?? ''}'.trim();
      // History already included; only the lab enrichment is extra.
      List<Map<String, dynamic>> chemicalAnalyses = const [];
      if (entryCode.isNotEmpty && labResults != null) {
        chemicalAnalyses =
            await labResults!.listSampleTestsForEntryCode(entryCode);
      }
      safeEmit(state.copyWith(
        loading: false,
        inspection: inspection,
        history: List<Map<String, dynamic>>.from(inspection['status_history'] ?? []),
        chemicalAnalyses: chemicalAnalyses,
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