import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../di/service_locator.dart';
import '../../lab/data/lab_repo.dart';

/// Lab (port of Web LabView). Phase 4 will replace this with the full
/// inventory/analyses/run-test panels.
class LabScreen extends StatefulWidget {
  const LabScreen({super.key});

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> {
  Future<List<Map<String, dynamic>>>? _inventoryFuture;

  @override
  void initState() {
    super.initState();
    _inventoryFuture = getIt<LabRepo>().listInventory();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('المختبر | Lab', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _inventoryFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final items = snap.data ?? const [];
              if (items.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.biotech_outlined,
                  title: 'المخزون المختبر | Lab inventory',
                  subtitle: 'لا توجد أصناف بعد — قسم المخزون قيد التطوير.',
                );
              }
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      for (final item in items)
                        ListTile(
                          dense: true,
                          title: Text('${item['item_name'] ?? ''}'),
                          subtitle: Text('${item['category'] ?? ''}'),
                          trailing: Text('${item['quantity'] ?? 0} ${item['unit'] ?? ''}'),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          AppEmptyState(
            icon: Icons.construction,
            title: AppStrings.lab,
            subtitle: 'الوظائف الكاملة للمختبر (التحليلات، تشغيل الاختبارات، تقارير المختبر) قيد التطوير.',
          ),
        ],
      ),
    );
  }
}