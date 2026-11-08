import 'dart:convert';
import 'dart:io';

import '../../../core/app_paths.dart';
import '../../../di/service_locator.dart';

/// Local graph view preferences per formulation.
///
/// Deliberately NOT part of the formulation record: these are cosmetic UI
/// choices (period window, aggregation, chart interval, source filter,
/// selected curves, donut parameter). They never enter the command/sync
/// protocol, the outbox or the audit stack — one JSON file per organization,
/// rewritten only when the user actually moves a graph control so the chart
/// always reopens exactly as it was left.
class FormulationViewPrefs {
  const FormulationViewPrefs._();

  static const String _fileName = 'formulation_view_prefs.json';
  static Future<void>? _writes;

  static String _key(int id, String? userId) => jsonEncode([userId ?? '', id]);

  /// Stored preferences of one formulation, or null when none exist.
  static Future<Map<String, dynamic>?> load(
    int? formulationId, {
    String? userId,
  }) async {
    if (formulationId == null) return null;
    final file = _file;
    final pending = _writes;
    if (pending != null) await pending;
    final all = await _read(await file);
    final raw = all[_key(formulationId, userId)];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  static Future<void> store(
    int? formulationId,
    Map<String, dynamic> prefs, {
    String? userId,
  }) {
    if (formulationId == null) return Future<void>.value();
    // Capture the organization and values now, before another screen/account
    // can change them. Serialize read-modify-write to retain rapid changes.
    final file = _file;
    final encoded = jsonEncode(prefs);
    final write = (_writes ?? Future<void>.value()).then((_) async {
      try {
        final target = await file;
        if (target == null) return;
        final all = await _read(target);
        all[_key(formulationId, userId)] = jsonDecode(encoded);
        await target.writeAsString(jsonEncode(all), flush: true);
      } on Object {
        // View preferences must never block business editing or saving.
      }
    });
    _writes = write;
    return write.whenComplete(() {
      // Retain only pending writes, never a completed async session/zone.
      if (identical(_writes, write)) _writes = null;
    });
  }

  static Future<Map<String, dynamic>> _read(File? file) async {
    if (file == null) return <String, dynamic>{};
    try {
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on Object {
      return <String, dynamic>{};
    }
  }

  static Future<File?> get _file async {
    try {
      final paths = getIt.isRegistered<AppPaths>()
          ? getIt<AppPaths>()
          : AppPaths();
      final dir = await paths.orgRoot(paths.orgId);
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } on Object {
      return null;
    }
  }
}
