import 'package:flutter/services.dart';

/// Camera permission through the app's own Android channel
/// (`MainActivity`, `material_lab/qr_camera`) — framework APIs only, no
/// third-party plugin.
///
/// This exists because the usual permission plugin ships a Windows
/// implementation that downloads a NuGet package at build time and breaks
/// `flutter run` on Windows. The scanner is Android-only anyway, so a tiny
/// first-party channel is the whole requirement.
///
/// Every method fails closed (`false` / no-op) off Android — including widget
/// tests with no plugin host — so callers never need platform branches.
class QrCameraPermission {
  QrCameraPermission._();

  static const MethodChannel _channel =
      MethodChannel('material_lab/qr_camera');

  /// True when the camera may be used. Shows the one-time system dialog when
  /// the permission is still undetermined; callers invoke this only from the
  /// QR scanner, never at app start.
  static Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True when the user denied with "don't ask again": the next step is the
  /// system settings screen, not another request (which Android would
  /// silently drop).
  static Future<bool> get permanentlyDenied async {
    try {
      return await _channel.invokeMethod<String>('check') ==
          'permanentlyDenied';
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's page in the system settings.
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } catch (_) {}
  }
}
