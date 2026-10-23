import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_search_field.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../di/service_locator.dart';
import '../../domain/qc_custom_table.dart';
import '../../domain/qc_repositories.dart';
import '../cubit/qc_custom_tables_cubit.dart';
import 'qc_table_editor.dart';
import 'qc_table_records_screen.dart';

/// The QC hub's settings gear: every user-authored register with its edit /
/// delete actions and the create button. Tables themselves live in the hub's
/// chips; this screen only manages definitions.
///
/// It owns a fresh [QcCustomTablesCubit] (a factory in DI, each getIt call
/// creates one) and the hub refetches its defs when this closes, so the two
/// never drift apart.
class QcSettingsScreen extends StatelessWidget {
  const QcSettingsScreen._();

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const QcSettingsScreen._()));
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<QcCustomTablesCubit>(
      create: (_) => getIt<QcCustomTablesCubit>()..load(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(AppText.t('إعدادات الجودة', 'Quality settings')),
        ),
        body: const SafeArea(child: _SettingsBody()),
      ),
    );
  }
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody();

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  String _query = '';

  List<QcCustomTable> _filtered(List<QcCustomTable> tables) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return tables;
    return [
      for (final t in tables)
        if (t.title.toLowerCase().contains(q) ||
            t.description.toLowerCase().contains(q))
          t,
    ];
  }

  Future<void> _edit(BuildContext context, QcCustomTable table) async {
    final bundle = await getIt<QcCustomTablesRepository>().getTableBundle(
      table.tableId!,
    );
    if (!context.mounted) return;
    final saved = await showQcTableEditor(context, bundle);
    if (saved && context.mounted) {
      context.read<QcCustomTablesCubit>().refresh();
    }
  }

  Future<void> _create(BuildContext context) async {
    final saved = await showQcTableEditor(context);
    if (saved && context.mounted) {
      context.read<QcCustomTablesCubit>().refresh();
    }
  }

  Future<void> _delete(BuildContext context, QcCustomTable table) async {
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.delete_outline,
      title: AppText.t('حذف الجدول؟', 'Delete table?'),
      message: AppText.t(
        'سيحذف الجدول وأعمدته وتسجيلاته. لا يمكن التراجع.',
        'The table, its columns and its records will be deleted. '
            'This cannot be undone.',
      ),
      confirmLabel: AppText.t('حذف', 'Delete'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<QcCustomTablesCubit>().deleteTable(table.tableId!);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
    } catch (_) {}
  }

  Future<void> _openRecords(BuildContext context, QcCustomTable table) async {
    await QcTableRecordsScreen.open(context, table.tableId!);
    if (context.mounted) context.read<QcCustomTablesCubit>().refresh();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QcCustomTablesCubit, QcCustomTablesState>(
      listenWhen: (prev, curr) =>
          curr.error != null && curr.error != prev.error,
      listener: (context, state) {
        AppFeedback.error(context, state.error!);
        context.read<QcCustomTablesCubit>().clearError();
      },
      builder: (context, state) {
        final tables = _filtered(state.tables);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.pageMobile),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppText.t(
                        'جداول المستخدم — سجلات مخصوصة من إعدادك',
                        'User tables — registers of your own design',
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  AppButton(
                    small: true,
                    label: AppText.t('جدول جديد', 'New table'),
                    icon: Icon(Icons.add, size: 18.r),
                    onPressed: () => _create(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.pageMobile,
              ),
              child: DebouncedSearchField(
                hint: AppText.t('بحث بالاسم أو الوصف', 'Search name or...'),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (state.loading && state.tables.isEmpty)
              const Expanded(
                child: AppSkeletonList(rows: 4, lines: 2, height: 120),
              )
            else if (state.tables.isEmpty)
              Expanded(
                child: AppEmptyState(
                  icon: Icons.tune,
                  title: AppText.t(
                    'لا توجد جداول بعد — أنشئ أول جدول',
                    'No tables yet — create the first one',
                  ),
                  action: AppButton(
                    label: AppText.t('جدول جديد', 'New table'),
                    onPressed: () => _create(context),
                  ),
                ),
              )
            else if (tables.isEmpty)
              Expanded(
                child: AppEmptyState(
                  icon: Icons.search_off_outlined,
                  title: AppText.t(
                    'لا توجد جداول مطابقة للبحث',
                    'No tables match the search',
                  ),
                ),
              )
            else
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () =>
                      context.read<QcCustomTablesCubit>().refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.pageMobile,
                      vertical: AppSpacing.xs,
                    ),
                    itemCount: tables.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, i) {
                      final table = tables[i];
                      return _TableCard(
                        table: table,
                        onOpen: () => _openRecords(context, table),
                        onEdit: () => _edit(context, table),
                        onDelete: () => _delete(context, table),
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TableCard extends StatelessWidget {
  const _TableCard({
    required this.table,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final QcCustomTable table;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12.r),
        child: Row(
          children: [
            Container(
              width: 44.r,
              height: 44.r,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10.r),
              ),
              child: Icon(
                Icons.table_chart_outlined,
                size: 22.r,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    table.title,
                    style: TextStyle(
                      fontSize: 15.spMax,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (table.description.trim().isNotEmpty)
                    Text(
                      table.description,
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
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 20.r),
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Text(AppText.t('تعديل', 'Edit')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    AppText.t('حذف', 'Delete'),
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
