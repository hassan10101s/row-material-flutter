import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import 'activity_tab.dart';
import 'analyses_tab.dart';
import 'constants_tab.dart';
import 'inventory_tab.dart';
import 'lab_reports_tab.dart';
import 'run_test_tab.dart';
import 'test_history_tab.dart';

class _LabTab {
  final String label;
  final IconData icon;
  final Widget child;
  const _LabTab(this.label, this.icon, this.child);
}

/// Lab center: inventory, analyses, run test, test history, constants,
/// activity log and lab reports (port of Web LabView panels).
class LabScreen extends StatefulWidget {
  const LabScreen({super.key});

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> {
  int _tab = 0;
  int _historyTick = 0;

  late final List<_LabTab> _tabs = [
    _LabTab('المخزون | Inventory', Icons.inventory_2_outlined, const InventoryTab()),
    _LabTab('التحليلات | Analyses', Icons.science_outlined, const AnalysesTab()),
    _LabTab(
        'تشغيل اختبار | Run Test',
        Icons.play_circle_outline,
        RunTestTab(onTestRun: () => setState(() => _historyTick++))),
    _LabTab('سجل الفحوصات | Tests', Icons.history, TestHistoryTab(refreshTick: _historyTick)),
    _LabTab('الثوابت | Constants', Icons.functions, const ConstantsTab()),
    _LabTab('سجل النشاط | Activity', Icons.receipt_long_outlined, const ActivityTab()),
    _LabTab('تقارير المختبر | Reports', Icons.description_outlined, const LabReportsTab()),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.page, AppSpacing.page, 0),
          child: Text(AppStrings.lab, style: Theme.of(context).textTheme.headlineSmall),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 46,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: ChoiceChip(
                      label: Text(_tabs[i].label),
                      avatar: Icon(_tabs[i].icon, size: 18),
                      selected: _tab == i,
                      onSelected: (_) => setState(() => _tab = i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: IndexedStack(index: _tab, children: [for (final t in _tabs) t.child]),
          ),
        ),
      ],
    );
  }
}