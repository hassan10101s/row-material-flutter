import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../di/service_locator.dart';
import '../../../../router/app_router.dart';
import '../cubit/qc_custom_tables_cubit.dart';
import '../cubit/qc_ncr_cubit.dart';
import '../cubit/qc_sops_cubit.dart';
import '../custom_tables/qc_settings_screen.dart';
import '../custom_tables/qc_table_records_screen.dart';
import '../ncr/qc_ncr_dashboard_screen.dart';
import '../routine/routine_lists_cubit.dart';
import '../routine/routine_lists_screen.dart';
import '../sops/qc_sops_screen.dart';

class _QualityTab {
  const _QualityTab({
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

/// One user-authored chip in the hub row: pressing it opens the register for
/// that table instead of swapping the inline tab.
typedef _CustomTableEntry = ({String title, int tableId});

/// Unified entry point for quality inspection and quality-management work.
///
/// The detail registers remain dedicated screens, while this hub keeps the
/// operational and management areas one tap apart.
class QcManagementScreen extends StatefulWidget {
  const QcManagementScreen({super.key});

  @override
  State<QcManagementScreen> createState() => _QcManagementScreenState();
}

/// One icon shared by every user-authored chip: definitions carry no color
/// or icon settings by design, so the column of custom registers reads as
/// its own family next to the four built-in tabs.
const _customChipIcon = Icons.table_chart_outlined;

class _QcManagementScreenState extends State<QcManagementScreen> {
  int _selectedTab = 0;

  /// Can the signed-in user open the settings gear? Re-read per build since
  /// the sign-in state and device mode can change between visits.
  bool get _canManageDefs {
    try {
      return getIt<AuthGate>().canWrite(Permission.qcWrite);
    } catch (_) {
      return false;
    }
  }

  /// Opens the settings gear; when it closes the defs cubit is refetched,
  /// which also rebuilds the chip row from the same state.
  Future<void> _openSettings(BuildContext context) async {
    await QcSettingsScreen.open(context);
    if (context.mounted) context.read<QcCustomTablesCubit>().refresh();
  }

  /// Pressing a user-authored chip opens that table's register where the
  /// rest of the program puts a surface: a dedicated window on desktop
  /// (the QC editor, the record form, the equipment dialogs) and a pushed
  /// page on phones. It is deliberately *not* an inline IndexedStack tab —
  /// a register is a separate surface, not a view of the hub.
  Future<void> _openTable(BuildContext context, int tableId) async {
    await QcTableRecordsScreen.open(context, tableId);
    if (context.mounted) context.read<QcCustomTablesCubit>().refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <_QualityTab>[
      _QualityTab(
        label: AppText.t('القوائم اليومية', 'Routine lists'),
        icon: Icons.checklist_rtl_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<RoutineListsCubit>()..load(),
          child: const RoutineListsScreen(),
        ),
      ),
      _QualityTab(
        label: AppText.t('عدم المطابقة', 'Non-conformance'),
        icon: Icons.fact_check_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcNcrCubit>()
            ..loadOptions()
            ..load(),
          child: QcNcrDashboardScreen(
            embedded: true,
            onOpenList: () => context.push(AppRoutes.qcNcrList),
          ),
        ),
      ),
      _QualityTab(
        label: AppText.t('الإجراءات SOP', 'Procedures SOP'),
        icon: Icons.menu_book_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcSopsCubit>()..load(),
          child: const QcSopsScreen(embedded: true),
        ),
      ),
    ];

    // Same hub anatomy as the Lab screen: title lives in the shell topbar
    // (both experiences), ChoiceChip tab row below, page-padded body. The
    // user-authored definitions ride at the end of the chip row as their own
    // chips, followed by the settings gear; the gear is visible to whoever
    // holds `qc.write`, the chips to everyone.
    return BlocProvider<QcCustomTablesCubit>(
      create: (_) => getIt<QcCustomTablesCubit>()..load(),
      child: BlocBuilder<QcCustomTablesCubit, QcCustomTablesState>(
        builder: (context, defsState) {
          final customTables = <_CustomTableEntry>[
            for (final table in defsState.tables)
              if (table.tableId != null)
                (title: table.title, tableId: table.tableId!),
          ];
          final allTabs = tabs;
          if (_selectedTab >= allTabs.length) _selectedTab = 0;

          // Same hub anatomy as the Lab screen: title lives in the shell topbar
          // (both experiences), ChoiceChip tab row below, page-padded body.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.page),
              SizedBox(
                height: 46.h,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.page,
                  ),
                  child: Row(
                    children: [
                      for (var index = 0; index < allTabs.length; index++)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            end: AppSpacing.sm,
                          ),
                          child: ChoiceChip(
                            label: Text(allTabs[index].label),
                            avatar: Icon(allTabs[index].icon, size: 18.r),
                            selected: _selectedTab == index,
                            onSelected: (_) =>
                                setState(() => _selectedTab = index),
                          ),
                        ),
                      // User-authored registers ride the same row, but select
                      // nothing: pressing one opens its dedicated window.
                      for (final table in customTables)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            end: AppSpacing.sm,
                          ),
                          child: ActionChip(
                            label: Text(table.title),
                            avatar: Icon(_customChipIcon, size: 18.r),
                            onPressed: () => _openTable(context, table.tableId),
                          ),
                        ),
                      if (_canManageDefs)
                        IconButton(
                          tooltip: AppText.t(
                            'إعدادات الجودة',
                            'Quality settings',
                          ),
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () => _openSettings(context),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.page),
                  child: IndexedStack(
                    index: _selectedTab,
                    children: [
                      for (var index = 0; index < allTabs.length; index++)
                        _LazyQualityTab(
                          key: ValueKey('quality-tab-$index'),
                          active: _selectedTab == index,
                          builder: allTabs[index].builder,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LazyQualityTab extends StatefulWidget {
  const _LazyQualityTab({
    super.key,
    required this.active,
    required this.builder,
  });

  final bool active;
  final WidgetBuilder builder;

  @override
  State<_LazyQualityTab> createState() => _LazyQualityTabState();
}

class _LazyQualityTabState extends State<_LazyQualityTab> {
  late bool _visited = widget.active;

  @override
  void didUpdateWidget(covariant _LazyQualityTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) _visited = true;
  }

  @override
  Widget build(BuildContext context) =>
      _visited ? widget.builder(context) : const SizedBox.shrink();
}
