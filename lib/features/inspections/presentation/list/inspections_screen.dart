import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/constants/app_strings.dart';
import '../cubit/inspections_cubit.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/inspections_screen.dart';
import 'mobile/inspections_screen.dart';

/// Inspections ledger host: dispatch only, no UI.
///
/// Both variants share the cubit and the bulk-export sheet, so behaviour
/// can never diverge — only chrome: a selectable paginated table + dialogs
/// on desktop, cards + full-screen routes on phones.
class InspectionsScreen extends StatelessWidget {
  const InspectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final content = appAdaptiveVariant(
      context,
      desktop: (_) => const DesktopInspectionsScreen(),
      mobile: (_) => const MobileInspectionsScreen(),
    );
    if (!context.read<InspectionsCubit>().formulationReceiptsOnly) {
      return content;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            AppText.t(
              'محاضر التركيبات: قبول نهائي أو مبدئي مع المتابعة فقط',
              'Formulation receipts: final or conditional approval only',
            ),
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        Expanded(child: content),
      ],
    );
  }
}
