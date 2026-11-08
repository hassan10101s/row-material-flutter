import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/security/secure_field_access.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../di/service_locator.dart';

class SecureVisibilitySetting extends StatefulWidget {
  const SecureVisibilitySetting({super.key});
  @override
  State<SecureVisibilitySetting> createState() => _SecureVisibilitySettingState();
}

class _SecureVisibilitySettingState extends State<SecureVisibilitySetting> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    if (!getIt.isRegistered<SecureFieldAccess>()) return const SizedBox.shrink();
    final access = getIt<SecureFieldAccess>();
    return ListenableBuilder(listenable: access, builder: (context, _) {
      if (!access.mayManage) return const SizedBox.shrink();
      return SwitchListTile.adaptive(
        title: Text(AppText.t('رؤية بيانات Secure', 'Reveal Secure data')),
        subtitle: Text(AppText.t('للجلسة الحالية فقط. لا تظهر البيانات المحمية في التقارير والطباعة.',
          'For this session. Protected data is always excluded from reports and printing.')),
        secondary: const Icon(Icons.shield_outlined),
        value: access.enabled,
        onChanged: _busy ? null : (value) async {
          setState(() => _busy = true);
          try {
            await access.setEnabled(value);
          } catch (error) {
            if (context.mounted) AppFeedback.errorFrom(context, error);
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        },
      );
    });
  }
}
