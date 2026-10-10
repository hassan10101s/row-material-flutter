import 'package:flutter/widgets.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/test_history_tab.dart';
import 'mobile/test_history_tab.dart';

/// Test-history host: dispatch only, no UI.
///
/// Reloads whenever [refreshTick] changes. Both variants share the cubit
/// and [TestHistoryScope] (filters/sort/page), so behaviour can never
/// diverge — only chrome: a 10-column sortable table on desktop, cards +
/// full-screen new-test route + filter bottom sheet on phones.
class TestHistoryTab extends StatelessWidget {
  final int refreshTick;
  const TestHistoryTab({super.key, this.refreshTick = 0});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => DesktopTestHistoryTab(refreshTick: refreshTick),
    mobile: (_) => MobileTestHistoryTab(refreshTick: refreshTick),
  );
}
