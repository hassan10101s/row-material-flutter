import 'package:flutter/material.dart';

import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../data/lab_repo.dart';

/// Activity-log tab: stock adjustments + consumptions.
class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key});

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  final _repo = getIt<LabRepo>();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

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
      final rows = await _repo.activityLog(limit: 300);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('سجل النشاط | Activity log', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        if (_loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (_error != null) ...[
          Text(_error!, style: TextStyle(color: AppColors.danger)),
        ] else if (_rows.isEmpty) ...[
          const Text('لا يوجد نشاط | No activity yet'),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final r in _rows)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          r['type'] == 'adjust'
                              ? Icons.tune
                              : Icons.science_outlined,
                          size: 20,
                          color: r['type'] == 'adjust'
                              ? AppColors.info
                              : AppColors.primary,
                        ),
                        title: Text('${r['inventory_name']}  ·  ${r['quantity_text']}'),
                        subtitle: Text(
                          '${r['user_name']}${(r['reason'] ?? '').toString().trim().isNotEmpty ? ' — ${r['reason']}' : ''}\n${r['at']}',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                        ),
                        isThreeLine: true,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}