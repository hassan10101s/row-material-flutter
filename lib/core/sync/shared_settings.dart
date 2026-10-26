import '../constants/report_form_keys.dart';

/// Organization content only. Paths, credentials, expiry seals, notification
/// watermarks, theme and language belong to the device that created them.
const sharedSettingKeys = <String>{
  'department_label',
  'report_logo_data_uri',
  ...ReportFormKeys.all,
};
