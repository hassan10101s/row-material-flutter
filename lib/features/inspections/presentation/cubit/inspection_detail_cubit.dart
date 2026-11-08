import '../../../../core/security/secure_field_access.dart';
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
    this.secureAccess,
  }) : super(const InspectionDetailState()) {
    refreshOnSync(load);
    secureAccess?.addListener(_privacyChanged);
  }

  final SecureFieldAccess? secureAccess;
  void _privacyChanged() {
    if (state.inspection != null) {
      safeEmit(
        state.copyWith(
          inspection: SecureFieldAccess.publicRecord(state.inspection!),
          chemicalAnalyses: [
            for (final r in state.chemicalAnalyses)
              if (r['secure_result'] != 1) SecureFieldAccess.publicRecord(r),
          ],
        ),
      );
    }
    load();
  }

  @override
  Future<void> close() {
    secureAccess?.removeListener(_privacyChanged);
    return super.close();
  }

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
      var inspection = await repo.getById(inspectionId);
      if (secureAccess != null) {
        inspection = await secureAccess!.reveal('sample', inspection);
      }
      final entryCode = '${inspection['entry_code'] ?? ''}';
      // History already included; only the lab enrichment is extra.
      List<Map<String, dynamic>> chemicalAnalyses = const [];
      if (entryCode.trim().isNotEmpty && labResults != null) {
        chemicalAnalyses = await labResults!.listSampleTestsForEntryCode(
          entryCode,
        );
      }
      safeEmit(
        state.copyWith(
          loading: false,
          inspection: secureAccess?.enabled == true
              ? inspection
              : SecureFieldAccess.publicRecord(inspection),
          history: List<Map<String, dynamic>>.from(
            inspection['status_history'] ?? [],
          ),
          chemicalAnalyses: chemicalAnalyses,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  /// Returns the saved PDF path. Errors rethrow so the caller can show a
  /// snackbar without disturbing the detail layout.
  Future<String?> exportPdf(String kind) async {
    safeEmit(state.copyWith(busy: kind));
    try {
      final doc = kind == 'label'
          ? await reports.sampleLabelPdf(inspectionId)
          : kind == 'detailed'
          ? await reports.inspectionReport(
              inspectionId,
              includeAnalysisDetails: true,
            )
          : await reports.inspectionReport(inspectionId);
      final date = parseIsoDate(
        '${state.inspection?['inspection_date'] ?? ''}',
      );
      final file = await reports.saveReport(doc, date: date);
      return file.path;
    } finally {
      safeEmit(state.copyWith(busy: ''));
    }
  }

  Future<void> delete() => repo.delete(inspectionId);
}
