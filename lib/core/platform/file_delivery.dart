import 'dart:io';

/// Delivering a file that the app just produced.
///
/// ## Why this is a port
///
/// The app writes every report and backup into its own sandbox. On desktop that
/// folder is somewhere the user can browse, so the natural action is "reveal
/// it in Explorer". On a phone the same folder is
/// `/data/user/0/<pkg>/files/MaterialLab/exports/...`, which **no file manager
/// can reach** - the call cannot be made to work, it can only be replaced.
///
/// Rather than branching on `Platform.is*` at each call site, presentation asks
/// this port what it can do. [canReveal] is what lets a widget hide the
/// affordance entirely instead of offering a tap that goes nowhere.
abstract interface class FileDelivery {
  /// Whether [reveal] can succeed for a file on this platform.
  bool get canReveal;

  /// Whether [share] can succeed for a file on this platform.
  bool get canShare;

  /// Opens the containing folder of [filePath] in the platform file manager.
  ///
  /// Returns false rather than throwing when the launch is not possible, so a
  /// cosmetic failure never becomes an error dialog.
  Future<bool> reveal(String filePath);

  /// Hands [filePath] to the platform share sheet.
  Future<bool> share(String filePath, {String? subject});
}

/// Desktop implementation: reveal through the OS file manager, share through
/// the same desktop handler.
class DesktopFileDelivery implements FileDelivery {
  const DesktopFileDelivery();

  @override
  bool get canReveal => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  bool get canShare => true;

  @override
  Future<bool> reveal(String filePath) async {
    if (!canReveal) return false;
    final dir = File(filePath).parent;
    try {
      if (!await dir.exists()) return false;
      if (Platform.isWindows) {
        // `explorer.exe` returns a non-zero code when it hands the request to
        // an already-running instance, so the exit status is not a usable
        // success signal - treat a completed launch as success.
        await Process.run('explorer.exe', [dir.path]);
        return true;
      }
      if (Platform.isMacOS) {
        return (await Process.run('open', [dir.path])).exitCode == 0;
      }
      return (await Process.run('xdg-open', [dir.path])).exitCode == 0;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> share(String filePath, {String? subject}) =>
      reveal(filePath);
}

/// A delivery that does nothing.
///
/// Used on platforms where neither reveal nor share is wired up yet, and in
/// tests. Reporting `false` for both capabilities is what makes the call sites
/// hide the button, which is the correct outcome - a visible control that does
/// nothing is worse than no control.
class UnsupportedFileDelivery implements FileDelivery {
  const UnsupportedFileDelivery();

  @override
  bool get canReveal => false;

  @override
  bool get canShare => false;

  @override
  Future<bool> reveal(String filePath) async => false;

  @override
  Future<bool> share(String filePath, {String? subject}) async => false;
}
