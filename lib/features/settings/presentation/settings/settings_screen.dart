import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/app_paths.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/locale/locale_service.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../di/platform_ports.dart';
import '../../../../core/utils/logo_encoding.dart';

import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../di/service_locator.dart';
import '../../../../router/app_router.dart';
import '../../../backup/domain/backup_service.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../members/presentation/members/leave_organization_section.dart';
import '../../../members/presentation/members/members_screen.dart';
import '../../../sync/presentation/sync/sync_screen.dart';
import '../cubit/database_settings_cubit.dart';
import '../cubit/database_settings_state.dart';
import '../cubit/general_settings_cubit.dart';
import '../cubit/general_settings_state.dart';
import 'migration_panel.dart';
import '../../domain/settings_repository.dart';

/// Deep-linkable Settings sections, reachable as `/settings?tab=<key>`.
enum SettingsTab {
  general('general', 'عام', 'General', 'الإعدادات العامة', 'General settings'),
  database('database', 'قاعدة البيانات', 'Database', 'نسخ واستعادة', 'Backup and restore'),
  members('members', 'الأعضاء', 'Members', 'إدارة حسابات المؤسسة', 'Organization accounts'),
  sync('sync', 'المزامنة', 'Sync', 'حالة المزامنة والتعارضات', 'Sync status and conflicts'),
  export('export', 'التصدير', 'Export', 'نسخ احتياطية يدوية', 'Manual backups');

  const SettingsTab(this.key, this.labelAr, this.labelEn, this.subtitleAr, this.subtitleEn);

  final String key;
  final String labelAr;
  final String labelEn;
  final String subtitleAr;
  final String subtitleEn;

  String get label => AppText.t(labelAr, labelEn);
  String get subtitle => AppText.t(subtitleAr, subtitleEn);

  static SettingsTab fromKey(String? key) => SettingsTab.values.firstWhere(
    (tab) => tab.key == key,
    orElse: () => SettingsTab.general,
  );
}

/// Settings (port of Web SettingsView: General / Database / Members / Sync /
/// Export). Members and Sync used to be top-level sidebar destinations; they
/// are sections of this screen now.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialTab = SettingsTab.general});

  final SettingsTab initialTab;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsTab _tab = widget.initialTab;

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _tab = widget.initialTab;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('الإعدادات', 'Settings'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          _SettingsTabs(
            current: _tab,
            onChange: (tab) => setState(() => _tab = tab),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() => switch (_tab) {
    SettingsTab.general => BlocProvider(
      create: (c) =>
          GeneralSettingsCubit(repo: getIt<SettingsRepository>())..load(),
      child: const _GeneralPanel(),
    ),
    SettingsTab.database => BlocProvider(
      create: (c) => DatabaseSettingsCubit(
        backup: getIt<BackupService>(),
        engine: getIt<SyncEngine>(),
      ),
      child: const _DatabasePanel(),
    ),
    SettingsTab.members => const _MembersPanel(),
    SettingsTab.sync => const SyncScreen(embedded: true),
    SettingsTab.export => const _ExportBackupsPanel(),
  };
}

/// Every section is always listed. A `lab` or `viewer` member cannot manage the
/// roster, but they must still see their own membership and be able to leave,
/// so the tab is never hidden from them.
class _SettingsTabs extends StatelessWidget {
  const _SettingsTabs({required this.current, required this.onChange});

  final SettingsTab current;
  final ValueChanged<SettingsTab> onChange;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tab in SettingsTab.values)
          Tooltip(
            message: tab.subtitle,
            child: ChoiceChip(
              selected: current == tab,
              label: Text(tab.label),
              onSelected: (_) => onChange(tab),
              selectedColor: AppColors.primary,
              backgroundColor: AppColors.surface,
              labelStyle: TextStyle(
                color: current == tab
                    ? Theme.of(context).colorScheme.onPrimary
                    : AppColors.textStrong,
              ),
            ),
          ),
      ],
    );
  }
}

class _GeneralPanel extends StatefulWidget {
  const _GeneralPanel();
  @override
  State<_GeneralPanel> createState() => _GeneralPanelState();
}

class _GeneralPanelState extends State<_GeneralPanel> {
  late final TextEditingController _dept;
  @override
  void initState() {
    super.initState();
    _dept = TextEditingController(
      text: context.read<GeneralSettingsCubit>().state.departmentLabel,
    );
  }

