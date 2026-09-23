import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../app/auth_gate.dart';
import '../../../core/services/seed_service.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../di/service_locator.dart';
import '../../backup/data/backup_manager.dart';

/// Migration wizard (port of Web Settings DatabasePanel "Import from external
/// DB" sections): import users+inspections, users only, or materials+units.
class MigrationPanel extends StatefulWidget {
  const MigrationPanel({super.key});

  @override
  State<MigrationPanel> createState() => _MigrationPanelState();
}

class _MigrationPanelState extends State<MigrationPanel> {
  final _backup = getIt<BackupManager>();
  String? _combinedPath;
  String? _usersPath;
  String? _materialsPath;
  String? _busyKey;

  String get _developerName => getIt<AuthGate>().currentUser?.username ?? '';

  Future<void> _pick(String target) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
      dialogTitle: 'اختر ملف قاعدة البيانات',
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() {
      switch (target) {
        case 'combined':
          _combinedPath = path;
        case 'users':
          _usersPath = path;
        case 'materials':
          _materialsPath = path;
      }
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    required bool danger,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                : null,
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _run(String key, Future<String> Function() action) async {
    setState(() => _busyKey = key);
    try {
      final message = await action();
      if (!mounted) return;
      if (message.isNotEmpty) AppFeedback.success(context, message);
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _importCombined() async {
    final path = _combinedPath;
    if (path == null) {
      AppFeedback.error(context, 'اختر قاعدة بيانات أولاً');
      return;
    }
    final ok = await _confirm(
      title: 'استيراد المستخدمين والفحوصات',
      message: 'سيتم استيراد المستخدمين الجدد والفحوصات فقط من قاعدة البيانات المحددة. '
          'الخامات المطلوبة تُنشأ تلقائياً. لا تتأثر الإعدادات أو البيانات المرجعية الموجودة.\n'
          'Only new users and inspections will be imported. Required materials are auto-created.',
      confirmText: 'استيراد',
      danger: false,
    );
    if (!ok) return;
    await _run('combined', () async {
      final users = await _backup.pullUsersFromSourceDb(
        sourceDbPath: path,
        developerName: _developerName,
      );
      final inspections =
          await _backup.importInspectionsFromSource(sourceDbPath: path);
      return 'تم استيراد ${users['users_copied']} مستخدم و $inspections فحص. '
          'Imported ${users['users_copied']} users and $inspections inspections.';
    });
  }

  Future<void> _importUsers() async {
    final path = _usersPath;
    if (path == null) {
      AppFeedback.error(context, 'اختر قاعدة بيانات أولاً');
      return;
    }
    final ok = await _confirm(
      title: 'استيراد المستخدمين',
      message: 'سيتم نسخ المستخدمين من الملف المحدد إلى القاعدة المحلية. '
          'المستخدمون الموجودون مسبقاً لن يتأثروا.\n'
          'Existing users will not be affected.',
      confirmText: 'استيراد',
      danger: false,
    );
    if (!ok) return;
    await _run('users', () async {
      await _backup.validateBackupDatabase(path);
      final result = await _backup.pullUsersFromSourceDb(
        sourceDbPath: path,
        developerName: _developerName,
      );
      final parts = ['تم نسخ ${result['users_copied']} مستخدم جديد'];
      if ((result['users_skipped'] as num? ?? 0) > 0) {
        parts.add('تم تخطي ${result['users_skipped']} مستخدم موجود سابقاً');
      }
      if ((result['legacy_count'] as num? ?? 0) > 0) {
        parts.add('${result['legacy_count']} كلمة مرور قديمة (سيتم ترقيتها عند أول تسجيل دخول)');
      }
      if ((result['v2_count'] as num? ?? 0) > 0) {
        parts.add('${result['v2_count']} كلمة مرور مشفرة من جهاز آخر (قد تحتاج إعادة تعيين)');
      }
      return '${parts.join('. ')}.';
    });
  }

  Future<void> _importMaterials() async {
    final path = _materialsPath;
    if (path == null) {
      AppFeedback.error(context, 'اختر قاعدة بيانات أولاً');
      return;
    }
    final ok = await _confirm(
      title: 'استيراد الخامات والوحدات',
      message: 'سيتم دمج الخامات والوحدات من قاعدة البيانات المحددة بشكل تراكمي (تحديث حسب الاسم). '
          'لن تتغير الإعدادات أو المسارات المحلية.\n'
          'Materials and units will be upserted by name. Settings stay unchanged.',
      confirmText: 'استيراد',
      danger: false,
    );
    if (!ok) return;
    await _run('materials', () async {
      await _backup.validateMaterialsDatabase(path);
      final result = await _backup.importMaterialsDatabase(
        sourceDbPath: path,
        importUnits: getIt<SeedService>().importUnits,
      );
      final message = '${result['message'] ?? ''}';
      return message.isEmpty
          ? 'تم استيراد ${result['materials']} خامة و ${result['parameters']} وحدة. '
              'Imported ${result['materials']} materials and ${result['parameters']} units.'
          : message;
    });
  }

  Widget _row(String label, String? path, String pickKey, String importKey,
      VoidCallback onImport) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.borderMuted),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  path?.isNotEmpty == true ? path! : '—',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(
              onPressed: _busyKey != null ? null : () => _pick(pickKey),
              child: const Text('اختيار'),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              small: true,
              label: 'استيراد',
              icon: Icon(Icons.import_export, size: 16.r),
              loading: _busyKey == importKey,
              onPressed: _busyKey != null ? null : onImport,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'استيراد من قاعدة بيانات خارجية',
          style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'وتستورد المستخدمين والفحوصات أو الخامات من قاعدة بيانات أخرى، لترقية البيانات إلى النسخة الجديدة من البرنامج.',
          style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        _row(
          'مستخدمين وفحوصات',
          _combinedPath,
          'combined',
          'combined',
          _importCombined,
        ),
        const SizedBox(height: AppSpacing.lg),
        _row(
          'مستخدمين فقط',
          _usersPath,
          'users',
          'users',
          _importUsers,
        ),
        const SizedBox(height: AppSpacing.lg),
        _row(
          'خامات ووحدات',
          _materialsPath,
          'materials',
          'materials',
          _importMaterials,
        ),
      ],
    );
  }
}