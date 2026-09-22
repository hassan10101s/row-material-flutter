import 'package:flutter/services.dart' show rootBundle;

import '../../../core/security/local_secret.dart';
import '../../../core/utils/app_dates.dart';
import '../../lab/data/lab_repo.dart';
import '../../settings/data/settings_repo.dart';
import 'qr_render.dart';
import 'report_builder.dart';
import 'tiny_jinja.dart';

/// Full HTML renderer for the stored `inspections.report_html` column.
///
/// Port of `core/services/report.py` `ReportService.render_html` +
/// `InspectionService.refresh_report_html`: builds the same Jinja context as
/// the reference (physical/chemical tables, status timeline, encrypted QR
/// data-URI, binary-lab rows merged) and renders the copy of
/// `templates/report_template.html` shipped under `assets/templates/`.
class ReportHtmlBuilder {
  ReportHtmlBuilder({
    required this.settingsRepo,
    required this.labRepo,
    required this.secret,
    Future<String> Function()? templateLoader,
  }) : _templateLoader = templateLoader ?? _loadTemplate;

  final SettingsRepo settingsRepo;
  final LabRepo labRepo;
  final LocalSecret secret;
  final Future<String> Function() _templateLoader;

  static String? _cachedTemplate;

  static Future<String> _loadTemplate() async {
    if (_cachedTemplate != null) return _cachedTemplate!;
    final template =
        await rootBundle.loadString('assets/templates/report_template.html');
    _cachedTemplate = template;
    return template;
  }

  /// Build the full render_html context (report.py:269-309) for a serialized
  /// inspection row (the shape `serializeInspectionRow` + `status_history`).
  Future<Map<String, dynamic>> buildContext(
    Map<String, dynamic> inspection, {
    String? baseUrl,
  }) async {
    final settings = await settingsRepo.getSettings();
    final enriched = await labRepo.injectLabTests(inspection);
    final secretBytes = await secret.load();
    final context = buildInspectionContext(
      enriched,
      settings: settings,
      encryptionSecret: secretBytes,
    );
    final (dataUri: qrImageDataUri, warning: qrWarning) =
        generateQrDataUri('${context['qr_payload_text'] ?? ''}');
    context
      ..['qr_image_data_uri'] = qrImageDataUri
      ..['qr_warning'] = qrWarning
      ..['updated_at'] = inspection['updated_at'] ?? nowIso()
      ..['quality_specialist_name'] = inspection['specialist_name'] ?? '-'
      // No local template dir in Flutter; the base tag is only needed for
      // relative asset resolution in a browser, so leave it unset.
      ..['base_url'] = baseUrl ?? '';
    return context;
  }

  /// Port of `report.py` `render_html(inspection, base_url=None)`.
  Future<String> renderInspectionHtml(
    Map<String, dynamic> inspection, {
    String? baseUrl,
  }) async {
    final context = await buildContext(inspection, baseUrl: baseUrl);
    final template = await _templateLoader();
    return tinyJinjaRender(template, context);
  }
}