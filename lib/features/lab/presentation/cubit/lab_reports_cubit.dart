import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../reports/data/report_service.dart';
import 'lab_reports_state.dart';

/// Runs daily/monthly/yearly lab-test PDF exports via ReportService and
/// records busy/result state. One export at a time.
class LabReportsCubit extends AppCubit<LabReportsState> {
  LabReportsCubit({required this.reports}) : super(const LabReportsState());

  final ReportService reports;

  Future<void> runDaily(String date) =>
      _run('daily', () => reports.labReport(type: 'daily', dateStr: date));

  Future<void> runMonthly(int month, int year) => _run(
      'monthly', () => reports.labReport(type: 'monthly', month: month, year: year));

  Future<void> runYearly(int year) =>
      _run('yearly', () => reports.labReport(type: 'yearly', year: year));

  Future<void> _run(String kind, Future<ReportDoc> Function() job) async {
    if (state.busy.isNotEmpty) return;
    safeEmit(state.copyWith(busy: kind, error: null, lastExport: null));
    try {
      final doc = await job();
      final file = await reports.saveReport(doc);
      safeEmit(state.copyWith(busy: '', lastExport: file.path));
    } on AppError catch (e) {
      safeEmit(state.copyWith(busy: '', error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(busy: '', error: '$e'));
    }
  }
}