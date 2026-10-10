import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/platform/camera_permission.dart';
import '../../../../core/security/local_secret.dart';
import '../../../../core/security/qr_payload.dart';
import '../../../../core/security/seal_codec.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../../../lab/domain/lab_result_repository.dart';
import '../../../reports/domain/report_repository.dart';
import '../../domain/inspection_repository.dart';
import '../cubit/inspection_detail_cubit.dart';
import '../detail/inspection_detail_screen.dart';

/// Camera availability on this device.
enum _CameraState { checking, ready, denied, unavailable }

/// Mobile-only QR reader for the codes embedded in inspection reports and
/// sample labels.
///
/// A scan opens its inspection **immediately** — no intermediate card. Only
/// codes printed by this app are accepted: new prints carry the `ML1.`
/// envelope (entry-code pointer + sealed body), legacy prints are the bare
/// sealed token or the bare JSON, and everything else is rejected outright.
/// The screen is never offered outside Android (see the scan button in
/// [InspectionsScreen]).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  MobileScannerController? _controller;
  _CameraState _camera = _CameraState.checking;
  final _manual = TextEditingController();

  bool _busy = false;
  bool _handled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_checkCamera());
  }

  @override
  void dispose() {
    _manual.dispose();
    unawaited(_controller?.dispose());
    super.dispose();
  }

  bool get _isMobile =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Camera permission is touched only here, when the scanner opens — never
  /// at app start and never by any other screen. The single `request()`
  /// shows the one-time system dialog exactly once, at QR time; a denial
  /// lands on the grant/settings card below instead of nagging every visit.
  Future<void> _checkCamera() async {
    if (!_isMobile) {
      if (mounted) setState(() => _camera = _CameraState.unavailable);
      return;
    }
    try {
      if (await QrCameraPermission.request()) {
        if (!mounted) return;
        _startScanner();
      } else if (mounted) {
        setState(() => _camera = _CameraState.denied);
      }
    } catch (_) {
      // No plugin host (tests, odd embeds): manual entry still works.
      if (mounted) setState(() => _camera = _CameraState.unavailable);
    }
  }

  Future<void> _requestCamera() async {
    try {
      if (await QrCameraPermission.request()) {
        if (!mounted) return;
        _startScanner();
      } else if (mounted) {
        setState(() => _camera = _CameraState.denied);
      }
    } catch (_) {
      if (mounted) setState(() => _camera = _CameraState.unavailable);
    }
  }

  void _startScanner() {
    _controller ??= MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    setState(() => _camera = _CameraState.ready);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.trim().isEmpty) return;
    _handled = true;
    unawaited(_controller?.stop());
    unawaited(_resolveQr(raw));
  }

  Future<void> _searchManual() async {
    final code = _manual.text.trim();
    if (code.isEmpty) {
      setState(() {
        _error = AppText.t('اكتب رقم القيد أولاً', 'Enter the entry code first');
      });
      return;
    }
    await _lookup(code);
  }

  /// Parses scanned text, then opens its inspection immediately.
  Future<void> _resolveQr(String raw) async {
    final parsed = tryParseAppQr(raw);
    if (parsed == null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppText.t(
          'هذا الرمز ليس من رموز البرنامج — يُقرأ فقط رمز المحاضر والملصقات',
          'This is not an app code — only report and label codes are readable',
        );
      });
      _rearm();
      return;
    }
    var entryCode = parsed.entryCode;
    final body = parsed.body;
    if (body.startsWith(sealedTextPrefix)) {
      // Tamper check when verifiable: a sealed body that opens but points
      // at a different code than the envelope is a forged print.
      try {
        final key = await getIt<LocalSecret>().load();
        final (plain, ok) = unsealText(body, key);
        if (ok && plain.isNotEmpty) {
          try {
            final decoded = jsonDecode(plain);
            if (decoded is Map) {
              final sealedCode = '${decoded['ec'] ?? ''}';
              if (sealedCode.isNotEmpty) {
                if (entryCode.isNotEmpty && sealedCode != entryCode) {
                  if (!mounted) return;
                  setState(() {
                    _busy = false;
                    _error = AppText.t(
                      'رمز مزيّف — محتواه المشفّر لا يطابق رقم المحضر',
                      'Forged code — its sealed content does not match the record number',
                    );
                  });
                  _rearm();
                  return;
                }
                entryCode = sealedCode;
              }
            }
          } catch (_) {
            // Sealed but not our JSON shape: still resolves via the
            // envelope pointer below.
          }
        }
      } catch (_) {
        // Cannot unseal here (another device's print): the inspection
        // itself still resolves from the local database below.
      }
    } else if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && entryCode.isEmpty) {
          entryCode = '${decoded['ec'] ?? ''}';
        }
      } catch (_) {}
    }
    if (entryCode.isEmpty) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppText.t(
          'رمز مشفّر من جهاز آخر — تعذّر التحقق منه ومعرفة محضره على هذا الجهاز',
          'Code sealed on another device — it cannot be verified or resolved here',
        );
      });
      _rearm();
      return;
    }
    await _lookup(entryCode);
  }

  /// Loads the inspection by entry code from the local database and opens
  /// it at once — the inspection itself comes from the database (the
  /// trusted channel), never from the QR text.
  Future<void> _lookup(String entryCode) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final rows = await getIt<InspectionRepository>().list(
        query: entryCode,
        limit: 50,
      );
      Map<String, dynamic>? row;
      for (final r in rows) {
        if ('${r['entry_code'] ?? ''}' == entryCode) {
          row = r;
          break;
        }
      }
      if (!mounted) return;
      if (row == null) {
        setState(() {
          _busy = false;
          _error = AppText.t(
            'هذا المحضر غير موجود على هذا الجهاز — قد يحتاج مزامنة من الجهاز الذي أُنشئ عليه',
            'Not on this device — it may need syncing from the device that created it',
          );
        });
        _rearm();
        return;
      }
      setState(() => _busy = false);
      await _openInspection((row['id'] as num).toInt());
      if (!mounted) return;
      _scanAgain();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppText.t(
          'تعذّر البحث برقم القيد',
          'Could not look up the entry code',
        );
      });
      _rearm();
    }
  }

  /// Re-arms the camera for the next code without clearing the current
  /// message, so a miss stays visible while scanning continues.
  void _rearm() {
    if (!mounted) return;
    setState(() => _handled = false);
    unawaited(_controller?.start());
  }

  void _scanAgain() {
    setState(() {
      _handled = false;
      _error = null;
    });
    unawaited(_controller?.start());
  }

  Future<void> _openInspection(int id) async {
    final wide = MediaQuery.of(context).size.width >= AppBreakpoints.medium;
    if (wide) {
      await showAppWindow<bool>(
        context,
        title: AppText.t('تفاصيل الفحص', 'Inspection Details'),
        icon: Icons.fact_check_outlined,
        size: AppWindowSize.lg,
        scrollBody: false,
        child: BlocProvider(
          create: (c) => InspectionDetailCubit(
            inspectionId: id,
            repo: getIt<InspectionRepository>(),
            reports: getIt<ReportRepository>(),
            labResults: getIt<LabResultRepository>(),
          )..load(),
          child: InspectionDetailScreen(inspectionId: id),
        ),
      );
    } else {
      await Navigator.of(context).push<bool>(
        AppPageRoute(
          builder: (_) => BlocProvider(
            create: (c) => InspectionDetailCubit(
              inspectionId: id,
              repo: getIt<InspectionRepository>(),
              reports: getIt<ReportRepository>(),
              labResults: getIt<LabResultRepository>(),
            )..load(),
            child: InspectionDetailScreen(inspectionId: id),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('مسح رمز QR', 'Scan QR code'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _cameraSection(),
            const SizedBox(height: AppSpacing.md),
            _manualSection(),
            const SizedBox(height: AppSpacing.md),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) _messageCard(_error!, AppColors.danger),
          ],
        ),
      ),
    );
  }

  Widget _cameraSection() {
    switch (_camera) {
      case _CameraState.checking:
        return const SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        );
      case _CameraState.ready:
        final controller = _controller;
        if (controller == null) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(16.r),
          child: SizedBox(
            height: 320.h,
            child: MobileScanner(
              controller: controller,
              onDetect: _onDetect,
            ),
          ),
        );
      case _CameraState.denied:
        // Two ways out: ask again (first denials), or the system settings
        // (Android silently drops re-requests after "don't ask again").
        return _messageCard(
          AppText.t(
            'يحتاج المسح إلى إذن الكاميرا',
            'Scanning needs camera permission',
          ),
          AppColors.warning,
          action: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppButton(
                label: AppText.t('منح الإذن', 'Grant permission'),
                icon: Icon(Icons.videocam_outlined, size: 18.r),
                onPressed: _requestCamera,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: AppText.t(
                  'فتح إعدادات التطبيق',
                  'Open app settings',
                ),
                style: AppButtonStyle.secondary,
                icon: Icon(Icons.settings_outlined, size: 18.r),
                onPressed: QrCameraPermission.openSettings,
              ),
            ],
          ),
        );
      case _CameraState.unavailable:
        return _messageCard(
          AppText.t(
            'لا توجد كاميرا متاحة — يمكن البحث برقم القيد أدناه',
            'No camera available — search by entry code below instead',
          ),
          AppColors.textMuted,
        );
    }
  }

  Widget _manualSection() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppText.t(
                'أو ابحث برقم القيد المطبوع تحت الرمز',
                'Or search by the entry code printed under the code',
              ),
              style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: AppField(
                    label: AppText.t('رقم القيد', 'Entry code'),
                    controller: _manual,
                    onFieldSubmitted: (_) => _searchManual(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  label: AppText.t('بحث', 'Search'),
                  icon: Icon(Icons.search, size: 18.r),
                  loading: _busy,
                  onPressed: _busy ? null : _searchManual,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageCard(String message, Color color, {Widget? action}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 13.spMax),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.sm),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
