import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';

/// Circular "مطلوب" toggle: empty circle when off, filled circle with a
/// checkmark when on. Used to mark a physical/chemical field as required
/// at inspection-save time.
class AppRequiredToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  const AppRequiredToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final fill = value ? AppColors.primary : Colors.transparent;
    final border = value ? AppColors.primary : AppColors.border;
    return Tooltip(
      message: AppText.t(
        'مطلوب: يجب إدخال قيمته عند حفظ المحضر',
        'Required: must be filled when saving the inspection',
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? () => onChanged(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 22.r,
                  height: 22.r,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                    border: Border.all(color: border, width: 1.6),
                    boxShadow: value
                        ? [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.3),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: value
                      ? Icon(Icons.check, size: 14.r, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 6),
                Text(
                  AppText.t('مطلوب', 'Required'),
                  style: TextStyle(
                    fontSize: 12.spMax,
                    fontWeight:
                        value ? FontWeight.w700 : FontWeight.w400,
                    color:
                        value ? AppColors.primary : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small "مطلوب *" pill shown in front of a required inspection field.
class RequiredBadge extends StatelessWidget {
  const RequiredBadge({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12.r, color: AppColors.primary),
          const SizedBox(width: 4),
          Text(
            AppText.t('مطلوب', 'Required'),
            style: TextStyle(
              fontSize: 11.spMax,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
