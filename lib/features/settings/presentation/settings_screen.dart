import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../di/service_locator.dart';
import '../../../router/app_router.dart';
import '../../auth/domain/user.dart';
import '../../backup/data/backup_manager.dart';
import '../../settings/data/settings_repo.dart';
import 'migration_panel.dart';

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
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الإعدادات | Settings',
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
              0 => const _GeneralPanel(),
              1 => const _DatabasePanel(),
              2 => const _UsersPanel(),
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
      ('عام | General', 'الإعدادات العامة'),
      ('قاعدة البيانات | Database', 'نسخ واستعادة'),
    ];
    if (devMode) {
      tabs.add(('الأمان | Security', '')); // dev-only: placeholder
    }
    tabs.add(('المستخدمون | Users', 'إدارة الحسابات'));
    tabs.add(('التصدير | Export', 'نسخ احتياطية يدوية'));

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
              color: current == i ? Colors.white : AppColors.textStrong,
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
  final _dept = TextEditingController();
  var _loading = true;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = getIt<SettingsRepo>();
    final label =
        (await repo.getSettingValue('department_label'))?.trim().isNotEmpty == true
            ? await repo.getSettingValue('department_label')
            : 'Quality Assurance Department';
    if (!mounted) return;
    _dept.text = label ?? 'Quality Assurance Department';
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await getIt<SettingsRepo>()
        .updateSettings({'department_label': _dept.text.trim()});
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم الحفظ | Saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Panel(
      children: [
        if (_loading)
          const Padding(
              padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else ...[
          const Text(
            'إدارة عامة | General',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.md),
          AppField(
            label: 'اسم القسم في التقارير | Department label',
            controller: _dept,
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: AppStrings.save,
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ],
    );
  }
}

class _DatabasePanel extends StatefulWidget {
  const _DatabasePanel();

  @override
  State<_DatabasePanel> createState() => _DatabasePanelState();
}

class _DatabasePanelState extends State<_DatabasePanel> {
  var _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final result = await getIt<BackupManager>().exportDatabaseBackup();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إنشاء النسخة الاحتياطية | Backup created: ${result['path']}')),
      );
    } on AppError catch (e) {
      if (mounted) _err(e.message);
    } catch (e) {
      if (mounted) _err('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
      dialogTitle: 'اختر ملف النسخة الاحتياطية | Pick a backup file',
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    final confirm = await _confirmRestore();
    if (!confirm) return;

    setState(() => _busy = true);
    try {
      await getIt<BackupManager>().restoreDatabaseBackup(path);
      getIt<AuthGate>().auth.logout();
      getIt<AuthGate>().updated();
      if (mounted) {
        context.go(AppRoutes.login);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تمت الاستعادة — سيتم تسجيل الخروج الآن | Restored, logging out')),
        );
      }
    } on AppError catch (e) {
      if (mounted) _err(e.message);
    } catch (e) {
      if (mounted) _err('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmRestore() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تأكيد الاستعادة | Confirm restore'),
        content: const Text(
            'سيتم استبدال قاعدة البيانات الحالية بالنسخة الاحتياطية بعد عمل نسخة أمان تلقائية. '
            'سيتم تسجيل الخروج بعد الاستعادة.\n'
            'The current database will be replaced with the backup, after an automatic safety copy. '
            'You will be logged out.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('إلغاء | Cancel')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('استعادة | Restore')),
        ],
      ),
    );
    return result ?? false;
  }

  void _err(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: AppColors.danger));
  }

  @override
  Widget build(BuildContext context) {
    return _Panel(
      children: [
        const Text(
          'قاعدة البيانات | Database',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'نسخة احتياطية واستعادة قاعدة البيانات. تشمل الاستعادة ترقية تلقائية لهيكل النسخة القديمة.',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            AppButton(
              label: AppStrings.backup,
              icon: const Icon(Icons.save_alt, size: 16),
              loading: _busy,
              onPressed: _busy ? null : _export,
            ),
            AppButton(
              label: AppStrings.restore,
              style: AppButtonStyle.secondary,
              icon: const Icon(Icons.restore, size: 16),
              loading: _busy,
              onPressed: _busy ? null : _restore,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const Divider(),
        const SizedBox(height: AppSpacing.lg),
        const MigrationPanel(),
      ],
    );
  }
}

class _ExportBackupsPanel extends StatelessWidget {
  const _ExportBackupsPanel();

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      icon: Icons.folder_open,
      title: 'نسخ احتياطية | Backups',
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
  List<User> _users = [];
  var _loading = true;
  String? _error;

  final _username = TextEditingController();
  final _fullName = TextEditingController();
  final _password = TextEditingController();
  var _role = 'Lab User';
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _username.dispose();
    _fullName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await getIt<SettingsRepo>().listUsers();
      if (!mounted) return;
      setState(() {
        _users = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      await getIt<SettingsRepo>().createUser(
        username: _username.text.trim(),
        fullName: _fullName.text.trim(),
        password: _password.text,
        role: _role,
      );
      _username.clear();
      _fullName.clear();
      _password.clear();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تمت الإضافة | User created')));
      }
    } catch (e) {
      if (mounted) _err('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(User user) async {
    if (user.isDeveloper) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('حذف المستخدم | Delete user'),
        content: Text('حذف ${user.fullName}؟ | Delete ${user.fullName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await getIt<SettingsRepo>().deleteUser(user.id!);
      await _load();
    } catch (e) {
      if (mounted) _err('$e');
    }
  }

  void _err(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: AppColors.danger));
  }

  @override
  Widget build(BuildContext context) {
    final dev = getIt<AuthGate>().currentUser?.isDeveloper ?? false;
    return _Panel(
      children: [
        const Text(
          'المستخدمون | Users',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_error != null)
          Text(_error!, style: TextStyle(color: AppColors.danger))
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final u in _users)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      leading: CircleAvatar(
                        backgroundColor: u.isDeveloper
                            ? AppColors.warning
                            : u.canSeeSettings
                                ? AppColors.primary
                                : AppColors.borderMuted,
                        child: Text(
                          u.username.isEmpty ? '?' : u.username.substring(0, 1).toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      title: Text('${u.fullName} — ${u.role}'),
                      subtitle: Text('@${u.username}'),
                      trailing: u.isDeveloper
                          ? Icon(Icons.lock, size: 16, color: AppColors.warning)
                          : IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => _delete(u),
                            ),
                    ),
                ],
              ),
            ),
          ),
        if (dev) ...[
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'إضافة مستخدم | Add user',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              SizedBox(width: 220, child: AppField(label: 'المستخدم | Username', controller: _username)),
              SizedBox(width: 220, child: AppField(label: 'الاسم الكامل | Full name', controller: _fullName)),
              SizedBox(width: 180, child: AppField(label: 'كلمة المرور | Password', controller: _password, obscure: true)),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: 'الدور | Role', isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'Admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'Lab User', child: Text('Lab User')),
                    DropdownMenuItem(value: 'Viewer', child: Text('Viewer')),
                  ],
                  onChanged: (v) => setState(() => _role = v ?? 'Lab User'),
                ),
              ),
              SizedBox(
                height: 42,
                child: AppButton(
                  label: AppStrings.save,
                  loading: _busy,
                  onPressed: _busy ? null : _create,
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