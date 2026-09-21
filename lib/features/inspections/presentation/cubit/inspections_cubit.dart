import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../reports/data/report_service.dart';
import '../../data/inspection_repo.dart';
import 'inspections_state.dart';

/// Inspections ledger: loads rows and maintains the client-side query/status
/// filters and the follow-up report export flag.
class InspectionsCubit extends AppCubit<InspectionsState> {
  InspectionsCubit({required this.repo, required this.reports})
      : super(const InspectionsState());

  final InspectionRepo repo;
  final ReportService reports;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.list(orderBy: 'inspection_date DESC, id DESC');
      safeEmit(state.copyWith(
        rows: rows,
        visible: _filtered(rows, state.query, state.status),
        loading: false,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  void setQuery(String query) {
    safeEmit(state.copyWith(query: query));
    safeEmit(state.copyWith(visible: _filtered(state.rows, query, state.status)));
  }

  void setStatus(String status) {
    safeEmit(state.copyWith(status: status));
    safeEmit(state.copyWith(visible: _filtered(state.rows, state.query, status)));
  }

  /// Returns the saved report path, or `null` when there is nothing to export.
  /// Export errors are surfaced by the caller (they are not ledger errors).
  Future<String?> exportFollowUp() async {
    final visible = state.visible;
    if (visible.isEmpty) return null;
    safeEmit(state.copyWith(exporting: true));
    try {
      final doc = await reports.followUpReport([
        for (final r in visible) (r['id'] as num).toInt(),
      ]);
      final file = await reports.saveReport(doc);
      return file.path;
    } finally {
      safeEmit(state.copyWith(exporting: false));
    }
  }

  static List<Map<String, dynamic>> _filtered(
    List<Map<String, dynamic>> rows,
    String query,
    String status,
  ) {
    final q = query.trim().toLowerCase();
    final list = q.isEmpty
        ? rows
        : [
            for (final r in rows)
              if ('${r['entry_code']}'.toLowerCase().contains(q) ||
                  '${r['material_name']}'.toLowerCase().contains(q) ||
                  '${r['supplier']}'.toLowerCase().contains(q) ||
                  '${r['truck_number']}'.toLowerCase().contains(q))
                r,
          ];
    return status.isEmpty
        ? list
        : [for (final r in list) if ('${r['decision_status']}' == status) r];
  }
}