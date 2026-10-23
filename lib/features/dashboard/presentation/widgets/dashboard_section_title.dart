import 'package:flutter/material.dart';

import '../../../../design_system/widgets/app_empty_state.dart';

/// Thin wrapper over the design-system header so every dashboard section
/// renders identically (icon tone + trailing-context subtitle). Kept as a
/// feature-local name so section files stay short.
class DashboardSectionTitle extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  const DashboardSectionTitle({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
  });
  @override
  Widget build(BuildContext context) {
    return AppSectionHeader(
      icon: icon,
      iconColor: color,
      title: title,
      subtitle: subtitle,
    );
  }
}
