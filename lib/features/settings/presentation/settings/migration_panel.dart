import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/services/seed_service.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../di/service_locator.dart';
import '../../../backup/domain/backup_service.dart';

/// Migration wizard (port of Web Settings DatabasePanel "Import from external
/// DB" sections): import users+inspections, users only, or materials+units.
class MigrationPanel extends StatefulWidget {
  const MigrationPanel({super.key});

  @override
  State<MigrationPanel> createState() => _MigrationPanelState();
}

class _MigrationPanelState extends State<MigrationPanel> {
  final _backup = getIt<BackupService>();
  String? _combinedPath;
  String? _usersPath;
  String? _materialsPath;
  String? _busyKey;

  String get _developerName => getIt<AuthGate>().currentUser?.username ?? '';

  Future<void> _pick(String target) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
      dialogTitle: AppText.t(
        'اختر ملف قاعدة البيانات',
        'Choose the database file',
      ),
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
  }) {
    return showAppConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: confirmText,
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
      danger: danger,
    );
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
      if (mounted) AppFeedback.errorFrom(context, e);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  static String get _needDbFirst =>
      AppText.t('اختر قاعدة بيانات أولاً', 'Choose a database first');

  Future<void> _importCombined() async {
    final path = _combinedPath;
    if (path == null) {
      AppFeedback.error(context, _needDbFirst);
      return;
    }
    final ok = await _confirm(
      title: AppText.t(
        'استيراد المستخدمين والفحوصات',
        'Import users and inspections',
      ),
      message: AppText.t(
        'سيتم استيراد المستخدمين الجدد والفحوصات فقط من قاعدة البيانات المحددة. '
        'الخامات المطلوبة تُنشأ تلقائياً. لا تتأثر الإعدادات أو البيانات المرجعية الموجودة.',
        'Only new users and inspections will be imported from the chosen database. '
        'Required materials are auto-created. Existing settings and reference data are untouched.',
      ),
      confirmText: AppText.t('استيراد', 'Import'),
      danger: false,
    );
    if (!ok) return;
    await _run('combined', () async {
      final users = await _backup.pullUsersFromSourceDb(
        sourceDbPath: path,
        developerName: _developerName,
      );
      final inspections = await _backup.importInspectionsFromSource(
        sourceDbPath: path,
      );
      final copied = users['users_copied'];
      return AppText.t(
        'تم استيراد $copied مستخدم و $inspections فحص.',
        'Imported $copied users and $inspections inspections.',
      );
    });
  }

  Future<void> _importUsers() async {
    final path = _usersPath;
    if (path == null) {
      AppFeedback.error(context, _needDbFirst);
      return;
    }
    final ok = await _confirm(
      title: AppText.t('استيراد المستخدمين', 'Import users'),
      message: AppText.t(
        'سيتم نسخ المستخدمين من الملف المحدد إلى القاعدة المحلية. '
        'المستخدمون الموجودون مسبقاً لن يتأثروا.',
        'Users are copied from the chosen file into the local database. '
        'Existing users will not be affected.',
      ),
      confirmText: AppText.t('استيراد', 'Import'),
      danger: false,
    );
    if (!ok) return;
    await _run('users', () async {
      await _backup.validateBackupDatabase(path);
      final result = await _backup.pullUsersFromSourceDb(
        sourceDbPath: path,
        developerName: _developerName,
      );
      final parts = [
        AppText.t(
          'تم نسخ ${result['users_copied']} مستخدم جديد',
          'Copied ${result['users_copied']} new users',
        ),
      ];
      if ((result['users_skipped'] as num? ?? 0) > 0) {
        parts.add(AppText.t(
          'تم تخطي ${result['users_skipped']} مستخدم موجود سابقاً',
          'Skipped ${result['users_skipped']} existing users',
        ));
      }
      if ((result['legacy_count'] as num? ?? 0) > 0) {
        parts.add(
          AppText.t(
            '${result['legacy_count']} كلمة مرور قديمة (سيتم ترقيتها عند أول تسجيل دخول)',
            '${result['legacy_count']} legacy passwords (upgraded on first login)',
          ),
        );
      }
      if ((result['v2_count'] as num? ?? 0) > 0) {
        parts.add(
          AppText.t(
            '${result['v2_count']} كلمة مرور مشفرة من جهاز آخر (قد تحتاج إعادة تعيين)',
            '${result['v2_count']} encrypted passwords from another device (may need reset)',
          ),
        );
      }
      return '${parts.join('. ')}.';
    });
  }

  Future<void> _importMaterials() async {
    final path = _materialsPath;
    if (path == null) {
      AppFeedback.error(context, _needDbFirst);
      return;
    }
    final ok = await _confirm(
      title: AppText.t('استيراد الخامات والوحدات', 'Import materials and units'),
      message: AppText.t(
        'سيتم دمج الخامات والوحدات من قاعدة البيانات المحددة بشكل تراكمي (تحديث حسب الاسم). '
        'لن تتغير الإعدادات أو المسارات المحلية.',
        'Materials and units are upserted by name from the chosen database. '
        'Local settings and paths stay unchanged.',
      ),
      confirmText: AppText.t('استيراد', 'Import'),
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
      if (message.isNotEmpty) return message;
      return AppText.t(
        'تم استيراد ${result['materials']} خامة و ${result['parameters']} وحدة.',
        'Imported ${result['materials']} materials and ${result['parameters']} units.',
      );
    });
  }

  Widget _row(
    String label,
    String? path,
    String pickKey,
    String importKey,
    VoidCallback onImport,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.borderMuted),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  path?.isNotEmpty == true ? path! : '—',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13.spMax,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(
              onPressed: _busyKey != null ? null : () => _pick(pickKey),
              child: Text(AppText.t('اختيار', 'Choose')),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              small: true,
              label: AppText.t('استيراد', 'Import'),
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
          AppText.t(
            'استيراد من قاعدة بيانات خارجية',
            'Import from an external database',
          ),
          style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t(
            'وتستورد المستخدمين والفحوصات أو الخامات من قاعدة بيانات أخرى، لترقية البيانات إلى النسخة الجديدة من البرنامج.',
            'Import users and inspections, or materials, from another database to upgrade the data to the new app version.',
          ),
          style: TextStyle(fontSize: 13.spMax, color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        _row(
          AppText.t('مستخدمين وفحوصات', 'Users and inspections'),
          _combinedPath,
          'combined',
          'combined',
          _importCombined,
        ),
        const SizedBox(height: AppSpacing.lg),
        _row(
          AppText.t('مستخدمين فقط', 'Users only'),
          _usersPath,
          'users',
          'users',
          _importUsers,
        ),
        const SizedBox(height: AppSpacing.lg),
        _row(
          AppText.t('خامات ووحدات', 'Materials and units'),
          _materialsPath,
          'materials',
          'materials',
          _importMaterials,
        ),
      ],
    );
  }
}
