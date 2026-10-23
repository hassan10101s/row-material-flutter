import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../di/service_locator.dart';
import '../../domain/lab_local_repository.dart';

/// Per-item stock log (the log button): lots with expiry on top, then the
/// unified history feed (receipts, FEFO consumption lines, adjustments,
/// disposals and reversals), newest first.
class InventoryLogScreen extends StatefulWidget {
  const InventoryLogScreen({super.key, required this.item});

  final Map<String, dynamic> item;

  static Future<void> open(BuildContext context, Map<String, dynamic> item) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => InventoryLogScreen(item: item)),
    );
  }

  @override
  State<InventoryLogScreen> createState() => _InventoryLogScreenState();
}

class _InventoryLogScreenState extends State<InventoryLogScreen> {
  final _repo = getIt<LabLocalRepository>();
  List<Map<String, dynamic>> _lots = const [];
  List<Map<String, dynamic>> _feed = const [];
  bool _loading = true;
  String? _error;
  bool _disposing = false;

  int get _itemId => (widget.item['id'] as num).toInt();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lots = await _repo.listInventoryLots(_itemId, includeEmpty: true);
      final feed = await _repo.itemStockLog(_itemId);
      if (!mounted) return;
      setState(() {
        _lots = lots;
        _feed = feed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  double get _expiredQty {
    final today = DateTime.now().toString().substring(0, 10);
    var sum = 0.0;
    for (final l in _lots) {
      final remaining = ((l['qty_remaining'] as num?)?.toDouble() ?? 0.0);
      final expiry = '${l['expiry_date'] ?? ''}';
      if (remaining > 1e-9 &&
          expiry.isNotEmpty &&
          expiry.substring(0, 10).compareTo(today) < 0) {
        sum += remaining;
      }
    }
    return sum;
  }

  Future<void> _disposeExpired() async {
    if (_disposing) return;
    final qty = _expiredQty;
    if (qty <= 1e-9) return;
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.delete_outline,
      title: AppText.t('إعدام المنتهي؟', 'Dispose expired?'),
      message: AppText.t(
        'سيتم تصفير $qty ${widget.item['unit'] ?? ''} منتهية الصلاحية مع تسجيلها في السجل.',
        'Will zero $qty ${widget.item['unit'] ?? ''} of expired stock, recorded in the log.',
      ),
      confirmLabel: AppText.t('إعدام', 'Dispose'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _disposing = true);
    try {
      await _repo.disposeExpiredLots(_itemId);
      if (!mounted) return;
      setState(() => _disposing = false);
      AppFeedback.success(context, AppText.t('تم الإعدام', 'Disposed.'));
      await _load();
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() => _disposing = false);
      AppFeedback.error(context, e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _disposing = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppTopAppBar(title: AppText.t('سجل المخزون', 'Stock log')),
      body: SafeArea(
        child: _loading && _lots.isEmpty && _feed.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(AppSpacing.page),
                child: AppSkeletonList(rows: 6, lines: 2, height: 72),
              )
            : _error != null && _lots.isEmpty && _feed.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.page),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.pageMobile),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SummaryCard(
                        item: widget.item,
                        lots: _lots,
                        expiredQty: _expiredQty,
                        disposing: _disposing,
                        onDispose: _disposeExpired,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        AppText.t('اللوتات', 'Lots (FEFO order)'),
                        style: TextStyle(
                          fontSize: 14.spMax,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (_lots.isEmpty)
                        AppEmptyState(
                          icon: Icons.inventory_outlined,
                          title: AppText.t('لا توجد لوتات', 'No lots yet'),
                        )
                      else
                        for (final lot in _lots) ...[
                          _LotCard(lot: lot),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        AppText.t('السجل', 'History'),
                        style: TextStyle(
                          fontSize: 14.spMax,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (_feed.isEmpty)
                        AppEmptyState(
                          icon: Icons.history,
                          title: AppText.t('لا حركات بعد', 'No movements yet'),
                        )
                      else
                        for (final entry in _feed) ...[
                          _FeedRow(entry: entry),
                          const SizedBox(height: AppSpacing.xs),
                        ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.item,
    required this.lots,
    required this.expiredQty,
    required this.disposing,
    required this.onDispose,
  });

  final Map<String, dynamic> item;
  final List<Map<String, dynamic>> lots;
  final double expiredQty;
  final bool disposing;
  final VoidCallback onDispose;

  @override
  Widget build(BuildContext context) {
    final remaining = lots.fold<double>(
      0.0,
      (s, l) => s + (((l['qty_remaining'] as num?)?.toDouble() ?? 0.0)),
    );
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${item['name'] ?? ''}',
            style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            '${AppText.t('الرصيد', 'Balance')}: $remaining ${item['unit'] ?? ''}'
            ' · ${lots.length} ${AppText.t('لوت', 'lots')}',
            style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
          ),
          if (expiredQty > 1e-9) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${AppText.t('منتهي الصلاحية', 'Expired')}: $expiredQty ${item['unit'] ?? ''}',
                    style: TextStyle(
                      fontSize: 13.spMax,
                      fontWeight: FontWeight.w700,
                      color: AppColors.danger,
                    ),
                  ),
                ),
                AppButton(
                  small: true,
                  style: AppButtonStyle.secondary,
                  label: AppText.t('إعدام المنتهي', 'Dispose expired'),
                  loading: disposing,
                  onPressed: disposing ? null : onDispose,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LotCard extends StatelessWidget {
  const _LotCard({required this.lot});

  final Map<String, dynamic> lot;

  @override
  Widget build(BuildContext context) {
    final remaining = ((lot['qty_remaining'] as num?)?.toDouble() ?? 0.0);
    final received = ((lot['qty_received'] as num?)?.toDouble() ?? 0.0);
    final expiry = '${lot['expiry_date'] ?? ''}';
    final today = DateTime.now().toString().substring(0, 10);
    final expired =
        expiry.isNotEmpty &&
        expiry.substring(0, 10).compareTo(today) < 0 &&
        remaining > 1e-9;
    final depleted = remaining <= 1e-9;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${lot['lot_no'] ?? ''}',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${AppText.t('الصلاحية', 'Expiry')}: ${expiry.isEmpty ? '—' : expiry}'
                  '${'${lot['supplier'] ?? ''}'.isNotEmpty ? ' · ${lot['supplier']}' : ''}',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: expired ? AppColors.danger : AppColors.textMuted,
                    fontWeight: expired ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                if ('${lot['note'] ?? ''}'.isNotEmpty)
                  Text(
                    '${lot['note']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$remaining',
                style: TextStyle(
                  fontSize: 16.spMax,
                  fontWeight: FontWeight.w800,
                  color: depleted
                      ? AppColors.textMuted
                      : expired
                      ? AppColors.danger
                      : AppColors.textStrong,
                ),
              ),
              Text(
                '/ $received',
                style: TextStyle(
                  fontSize: 11.spMax,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final kind = '${entry['kind'] ?? ''}';
    final icon = switch (kind) {
      'lot' => Icons.inventory_outlined,
      'ledger' => Icons.receipt_long_outlined,
      'consumption' => Icons.science_outlined,
      'adjustment' => Icons.balance_outlined,
      _ => Icons.circle_outlined,
    };
    final qty = ((entry['qty'] as num?)?.toDouble() ?? 0.0);
    final at = '${entry['at'] ?? ''}';
    final time = at.length >= 16 ? at.substring(0, 16) : at;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20.r, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry['detail'] ?? ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.spMax),
                ),
                Text(
                  time,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (qty.abs() > 1e-9)
            Text(
              '${qty > 0 ? '+' : ''}$qty',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontSize: 13.spMax,
                fontWeight: FontWeight.w700,
                color: qty > 0 ? AppColors.success : AppColors.textStrong,
              ),
            ),
        ],
      ),
    );
  }
}
