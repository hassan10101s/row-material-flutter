import 'package:flutter/widgets.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import '../domain/lab_local_repository.dart';
import 'desktop/constants_tab.dart';
import 'mobile/constants_tab.dart';

/// Global-constant management.
///
/// The first feature to be split, and the shape every later split should copy:
/// this file holds *no* UI at all, only the dispatch. The desktop experience is
/// the pre-split screen verbatim; the mobile experience is a card list. Both
/// share their fields and their save path through `constants_editor.dart`, so
/// the two can only diverge in layout - never in behaviour.
///
/// The repository is a required parameter rather than a `getIt` lookup. The
/// variants sit below this host, so injecting here is what lets both be given
/// the same instance - and it is the shape the remaining features need when
/// their `getIt` calls come out of `build`.
class ConstantsTab extends StatelessWidget {
  const ConstantsTab({super.key, required this.repo});

  final LabLocalRepository repo;

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => DesktopConstantsTab(repo: repo),
    mobile: (_) => MobileConstantsTab(repo: repo),
  );
}
