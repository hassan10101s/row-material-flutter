import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/platform/file_delivery.dart';
import 'package:material_lab/core/platform/file_delivery_mobile.dart';

/// Folder-opening capability: only desktops can reveal the exports folder.
/// Phones keep file open/share, but a visible "open folder" button could
/// never succeed (sandbox), so it must stay hidden via [canRevealFolder].
void main() {
  test('mobile delivery opens/shares files but never folders', () {
    const delivery = MobileFileDelivery();
    expect(delivery.canReveal, isTrue);
    expect(delivery.canShare, isTrue);
    expect(delivery.canRevealFolder, isFalse);
  });

  test('desktop folder capability tracks file capability', () {
    const delivery = DesktopFileDelivery();
    expect(delivery.canRevealFolder, delivery.canReveal);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      expect(delivery.canRevealFolder, isTrue);
    }
  });

  test('unsupported delivery offers nothing', () {
    const delivery = UnsupportedFileDelivery();
    expect(delivery.canReveal, isFalse);
    expect(delivery.canRevealFolder, isFalse);
    expect(delivery.canShare, isFalse);
  });
}
