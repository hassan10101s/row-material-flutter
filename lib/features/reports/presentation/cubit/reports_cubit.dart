import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/report_repository.dart';
import 'reports_state.dart';

/// Runs daily/monthly/yearly PDF report jobs and tracks busy/result state.
class ReportsCubit extends AppCubit<ReportsState> {
  ReportsCubit({required this.repo}) : super(const ReportsState());

  final ReportRepository repo;

  Future<void> runDaily(String date) => _run('daily', () => repo.dailyReport(date));

  Future<void> runMonthly(int month, int year) =>
      _run('monthly', () => repo.monthlyReport(month: month, year: year));

  Future<void> runYearly(int year) => _run('yearly', () => repo.yearlyReport(year: year));

  Future<void> _run(String kind, Future<ReportDoc> Function() job) async {
    if (state.busy.isNotEmpty) return;
    safeEmit(state.copyWith(busy: kind, error: null, lastExport: null, lastExportTitle: null));
    try {
      final doc = await job();
      // The bytes alone are useless: without a file on disk the export sheet
      // can only offer a bare filename that no app can open. Persist first
      // (same pattern as the lab-reports cubit) and hand out the real path.
      final file = await repo.saveReport(doc);
      safeEmit(state.copyWith(
        busy: '',
        lastExport: file.path,
        lastExportTitle: doc.title,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(busy: '', error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(busy: '', error: '$e'));
    }
  }
}