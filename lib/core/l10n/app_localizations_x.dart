import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';

/// Convenience accessor for the active-app locale's UI strings.
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
