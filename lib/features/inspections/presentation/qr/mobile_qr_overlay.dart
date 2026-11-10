import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/animations/app_animations.dart';
import 'qr_scan_screen.dart';

/// Watches both router navigators so the shared launcher yields to dialogs.
class MobileQrNavigation extends ChangeNotifier {
  late final NavigatorObserver rootObserver = _QrRouteObserver(this);
  late final NavigatorObserver shellObserver = _QrRouteObserver(this);
  bool _scheduled = false;
  bool _disposed = false;

  bool get popupOpen =>
      [rootObserver, shellObserver].cast<_QrRouteObserver>().any(
        (observer) => observer.navigator != null && observer.top is PopupRoute,
      );

  void _changed() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _QrRouteObserver extends NavigatorObserver {
  _QrRouteObserver(this.owner);
  final MobileQrNavigation owner;
  Route<dynamic>? top;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    top = topRoute;
    owner._changed();
  }
}

/// One launcher above the app navigator, including pushed detail pages.
/// The leading edge leaves the page's trailing create/save FAB available.
class MobileQrOverlay extends StatefulWidget {
  const MobileQrOverlay({
    super.key,
    required this.child,
    required this.gate,
    required this.navigation,
    required this.navigatorKey,
  });

  final Widget child;
  final AuthGate gate;
  final MobileQrNavigation navigation;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<MobileQrOverlay> createState() => _MobileQrOverlayState();
}

class _MobileQrOverlayState extends State<MobileQrOverlay> {
  bool _scanning = false;

  Future<void> _open() async {
    if (_scanning) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    setState(() => _scanning = true);
    try {
      await navigator.push<void>(
        AppPageRoute(
          settings: const RouteSettings(name: '/qr-scan'),
          builder: (_) => const QrScanScreen(replaceOnOpen: true),
        ),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Do not even construct the scanner outside its supported mobile host.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return widget.child;
    }
    return ListenableBuilder(
      listenable: Listenable.merge([widget.gate, widget.navigation]),
      builder: (context, _) {
        final session = widget.gate.session;
        final show =
            widget.gate.isAuthenticated &&
            (session.can(Permission.samplesRead) ||
                session.can(Permission.labResultsRead)) &&
            !_scanning &&
            !widget.navigation.popupOpen &&
            MediaQuery.viewInsetsOf(context).bottom == 0;
        return Overlay.wrap(
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (show)
                PositionedDirectional(
                  start: 16,
                  // Above the phone navigation bar and its gesture safe area.
                  bottom: MediaQuery.paddingOf(context).bottom + 104,
                  child: FloatingActionButton.small(
                    key: const Key('global-qr-scan'),
                    heroTag: null,
                    tooltip: AppText.t('مسح رمز QR', 'Scan QR code'),
                    onPressed: _open,
                    child: const Icon(Icons.qr_code_scanner_outlined),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
