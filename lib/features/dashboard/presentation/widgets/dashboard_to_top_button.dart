import 'package:flutter/material.dart';

import '../../../../design_system/tokens/app_colors.dart';

class DashboardToTopButton extends StatefulWidget {
  const DashboardToTopButton({super.key, required this.scroll});

  final ScrollController scroll;

  @override
  State<DashboardToTopButton> createState() => _ToTopButtonState();
}

class _ToTopButtonState extends State<DashboardToTopButton> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final show = widget.scroll.hasClients && widget.scroll.offset > 700;
    if (show != _show && mounted) setState(() => _show = show);
  }

  void _toTop() {
    if (!widget.scroll.hasClients) return;
    widget.scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Directionality-aware trailing offset: `end` flips with RTL (Arabic).
    return PositionedDirectional(
      end: 16,
      bottom: 20,
      child: AnimatedOpacity(
        opacity: _show ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: IgnorePointer(
          ignoring: !_show,
          child: Material(
            color: AppColors.primary,
            shape: const CircleBorder(),
            elevation: 6,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _toTop,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.arrow_upward, color: Colors.white, size: 22),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
