import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lets the app drive the native window's own chrome.
///
/// `MaterialApp.title` is a Dart-side string. With the stock Windows runner
/// nothing carries it across to the OS, so the title bar kept showing the
/// build's `material_lab` while the app branded itself "Material Lab", and
/// flipping the in-app light/dark toggle left a light title bar framing a dark
/// app. Both are corrected here.
///
/// Every method is a no-op on platforms with no runner behind them, and every
/// failure is swallowed, because a window that refuses to retitle is a cosmetic
/// problem and must never take the app down with it.
class WindowChrome {
  const WindowChrome();

  /// Must match `FlutterWindow::kWindowChannelName` in
  /// `windows/runner/flutter_window.cpp`.
  static const MethodChannel _channel = MethodChannel('material_lab/window');

  /// Sets the native title bar text.
  Future<void> setTitle(String title) async {
    if (title.isEmpty) return;
    await _invoke('setTitle', {'title': title});
  }

  /// Forces the title bar's light or dark appearance, or [null] to hand
  /// control back to the operating system.
  ///
  /// Pass `null` under `ThemeMode.system`: the OS registry value is the right
  /// answer there, and pinning it would stop the title bar following a
  /// system-wide theme change.
  Future<void> setDarkMode(bool? dark) async {
    await _invoke('setDarkMode', {'dark': dark});
  }

  /// Convenience for the brightness the app has actually resolved.
  Future<void> applyBrightness(Brightness brightness) =>
      setDarkMode(brightness == Brightness.dark);

  /// Whether this platform has a runner that understands the channel.
  ///
  /// Android and iOS have their own task-switcher naming, which is managed by
  /// the OS, so the calls are pointless there.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      // A stale runner (rebuilt binary, older channel) surfaces here.
      debugPrint('WindowChrome.$method failed: ${error.message}');
    } on MissingPluginException {
      // No handler registered on this build. Cosmetic only.
    }
  }
}
