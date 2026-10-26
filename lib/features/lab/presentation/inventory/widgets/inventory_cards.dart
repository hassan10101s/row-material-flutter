import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/responsive/form_factor.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../core/formula_engine.dart';

/// Small card widgets for the mobile inventory list.
///
/// Composed by `MobileInventoryTab`; status text/color stay beside the row
/// here so desktop and mobile can never disagree on thresholds.

String inventoryStatusText(Map<String, dynamic> r) {
  final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
  final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
  if (qty <= 0) return AppText.t('نفد', 'Empty');
  if (qty < min) return AppText.t('منخفض', 'Low');
  return AppText.t('متوفر', 'OK');
}

Color inventoryStatusColor(Map<String, dynamic> r) {
  final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
  final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
  if (qty <= 0) return AppColors.danger;
  if (qty < min) return AppColors.partial;
  return AppColors.success;
}

class InventoryCards extends StatelessWidget {
  const InventoryCards({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onAdjust,
    required this.onReceive,
    required this.onLog,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onAdjust;
  final void Function(Map<String, dynamic> row) onReceive;
  final void Function(Map<String, dynamic> row) onLog;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: rows.length,
      // md between cards — sm keeps them visually glued together.
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, index) {
        final r = rows[index];
        return InventoryCard(
          name: '${r['name']}',
          category: inventoryCategoryLabel(r['category']),
          qty: '${r['current_qty'] ?? 0} ${r['unit'] ?? ''}',
          status: inventoryStatusText(r),
          statusColor: inventoryStatusColor(r),
          expiredQty: ((r['expired_qty'] as num?)?.toDouble() ?? 0.0),
          nearestExpiry: '${r['nearest_expiry'] ?? ''}',
          onEdit: () => onEdit(r),
          onAdjust: () => onAdjust(r),
          onReceive: () => onReceive(r),
          onLog: () => onLog(r),
        );
      },
    );
  }
}

class InventoryCard extends StatelessWidget {
  const InventoryCard({
    super.key,
    required this.name,
    required this.category,
    required this.qty,
    required this.status,
    required this.statusColor,
    required this.onEdit,
    required this.onAdjust,
    required this.onReceive,
    required this.onLog,
    this.expiredQty = 0,
    this.nearestExpiry = '',
  });

  final String name;
  final String category;
  final String qty;
  final String status;
  final Color statusColor;
  final VoidCallback onEdit;
  final VoidCallback onAdjust;
  final VoidCallback onReceive;
  final VoidCallback onLog;

  /// Remaining quantity sitting in expired lots.
  final double expiredQty;

  /// Nearest lot expiry (`yyyy-MM-dd`) or ''.
  final String nearestExpiry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      // Dense list card: the flat shadow tier on mobile keeps long registers
      // light; the desktop grid keeps the standard lift.
      flat: FormFactor.current.isMobile,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.spMax,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: AppText.t('تسوية الكمية', 'Adjust'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onAdjust,
                icon: Icon(Icons.swap_vert, size: 20.r),
              ),
              IconButton(
                tooltip: AppStrings.edit,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined, size: 20.r),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, size: 20.r),
                tooltip: AppText.t('المزيد', 'More'),
                onSelected: (v) {
                  if (v == 'receive') onReceive();
                  if (v == 'adjust') onAdjust();
                  if (v == 'log') onLog();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'receive',
                    child: Text(AppText.t('استلام كمية', 'Receive stock')),
                  ),
                  PopupMenuItem(
                    value: 'adjust',
                    child: Text(AppText.t('تسوية الكمية', 'Adjust')),
                  ),
                  PopupMenuItem(
                    value: 'log',
                    child: Text(AppText.t('السجل', 'Log')),
                  ),
                ],
              ),
            ],
          ),
          if (expiredQty > 1e-9 || nearestExpiry.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (expiredQty > 1e-9)
                  _Badge(
                    icon: Icons.warning_amber_outlined,
                    text: '${AppText.t('منتهي', 'Expired')}: $expiredQty',
                    color: AppColors.danger,
                  ),
                if (nearestExpiry.isNotEmpty)
                  _Badge(
                    icon: Icons.event_outlined,
                    text:
                        '${AppText.t('أقرب صلاحية', 'Nearest expiry')}: $nearestExpiry',
                    color: AppColors.textMuted,
                  ),
              ],
            ),
          ],
          const Divider(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: Text(
                  qty,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.spMax,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.r, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.spMax,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
