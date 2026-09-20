import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../di/service_locator.dart';
import '../../reference/data/reference_repo.dart';

/// Reference materials manager (port of Web ReferenceAppView / MaterialsEditor).
class ReferenceScreen extends StatefulWidget {
  const ReferenceScreen({super.key});

  @override
  State<ReferenceScreen> createState() => _ReferenceScreenState();
}

class _ReferenceScreenState extends State<ReferenceScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = getIt<ReferenceRepo>().listMaterials();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('????????', 'Reference'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.book_outlined,
                  title: 'لا توجد خامات | No materials yet',
                  subtitle: 'تُستورد المواد تلقائياً من Reference.xlsx عند التشغيل الأول.',
                );
              }
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      for (final r in rows)
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.science_outlined,
                              size: 18, color: AppColors.primary),
                          title: Text('${r['material_name'] ?? ''}'),
                          subtitle: Text('${r['material_code'] ?? ''}'),
                          trailing: IconButton(
                            tooltip: 'تعديل | Edit',
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () {},
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}