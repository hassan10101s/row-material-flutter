import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../../../inspections/domain/inspection_repository.dart';
import '../../../inspections/presentation/cubit/inspection_detail_cubit.dart';
import '../../../inspections/presentation/detail/inspection_detail_screen.dart';
import '../../../reports/domain/report_repository.dart';
import '../../domain/lab_result_repository.dart';

/// Opens the inspection (المحضر) linked to a lab test row through its
/// `entry_code` — the same detail window the inspections ledger opens on a row
/// tap. The record is read back from the local database (the trusted channel),
/// never trusted from the row text; when the code is not on this device the
/// user gets a message instead of a broken screen.
Future<void> openLinkedInspection(
  BuildContext context,
  Map<String, dynamic> row,
) async {
  final code = '${row['entry_code'] ?? ''}'.trim();
  if (code.isEmpty) return;

  Map<String, dynamic>? inspection;
  try {
    final rows = await getIt<InspectionRepository>().list(query: code, limit: 50);
    for (final r in rows) {
      if ('${r['entry_code'] ?? ''}' == code) {
        inspection = r;
        break;
      }
    }
  } catch (_) {
    inspection = null;
  }
  if (!context.mounted) return;

  if (inspection == null) {
    AppFeedback.error(
      context,
      AppText.t(
        'هذا المحضر غير موجود على هذا الجهاز — قد يحتاج مزامنة',
        'Not on this device — it may need syncing',
      ),
    );
    return;
  }

  final id = (inspection['id'] as num).toInt();
  Widget screen(BuildContext c) => BlocProvider(
    create: (_) => InspectionDetailCubit(
      inspectionId: id,
      repo: getIt<InspectionRepository>(),
      reports: getIt<ReportRepository>(),
      labResults: getIt<LabResultRepository>(),
    )..load(),
    child: InspectionDetailScreen(inspectionId: id),
  );

  final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.medium;
  if (wide) {
    await showAppWindow<bool>(
      context,
      title: AppText.t('تفاصيل الفحص', 'Inspection Details'),
      icon: Icons.fact_check_outlined,
      size: AppWindowSize.lg,
      scrollBody: false,
      child: screen(context),
    );
  } else {
    await Navigator.of(context).push<bool>(
      AppPageRoute(builder: screen),
    );
  }
}