  @override
  void dispose() {
    _dept.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await context.read<GeneralSettingsCubit>().save(_dept.text.trim());
      if (!mounted) return;
      AppFeedback.success(context, AppText.t('تم الحفظ', 'Saved'));
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  Future<void> _pickLogo() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
      dialogTitle: AppText.t('اختر شعار التقرير', 'Choose the report logo'),
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final dataUri = encodeReportLogoDataUri(path);
      await context.read<GeneralSettingsCubit>().saveLogo(
        path: path,
        dataUri: dataUri,
      );
      if (!mounted) return;
      AppFeedback.success(context, AppText.t('تم حفظ الشعار', 'Logo saved'));
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (_) {
      if (mounted) {
        AppFeedback.error(
            context, AppText.t('تعذر قراءة الصورة', 'Could not read the image'));
      }
    }
  }

  Future<void> _removeLogo() async {
    await context.read<GeneralSettingsCubit>().clearLogo();
    if (!mounted) return;
    AppFeedback.success(context, AppText.t('تمت إزالة الشعار', 'Logo removed'));
  }

  /// Pick the folder where report PDFs are saved (`export_root_path`).
  Future<void> _pickExportPath() async {
    final picker = folderPicker();
    if (!picker.supported) {
      // Guarded here as well as in the UI: the button can still be reached by
      // keyboard, and a silent no-op picker is indistinguishable from a hang.
      if (!mounted) return;
      AppFeedback.info(
        context,
        AppText.t(
          'لا يمكن اختيار مجلد على هذا الجهاز، يتم الحفظ داخل مساحة التطبيق',
          'This device cannot choose a folder; reports are saved inside the app',
        ),
      );
      return;
    }
    final current = context.read<GeneralSettingsCubit>().state.exportRootPath;
    final picked = await picker.pick(
      startDirectory: current.isEmpty ? null : current,
      dialogTitle: AppText.t(
        'اختر مجلد حفظ التقارير',
        'Choose reports save folder',
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await context.read<GeneralSettingsCubit>().saveExportRootPath(picked);
      if (!mounted) return;
      AppFeedback.success(
        context,
        AppText.t('تم حفظ مجلد الحفظ', 'Save folder updated'),
      );
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  /// Open the configured folder in the file manager; falls back to the app's
  /// default exports folder when none is configured.
  Future<void> _openExportPath() async {
    String? path = context.read<GeneralSettingsCubit>().state.exportRootPath;
    if (path.isEmpty) {
      try {
        path = (await getIt<AppPaths>().exportsRoot()).path;
      } catch (_) {
        if (mounted) {
          AppFeedback.error(
            context,
            AppText.t('تعذر فتح المجلد', 'Could not open the folder'),
          );
        }
        return;
      }
    }
    if (!fileDelivery().canReveal) return;
    final opened = await fileDelivery().reveal(path);
    if (!opened && mounted) {
      AppFeedback.error(
        context,
        AppText.t('تعذر فتح المجلد', 'Could not open the folder'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GeneralSettingsCubit>().state;
    return BlocListener<GeneralSettingsCubit, GeneralSettingsState>(
      listenWhen: (prev, curr) => prev.loading && !curr.loading,
      listener: (context, state) => _dept.text = state.departmentLabel,
      child: _Panel(
        children: [
          if (state.loading && state.departmentLabel.isEmpty)
            const AppSkeletonList(rows: 3, lines: 2, height: 220)
          else ...[
            _TwoColumn(
              children: [
                _SettingsCard(
                  title: AppText.t(
                    'القسم والتقارير',
                    'Department & reports',
                  ),
                  children: [
                    AppField(
                      label: AppText.t(
                        'اسم القسم في التقارير',
                        'Department name on reports',
                      ),
                      controller: _dept,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      label: AppStrings.save,
                      loading: state.saving,
                      onPressed: state.saving ? null : _save,
                    ),
                  ],
                ),
                const _AppearanceSection(),
                _SettingsCard(
                  title: AppText.t('شعار التقرير', 'Report logo'),
                  children: [
                    _ReportLogoSection(
                      path: state.logoPath,
                      dataUri: state.logoDataUri,
                      onPick: _pickLogo,
                      onRemove: _removeLogo,
                    ),
                  ],
                ),
                _SettingsCard(
                  title: AppText.t(
                    'مجلد حفظ تقارير PDF',
                    'PDF reports folder',
                  ),
                  children: [
                    _ExportPathSection(
                      path: state.exportRootPath,
                      canPick: folderPicker().supported,
                      canOpen: fileDelivery().canReveal,
                      onPick: _pickExportPath,
                      onOpen: _openExportPath,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Theme and language controls.
///
/// These were previously reachable only from the compact top-bar toggle, which
/// cycles light -> dark -> system with no labels, and from a second,
/// never-read theme store in `token_storage.dart`. Settings is the discoverable
/// home for them.
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final themeService = getIt<ThemeService>();
    final localeService = getIt<LocaleService>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppText.t('المظهر واللغة', 'Appearance & language'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(AppText.t('السمة', 'Theme'),
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            // SegmentedButton shows all three states at once, unlike the
            // top-bar toggle which can only imply the current one.
            SegmentedButton<ThemeMode>(
              segments: [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: const Icon(Icons.brightness_auto, size: 18),
                  label: Text(AppText.t('النظام', 'System')),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: const Icon(Icons.light_mode_outlined, size: 18),
                  label: Text(AppText.t('فاتح', 'Light')),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: const Icon(Icons.dark_mode_outlined, size: 18),
                  label: Text(AppText.t('داكن', 'Dark')),
                ),
              ],
              selected: {themeService.mode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  themeService.setMode(selection.first),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(AppText.t('اللغة', 'Language'),
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<Locale>(
              segments: [
                ButtonSegment(
                    value: const Locale('ar'),
                    label: Text(AppText.t('العربية', 'Arabic'))),
                const ButtonSegment(
                    value: Locale('en'), label: Text('English')),
              ],
              selected: {localeService.locale},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  localeService.setLocale(selection.first),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportLogoSection extends StatelessWidget {
  final String path;
  final String dataUri;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  const _ReportLogoSection({
    required this.path,
    required this.dataUri,
    required this.onPick,
    required this.onRemove,
  });
  @override
  Widget build(BuildContext context) {
    final hasLogo = dataUri.isNotEmpty;
    // The title lives on the wrapping card; this only lays out the preview.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8.r),
              child: hasLogo
                  ? Image.memory(
                      _logoBytes,
                      width: 96.r,
                      height: 48.r,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => _placeholder(),
                    )
                  : _placeholder(),
            ),
            const SizedBox(width: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasLogo
                      ? path.split('\\').last.split('/').last
                      : AppText.t('لا يوجد شعار', 'No logo'),
                  style: TextStyle(
                    fontSize: 13.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    AppButton(
                      label: AppText.t('اختيار', 'Choose'),
                      icon: Icon(Icons.image_outlined, size: 16.r),
                      onPressed: onPick,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (hasLogo)
                      AppButton(
                        label: AppText.t('إزالة', 'Remove'),
                        style: AppButtonStyle.secondary,
                        icon: Icon(Icons.close, size: 16.r),
                        onPressed: onRemove,
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _placeholder() => Container(
    width: 96.r,
    height: 48.r,
    color: AppColors.borderMuted,
    alignment: Alignment.center,
    child: Icon(Icons.image_outlined, size: 20.r, color: AppColors.textMuted),
  );
  Uint8List get _logoBytes =>
      base64Decode(dataUri.substring(dataUri.indexOf(',') + 1));
}

class _ExportPathSection extends StatelessWidget {
  final String path;
  final VoidCallback onPick;
  final VoidCallback onOpen;

  /// Whether this platform can choose a save folder. False on Android, where
  /// the app has no folder picker and no permission to write outside its
  /// sandbox - the button is hidden rather than shown and ignored.
  final bool canPick;

  /// Whether this platform can show a file manager on that folder.
  final bool canOpen;

  const _ExportPathSection({
    required this.path,
    required this.onPick,
    required this.onOpen,
    required this.canPick,
    required this.canOpen,
  });

  @override
  Widget build(BuildContext context) {
    final tail = path.split('\\').last.split('/').last;
    // The title lives on the wrapping card; this only lays out the rows.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          path.isNotEmpty
              ? tail
              : AppText.t(
                  'غير محدد — سيتم الحفظ في مجلد التطبيق الافتراضي',
                  'Not set — reports are saved to the app default folder',
                ),
          style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
        ),
        // Explain the fixed location instead of leaving an unexplained missing
        // button: on mobile the location is a deliberate choice, not a setting
        // the user forgot.
        if (!canPick)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              AppText.t(
                'يُحفظ في مساحة التطبيق على هذا الجهاز، ويمكن مشاركته عند إنشاء التقرير',
                'On this device reports are saved inside the app and can be shared when created',
              ),
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            ),
          ),
        if (canPick || canOpen)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            // A `Wrap` rather than a `Row`: two labelled Arabic buttons do not
            // fit side by side on a 400dp phone, and a Row would clip the second
            // one instead of dropping it to the next line.
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (canPick)
                  AppButton(
                    label: AppText.t('اختيار مجلد', 'Choose folder'),
                    icon: Icon(Icons.folder_open_outlined, size: 16.r),
                    onPressed: onPick,
                  ),
                if (canOpen)
                  AppButton(
                    label: AppText.t('فتح', 'Open'),
                    style: AppButtonStyle.secondary,
                    icon: Icon(Icons.launch, size: 16.r),
                    onPressed: onOpen,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DatabasePanel extends StatelessWidget {
  const _DatabasePanel();
  Future<void> _export(BuildContext context) async {
    final cubit = context.read<DatabaseSettingsCubit>();
    if (cubit.state.busy) return;
    await cubit.exportBackup();
  }

  Future<void> _restore(BuildContext context) async {
    final cubit = context.read<DatabaseSettingsCubit>();
    if (cubit.state.busy) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
      dialogTitle: AppText.t(
        'اختر ملف النسخة الاحتياطية',
        'Choose the backup file',
      ),
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    final confirm = await _confirmRestore(context);
    if (!confirm) return;
    await cubit.restoreBackup(path);
    if (!context.mounted) return;
    if (cubit.state.error == null) {
      // A restore replaces the database underneath the session: sign out and
      // let the auth flow rebuild the per-organization binding (plan P11.2).
      await getIt<AuthGate>().auth.signOut();
      getIt<AuthGate>().updated();
      if (context.mounted) context.go(AppRoutes.login);
      if (!context.mounted) return;
      // Never let a restore look silently complete: anything the reconciliation
      // had to flag is stated in the message (plan §14-P11.2).
      AppFeedback.info(context, _restoreMessage(cubit.state));
    }
  }

  static String _restoreMessage(DatabaseSettingsState state) {
    final notes = <String>[
      if (state.restoreConflicts > 0)
        '${state.restoreConflicts} ${AppText.t(
          'سجل مُنشأ تعارضاً لأنه غير موجود في النسخة',
          'records conflicted as missing from the backup',
        )}',
      if (state.restoreRequeued > 0)
        '${state.restoreRequeued} ${AppText.t(
          'سجل أُعيد إلى قائمة المزامنة لإرساله',
          'records requeued for upload',
        )}',
    ];
    if (notes.isEmpty) {
      return AppText.t(
        'تمت الاستعادة — سيتم تسجيل الخروج الآن',
        'Restored — you will be logged out now',
      );
    }
    return '${AppText.t('تمت الاستعادة', 'Restored')} — '
        '${notes.join(AppText.t('، ', ', '))}. '
        '${AppText.t('سيتم تسجيل الخروج الآن', 'You will be logged out now')}';
  }

  Future<bool> _confirmRestore(BuildContext context) {
    return showAppConfirm(
      context,
      title: AppText.t('تأكيد الاستعادة', 'Confirm restore'),
      message: AppText.t(
        'سيتم استبدال قاعدة البيانات الحالية بالنسخة الاحتياطية بعد عمل نسخة أمان تلقائية. '
        'سيتم تسجيل الخروج بعد الاستعادة.',
        'The current database will be replaced with the backup, after an automatic safety copy. '
        'You will be logged out.',
      ),
      confirmLabel: AppText.t('استعادة', 'Restore'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
      danger: true,
      icon: Icons.restore,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DatabaseSettingsCubit>().state;
    return BlocListener<DatabaseSettingsCubit, DatabaseSettingsState>(
      listenWhen: (prev, curr) =>
          (curr.error != null && curr.error != prev.error) ||
          (curr.lastPath != null && curr.lastPath != prev.lastPath) ||
          (curr.restored && !prev.restored),
      listener: (context, state) {
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
        } else if (state.lastPath != null) {
          AppFeedback.success(
            context,
            '${AppText.t('تم إنشاء النسخة الاحتياطية', 'Backup created')}: '
            '${state.lastPath}',
          );
        }
      },
      child: _Panel(
        children: [
          _TwoColumn(
            children: [
              _SettingsCard(
                title: AppText.t('قاعدة البيانات', 'Database'),
                children: [
                  Text(
                    AppText.t(
                      'نسخة احتياطية واستعادة قاعدة البيانات. تشمل الاستعادة ترقية تلقائية لهيكل النسخة القديمة.',
                      'Back up and restore the database. Restoring automatically upgrades an old backup format.',
                    ),
                    style: TextStyle(
                      fontSize: 13.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.md,
                    children: [
                      AppButton(
                        label: AppStrings.backup,
                        icon: Icon(Icons.save_alt, size: 16.r),
                        loading: state.busy,
                        onPressed: state.busy ? null : () => _export(context),
                      ),
                      AppButton(
                        label: AppStrings.restore,
                        style: AppButtonStyle.secondary,
                        icon: Icon(Icons.restore, size: 16.r),
                        loading: state.busy,
                        onPressed: state.busy ? null : () => _restore(context),
                      ),
                    ],
                  ),
                ],
              ),
              Card(
                margin: EdgeInsets.zero,
                child: const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: MigrationPanel(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExportBackupsPanel extends StatelessWidget {
  const _ExportBackupsPanel();
  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.folder_open,
      title: AppText.t('نسخ احتياطية', 'Backups'),
      subtitle: AppText.t(
        'تُنشأ النسخ الاحتياطية التلقائية يومياً في مجلد exports/backups.',
        'Automatic backups are created daily in the exports/backups folder.',
      ),
    );
  }
}

/// Members live in Settings now (they used to be a top-level destination).
///
/// The content is role-adaptive: a role with `users.read` (owner, quality
/// manager) gets the full roster with invite / activate / change role /
/// remove plus the co-owner shortcut, while a `lab` or `viewer` member gets
/// only their own membership and the leave action — they hold no `users.*`
/// permission, and hiding the tab from them would leave no way out.
class _MembersPanel extends StatelessWidget {
  const _MembersPanel();

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    if (gate.canWrite(Permission.usersRead)) {
      return const MembersScreen(embedded: true);
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: const [
        LeaveOrganizationSection(),
        SizedBox(height: AppSpacing.md),
        _MembersReadOnlyNote(),
      ],
    );
  }
}

class _MembersReadOnlyNote extends StatelessWidget {
  const _MembersReadOnlyNote();

  @override
  Widget build(BuildContext context) {
    final role = getIt<AuthGate>().role;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        AppText.t(
          'دورك الحالي (${AppRoles.label(role)}) لا يعرض قائمة الأعضاء. '
              'تواصل مع مدير المؤسسة إن احتجت صلاحية إضافية.',
          'Your role (${AppRoles.label(role)}) cannot view the member roster. '
              'Ask an organization owner if you need more access.',
        ),
        style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
      ),
    );
  }
}

/// A section body: a card whose height is bounded by the tab area.
///
/// The sections are longer than the window they live in - General alone carries
/// a field, a theme picker, a logo picker and a folder picker - so the column
/// has to scroll rather than overflow. `Expanded` gives the panel a bounded
/// height, which is what lets the scroll view decide between "fits" and
/// "scrolls".
class _Panel extends StatelessWidget {
  final List<Widget> children;
  const _Panel({required this.children});
  @override
  Widget build(BuildContext context) {
    // The keyboard closes over the bottom of the panel: the department field
    // sits above the save button, so without the inset the button ends up
    // underneath the keyboard with no way to scroll it clear.
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Card(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + (keyboard > 0 ? keyboard + AppSpacing.md : 0),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// One settings block inside a panel: title plus content in a card.
class _SettingsCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SettingsCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 14.spMax,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Lays blocks in two columns on wide windows (desktop), one column on
/// phones — the panels used to stack everything in a single narrow column
/// even when half the window sat empty.
class _TwoColumn extends StatelessWidget {
  final List<Widget> children;
  const _TwoColumn({required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppBreakpoints.medium) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.md),
                children[i],
              ],
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += 2) {
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: children[i]),
                const SizedBox(width: AppSpacing.md),
                if (i + 1 < children.length)
                  Expanded(child: children[i + 1])
                else
                  const Spacer(),
              ],
            ),
          );
          rows.add(const SizedBox(height: AppSpacing.md));
        }
        return Column(children: rows);
      },
    );
  }
}
