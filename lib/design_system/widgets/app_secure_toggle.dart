import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import 'app_tooltip.dart';

/// No visible label: the bilingual interface deliberately uses "Secure" in
/// both languages. Place immediately alongside AppRequiredToggle.
class AppSecureToggle extends StatelessWidget {
  const AppSecureToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => AppTooltip(
    message: 'Secure',
    child: Semantics(
      label: 'Secure',
      toggled: value,
      enabled: enabled,
      button: true,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Icon(
            value ? Icons.shield : Icons.shield_outlined,
            size: 22.r,
            color: !enabled
                ? AppColors.textMuted.withValues(alpha: .5)
                : value
                ? AppColors.primary
                : AppColors.textMuted,
          ),
        ),
      ),
    ),
  );
}
