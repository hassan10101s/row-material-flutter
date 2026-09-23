import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/logo_encoding.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_dialogs.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../di/service_locator.dart';
import '../../../router/app_router.dart';
import '../../auth/domain/user.dart';
import '../../backup/data/backup_manager.dart';
import 'cubit/database_settings_cubit.dart';
import 'cubit/database_settings_state.dart';
import 'cubit/general_settings_cubit.dart';
import 'cubit/general_settings_state.dart';
import 'cubit/users_cubit.dart';
import 'migration_panel.dart';
import '../data/settings_repo.dart';
/// Settings (port of Web SettingsView: General / Export / Database / Users).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}
class _SettingsScreenState extends State<SettingsScreen> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    final user = getIt<AuthGate>().currentUser;
    final canDev = user?.isDeveloper ?? false;
return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الإعدادات',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          _SettingsTabs(
            current: _tab,
            devMode: canDev,
            onChange: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: switch (_tab) {
              0 => BlocProvider(
                  create: (c) =>
                      GeneralSettingsCubit(repo: getIt<SettingsRepo>())..load(),
                  child: const _GeneralPanel(),
                ),
              1 => BlocProvider(
                  create: (c) =>
                      DatabaseSettingsCubit(backup: getIt<BackupManager>()),
                  child: const _DatabasePanel(),
                ),
              2 => BlocProvider(
                  create: (c) => UsersCubit(repo: getIt<SettingsRepo>())..load(),
                  child: const _UsersPanel(),
                ),
              _ => const _ExportBackupsPanel(),
            },
          ),
        ],
      ),
    );
  }
}
class _SettingsTabs extends StatelessWidget {
  final int current;
  final bool devMode;
  final ValueChanged<int> onChange;
  const _SettingsTabs({
    required this.current,
    required this.devMode,
    required this.onChange,
  });
  @override
  Widget build(BuildContext context) {
    final tabs = <(String, String)>[
      ('عام', 'الإعدادات العامة'),
      ('قاعدة البيانات', 'نسخ واستعادة'),
    ];
    if (devMode) {
      tabs.add(('الأمان', '')); // dev-only: placeholder
    }
    tabs.add(('المستخدمون', 'إدارة الحسابات'));
    tabs.add(('التصدير', 'نسخ احتياطية يدوية'));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < tabs.length; i++)
          ChoiceChip(
            selected: current == i,
            label: Text(tabs[i].$1),
            onSelected: (_) => onChange(i),
selectedColor: AppColors.primary,
            backgroundColor: AppColors.surface,
            labelStyle: TextStyle(
              color: current == i
                  ? Theme.of(context).colorScheme.onPrimary
                  : AppColors.textStrong,
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
        text: context.read<GeneralSettingsCubit>().state.departmentLabel);
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
      AppFeedback.success(context, 'تم الحفظ');
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) _err(context, '$e');
    }
  }
  void _err(BuildContext context, String message) {
    AppFeedback.error(context, message);
  }
  Future<void> _pickLogo() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
      dialogTitle: 'اختر شعار التقرير',
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final dataUri = encodeReportLogoDataUri(path);
      await context.read<GeneralSettingsCubit>().saveLogo(path: path, dataUri: dataUri);
      if (!mounted) return;
      AppFeedback.success(context, 'تم حفظ الشعار');
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (_) {
      if (mounted) AppFeedback.error(context, 'تعذر قراءة الصورة');
    }
  }
  Future<void> _removeLogo() async {
    await context.read<GeneralSettingsCubit>().clearLogo();
    if (!mounted) return;
    AppFeedback.success(context, 'تمت إزالة الشعار');
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<GeneralSettingsCubit>().state;
    return BlocListener<GeneralSettingsCubit, GeneralSettingsState>(
      listenWhen: (prev, curr) => prev.loading && !curr.loading,
      listener: (context, state) => _dept.text = state.departmentLabel,
      child: _Panel(
        children: [
          if (state.loading)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()))
          else ...[
            Text(
              'إدارة عامة',
              style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.md),
AppField(
              label: 'اسم القسم في التقارير',
              controller: _dept,
            ),
            const SizedBox(height: AppSpacing.md),
_ReportLogoSection(
              path: state.logoPath,
              dataUri: state.logoDataUri,
              onPick: _pickLogo,
              onRemove: _removeLogo,
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: AppStrings.save,
              loading: state.saving,
              onPressed: state.saving ? null : _save,
            ),
          ],
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'شعار التقرير',
          style: TextStyle(fontSize: 14.spMax, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
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
                  hasLogo ? path.split('\\').last.split('/').last : 'لا يوجد شعار',
                  style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    AppButton(
                      label: 'اختيار',
                      icon: Icon(Icons.image_outlined, size: 16.r),
                      onPressed: onPick,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (hasLogo)
                      AppButton(
                        label: 'إزالة',
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
      dialogTitle: 'اختر ملف النسخة الاحتياطية',
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    final confirm = await _confirmRestore(context);
    if (!confirm) return;
    await cubit.restoreBackup(path);
    if (!context.mounted) return;
if (cubit.state.error == null) {
      getIt<AuthGate>().auth.logout();
      getIt<AuthGate>().updated();
      context.go(AppRoutes.login);
      AppFeedback.info(
        context,
        'تمت الاستعادة — سيتم تسجيل الخروج الآن',
      );
    }
  }
  Future<bool> _confirmRestore(BuildContext context) {
    return showAppConfirm(
      context,
      title: 'تأكيد الاستعادة',
      message:
          'سيتم استبدال قاعدة البيانات الحالية بالنسخة الاحتياطية بعد عمل نسخة أمان تلقائية. '
          'سيتم تسجيل الخروج بعد الاستعادة.\n'
          'The current database will be replaced with the backup, after an automatic safety copy. '
          'You will be logged out.',
      confirmLabel: 'استعادة',
      cancelLabel: 'إلغاء',
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
          (curr.lastPath != null && curr.lastPath != prev.lastPath),
listener: (context, state) {
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
        } else if (state.lastPath != null) {
          AppFeedback.success(
            context,
            'تم إنشاء النسخة الاحتياطية: ${state.lastPath}',
          );
        }
      },
      child: _Panel(
        children: [
          Text(
            'قاعدة البيانات',
            style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'نسخة احتياطية واستعادة قاعدة البيانات. تشمل الاستعادة ترقية تلقائية لهيكل النسخة القديمة.',
            style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
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
          const SizedBox(height: AppSpacing.lg),
          const Divider(),
          const SizedBox(height: AppSpacing.lg),
          const MigrationPanel(),
        ],
      ),
    );
  }
}
class _ExportBackupsPanel extends StatelessWidget {
  const _ExportBackupsPanel();
  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      icon: Icons.folder_open,
      title: 'نسخ احتياطية',
      subtitle: 'تُنشأ النسخ الاحتياطية التلقائية يومياً في مجلد exports/backups.',
    );
  }
}
class _UsersPanel extends StatefulWidget {
  const _UsersPanel();
  @override
  State<_UsersPanel> createState() => _UsersPanelState();
}
class _UsersPanelState extends State<_UsersPanel> {
  final _username = TextEditingController();
  final _fullName = TextEditingController();
  final _password = TextEditingController();
  String _role = 'Lab User';
  @override
  void dispose() {
    _username.dispose();
    _fullName.dispose();
    _password.dispose();
    super.dispose();
  }
  Future<void> _create() async {
    final cubit = context.read<UsersCubit>();
    final ok = await cubit.createUser(
      username: _username.text.trim(),
      fullName: _fullName.text.trim(),
      password: _password.text,
      role: _role,
    );
    if (!mounted) return;
if (ok) {
      _username.clear();
      _fullName.clear();
      _password.clear();
      AppFeedback.success(context, 'تمت الإضافة');
    } else if (cubit.state.error != null) {
      AppFeedback.error(context, cubit.state.error!);
    }
  }
  Future<void> _delete(User user) async {
    if (user.isDeveloper) return;
    final ok = await showAppConfirm(
      context,
      title: 'حذف المستخدم',
      message: 'حذف ${user.fullName}؟',
      confirmLabel: 'حذف',
      cancelLabel: 'إلغاء',
      danger: true,
      icon: Icons.person_off_outlined,
    );
    if (!ok || !mounted) return;
    final cubit = context.read<UsersCubit>();
    final deleted = await cubit.deleteUser(user.id!);
    if (!mounted || deleted) return;
    if (cubit.state.error != null) {
      AppFeedback.error(context, cubit.state.error!);
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<UsersCubit>().state;
    final dev = getIt<AuthGate>().currentUser?.isDeveloper ?? false;
    return _Panel(
      children: [
        Text(
          'المستخدمون',
          style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.loading)
          const Center(child: CircularProgressIndicator())
        else if (state.error != null)
          Text(state.error!, style: TextStyle(color: AppColors.danger))
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final u in state.users)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
leading: Builder(builder: (context) {
                        final isNeutral = !u.isDeveloper && !u.canSeeSettings;
                        return CircleAvatar(
                          backgroundColor: u.isDeveloper
                              ? AppColors.warning
                              : u.canSeeSettings
                                  ? AppColors.primary
                                  : AppColors.borderMuted,
                          child: Text(
                            u.username.isEmpty
                                ? '?'
                                : u.username.substring(0, 1).toUpperCase(),
                            style: TextStyle(
                              color: isNeutral
                                  ? AppColors.textStrong
                                  : Colors.white,
                              fontSize: 14.spMax,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }),
                      title: Text('${u.fullName} — ${u.role}'),
                      subtitle: Text('@${u.username}'),
                      trailing: u.isDeveloper
                          ? Icon(Icons.lock, size: 16.r, color: AppColors.warning)
                          : IconButton(
                              icon: Icon(Icons.delete_outline, size: 18.r),
                              onPressed: () => _delete(u),
                            ),
                    ),
                ],
              ),
            ),
          ),
        if (dev) ...[
          const SizedBox(height: AppSpacing.lg),
          Text(
            'إضافة مستخدم',
            style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              SizedBox(
                  width: 220.w,
                  child: AppField(label: 'المستخدم', controller: _username)),
              SizedBox(
                  width: 220.w,
                  child: AppField(label: 'الاسم الكامل', controller: _fullName)),
              SizedBox(
                  width: 180.w,
                  child: AppField(label: 'كلمة المرور', controller: _password, obscure: true)),
              SizedBox(
                width: 180.w,
                child: DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: 'الدور', isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'Admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'Lab User', child: Text('Lab User')),
                    DropdownMenuItem(value: 'Viewer', child: Text('Viewer')),
                  ],
                  onChanged: (v) => setState(() => _role = v ?? 'Lab User'),
                ),
              ),
              SizedBox(
                height: 42.h,
                child: AppButton(
                  label: AppStrings.save,
                  loading: state.busy,
                  onPressed: state.busy ? null : _create,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
class _Panel extends StatelessWidget {
  final List<Widget> children;
  const _Panel({required this.children});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(20), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      )),
    );
  }
}