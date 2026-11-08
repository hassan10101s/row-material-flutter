import 'package:flutter/material.dart';

import 'secure_field_access.dart';

/// Revokes copied modal state as soon as reveal is disabled or permission is
/// lost. A modal must not retain a previously revealed immutable model.
class SecureDisplayGuard extends StatefulWidget {
  const SecureDisplayGuard({
    super.key,
    required this.access,
    required this.child,
  });
  final SecureFieldAccess? access;
  final Widget child;
  @override
  State<SecureDisplayGuard> createState() => _SecureDisplayGuardState();
}

class _SecureDisplayGuardState extends State<SecureDisplayGuard> {
  bool _revealed = false;
  bool _revoked = false;
  @override
  void initState() {
    super.initState();
    _revealed = widget.access?.enabled == true;
    widget.access?.addListener(_changed);
  }

  void _changed() {
    if (widget.access?.enabled == true) _revealed = true;
    if (!_revealed || widget.access?.enabled == true || _revoked) return;
    setState(() => _revoked = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    widget.access?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _revoked ? const SizedBox.shrink() : widget.child;
}
