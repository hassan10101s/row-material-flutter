import 'dart:io';

import '../app/auto_backup_task.dart';
import '../core/platform/auto_backup_scheduler.dart';
import '../core/platform/file_delivery.dart';
import '../core/platform/file_delivery_mobile.dart';
import '../core/platform/folder_picker.dart';
import 'service_locator.dart' show getIt;

/// Resolving the platform ports from anywhere.
///
/// The registrations themselves live in [service_locator] — that is the single
/// place where the app decides which adapter each port gets. These helpers exist
/// for the paths where asking the locator is not safe:
///
///  * a widget test that builds a screen without a locator,
///  * an error path raised before `initServiceLocator` finished,
///  * a background isolate that only wires up part of the graph.
///
/// In all three cases a *missing* registration must not become a crash, because
/// every caller is a place that is already reporting something good to the user
/// ("your report is ready"). So these fall back to the adapter for the platform
/// actually running. A test that needs to control the behaviour registers a
/// double and gets it, which is the whole point of the ports.
///
/// [service_locator]: service_locator.dart
FileDelivery fileDelivery() {
  if (getIt.isRegistered<FileDelivery>()) return getIt<FileDelivery>();
  if (Platform.isAndroid || Platform.isIOS) return const MobileFileDelivery();
  return const DesktopFileDelivery();
}

FolderPicker folderPicker() {
  if (getIt.isRegistered<FolderPicker>()) return getIt<FolderPicker>();
  if (Platform.isAndroid || Platform.isIOS) {
    return const UnsupportedFolderPicker();
  }
  return const DesktopFolderPicker();
}

AutoBackupScheduler autoBackupScheduler() {
  if (getIt.isRegistered<AutoBackupScheduler>()) {
    return getIt<AutoBackupScheduler>();
  }
  if (Platform.isAndroid) return const AndroidBackupScheduler();
  return const NoopBackupScheduler();
}
