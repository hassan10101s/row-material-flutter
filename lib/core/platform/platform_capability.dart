import 'dart:io';

import 'package:flutter/foundation.dart';

/// Single source of truth for "what can this build do?".
///
/// Replaces scattered `Platform.isAndroid || Platform.isIOS` checks so a new
/// platform (MSIX-packaged Windows, plain EXE, Android, iOS) only changes one
/// file. Desktop = Windows/Linux/macOS. Mobile = Android/iOS. Web never has
/// native plugins.
///
/// Parity rule: every capability has a UI affordance rule — call sites must
/// *hide* the button when the capability is false, not offer a tap that throws
/// `MissingPluginException`.
abstract final class PlatformCapability {
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isWindowsNoWeb => !kIsWeb && Platform.isWindows;

  /// Camera capture (`image_picker` camera source). No Windows registrant —
  /// always false on desktop. Use gallery/file pick instead.
  static bool get canCaptureCamera => isMobile;

  /// QR live scan (`mobile_scanner`). No Windows registrant.
  static bool get canScanQr => isMobile;

  /// Background periodic work (`workmanager`). Android-only.
  static bool get canScheduleBackground => !kIsWeb && Platform.isAndroid;

  /// OS notifications (`flutter_local_notifications`). Mobile-only.
  static bool get canNotifyOs => isMobile;

  /// Reveal file in Explorer/Finder. Desktop-only (mobile sandbox is hidden).
  static bool get canRevealFile => isDesktop;

  /// Google loopback sign-in on desktop needs a Desktop OAuth client id
  /// (`--dart-define GOOGLE_DESKTOP_CLIENT_ID`). When missing, UI must show
  /// the setup hint instead of attempting sign-in (redirect_uri_mismatch).
  static bool googleDesktopClientConfigured() {
    if (!isDesktop) return true;
    return const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID').isNotEmpty;
  }
}
