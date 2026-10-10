import 'package:flutter/widgets.dart';

import '../../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/params_tab.dart';
import 'mobile/params_tab.dart';

/// Parameter management.
///
/// Splits on [parameterType] only - which of the two aspects tabs this is - and
/// dispatches on the form factor. Both axes stay outside the variants so a
/// variant never has to know it is one of a pair.
class ParamsTab extends StatelessWidget {
  const ParamsTab({super.key, required this.parameterType});

  /// 'chemical' or 'physical'; physical rows are unit-less by design.
  final String parameterType;

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => DesktopParamsTab(parameterType: parameterType),
    mobile: (_) => MobileParamsTab(parameterType: parameterType),
  );
}
