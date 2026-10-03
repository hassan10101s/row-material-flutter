import 'package:file_picker/file_picker.dart';

/// Choosing a folder on disk.
///
/// ## Why this is a port
///
/// Android has no folder picker, and `WRITE_EXTERNAL_STORAGE` is deliberately
/// not declared (see the manifest): exports and evidence belong in the app
/// sandbox. So the honest mobile answer is "there is nothing to pick", and the
/// interesting behaviour is [supported]. A screen that offers folder picking
/// unconditionally ends up with a button that opens a dialog and then does
/// nothing, which is worse than not having the button.
abstract interface class FolderPicker {
  /// Whether a folder can be chosen at all on this platform.
  bool get supported;

  /// Returns the chosen path, or null when cancelled or unsupported.
  Future<String?> pick({String? startDirectory, String? dialogTitle});
}

/// Desktop implementation, backed by the native directory chooser.
class DesktopFolderPicker implements FolderPicker {
  const DesktopFolderPicker();

  @override
  bool get supported => true;

  @override
  Future<String?> pick({String? startDirectory, String? dialogTitle}) async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
        initialDirectory: startDirectory,
      );
      final path = result?.trim();
      return (path == null || path.isEmpty) ? null : path;
    } on Object {
      return null;
    }
  }
}

/// Mobile implementation. Always null - see [supported].
class UnsupportedFolderPicker implements FolderPicker {
  const UnsupportedFolderPicker();

  @override
  bool get supported => false;

  @override
  Future<String?> pick({String? startDirectory, String? dialogTitle}) async =>
      null;
}
