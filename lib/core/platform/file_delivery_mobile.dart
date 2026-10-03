import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'file_delivery.dart';

/// Android implementation.
///
/// The sandbox is unreachable by a file manager, so *revealing the containing
/// folder* has no equivalent: instead the single file is handed to a viewer,
/// and the share sheet is the real escape hatch out of the sandbox.
class MobileFileDelivery implements FileDelivery {
  const MobileFileDelivery();

  @override
  bool get canReveal => true;

  @override
  bool get canShare => true;

  @override
  Future<bool> reveal(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      final result = await OpenFilex.open(filePath);
      return result.type == ResultType.done;
    } on Object {
      // No handler installed for this MIME type is a normal outcome on a
      // device, not an error worth surfacing.
      return false;
    }
  }

  @override
  Future<bool> share(String filePath, {String? subject}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          subject: subject,
        ),
      );
      return true;
    } on Object {
      return false;
    }
  }
}
