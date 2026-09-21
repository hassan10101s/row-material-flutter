import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
  ];

  /// No description provided for @activity_log.
  ///
  /// In en, this message translates to:
  /// **'Activity Log'**
  String get activity_log;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @analyses.
  ///
  /// In en, this message translates to:
  /// **'Analyses'**
  String get analyses;

  /// No description provided for @app_title.
  ///
  /// In en, this message translates to:
  /// **'Raw Material Lab'**
  String get app_title;

  /// No description provided for @app_title_short.
  ///
  /// In en, this message translates to:
  /// **'Material Lab'**
  String get app_title_short;

  /// No description provided for @approval.
  ///
  /// In en, this message translates to:
  /// **'Approval'**
  String get approval;

  /// No description provided for @approval_rate.
  ///
  /// In en, this message translates to:
  /// **'Approval Rate'**
  String get approval_rate;

  /// No description provided for @approval_rate_suffix.
  ///
  /// In en, this message translates to:
  /// **'approval'**
  String get approval_rate_suffix;

  /// No description provided for @backup.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backup;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @conditional.
  ///
  /// In en, this message translates to:
  /// **'Conditional'**
  String get conditional;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @constants.
  ///
  /// In en, this message translates to:
  /// **'Constants'**
  String get constants;

  /// No description provided for @count_inspections.
  ///
  /// In en, this message translates to:
  /// **'inspections'**
  String get count_inspections;

  /// No description provided for @dashboard.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get dashboard;

  /// No description provided for @dashboard_hero_subtitle.
  ///
  /// In en, this message translates to:
  /// **'Raw material quality overview & analytics'**
  String get dashboard_hero_subtitle;

  /// No description provided for @dashboard_history.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get dashboard_history;

  /// No description provided for @dashboard_lab.
  ///
  /// In en, this message translates to:
  /// **'Lab'**
  String get dashboard_lab;

  /// No description provided for @dashboard_load_error.
  ///
  /// In en, this message translates to:
  /// **'Failed to load dashboard'**
  String get dashboard_load_error;

  /// No description provided for @dashboard_material.
  ///
  /// In en, this message translates to:
  /// **'Material'**
  String get dashboard_material;

  /// No description provided for @dashboard_new_inspection.
  ///
  /// In en, this message translates to:
  /// **'New Inspection'**
  String get dashboard_new_inspection;

  /// No description provided for @dashboard_reports.
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get dashboard_reports;

  /// No description provided for @dashboard_retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get dashboard_retry;

  /// No description provided for @dashboard_status.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get dashboard_status;

  /// No description provided for @dashboard_supplier.
  ///
  /// In en, this message translates to:
  /// **'Supplier'**
  String get dashboard_supplier;

  /// No description provided for @database.
  ///
  /// In en, this message translates to:
  /// **'Database'**
  String get database;

  /// No description provided for @decision_approved.
  ///
  /// In en, this message translates to:
  /// **'Final Approval'**
  String get decision_approved;

  /// No description provided for @decision_conditional.
  ///
  /// In en, this message translates to:
  /// **'Conditional Approval'**
  String get decision_conditional;

  /// No description provided for @decision_partial.
  ///
  /// In en, this message translates to:
  /// **'Partial Rejection'**
  String get decision_partial;

  /// No description provided for @decision_reason.
  ///
  /// In en, this message translates to:
  /// **'Decision Reason'**
  String get decision_reason;

  /// No description provided for @decision_rejected.
  ///
  /// In en, this message translates to:
  /// **'Full Rejection'**
  String get decision_rejected;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @discard_changes.
  ///
  /// In en, this message translates to:
  /// **'Discard and continue'**
  String get discard_changes;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @export_pdf.
  ///
  /// In en, this message translates to:
  /// **'Export PDF'**
  String get export_pdf;

  /// No description provided for @follow_up_note.
  ///
  /// In en, this message translates to:
  /// **'Follow-up Note'**
  String get follow_up_note;

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @general_empty.
  ///
  /// In en, this message translates to:
  /// **'No data yet'**
  String get general_empty;

  /// No description provided for @history.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get history;

  /// No description provided for @insights_title.
  ///
  /// In en, this message translates to:
  /// **'Insights'**
  String get insights_title;

  /// No description provided for @inspection_count_suffix.
  ///
  /// In en, this message translates to:
  /// **'inspection'**
  String get inspection_count_suffix;

  /// No description provided for @inspections.
  ///
  /// In en, this message translates to:
  /// **'Inspections'**
  String get inspections;

  /// No description provided for @inventory.
  ///
  /// In en, this message translates to:
  /// **'Inventory'**
  String get inventory;

  /// No description provided for @kpi_today_approved.
  ///
  /// In en, this message translates to:
  /// **'Today Approved'**
  String get kpi_today_approved;

  /// No description provided for @kpi_today_inspections.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get kpi_today_inspections;

  /// No description provided for @kpi_today_rejected.
  ///
  /// In en, this message translates to:
  /// **'Today Rejected'**
  String get kpi_today_rejected;

  /// No description provided for @kpi_total.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get kpi_total;

  /// No description provided for @lab.
  ///
  /// In en, this message translates to:
  /// **'Lab'**
  String get lab;

  /// No description provided for @lab_reports.
  ///
  /// In en, this message translates to:
  /// **'Lab Reports'**
  String get lab_reports;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @language_ar.
  ///
  /// In en, this message translates to:
  /// **'العربية'**
  String get language_ar;

  /// No description provided for @language_en.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get language_en;

  /// No description provided for @language_switch.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language_switch;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// No description provided for @low_stock.
  ///
  /// In en, this message translates to:
  /// **'Low stock'**
  String get low_stock;

  /// No description provided for @materials.
  ///
  /// In en, this message translates to:
  /// **'Materials'**
  String get materials;

  /// No description provided for @materials_editor.
  ///
  /// In en, this message translates to:
  /// **'Materials Editor'**
  String get materials_editor;

  /// No description provided for @menu.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get menu;

  /// No description provided for @month_apr.
  ///
  /// In en, this message translates to:
  /// **'April'**
  String get month_apr;

  /// No description provided for @month_aug.
  ///
  /// In en, this message translates to:
  /// **'August'**
  String get month_aug;

  /// No description provided for @month_dec.
  ///
  /// In en, this message translates to:
  /// **'December'**
  String get month_dec;

  /// No description provided for @month_feb.
  ///
  /// In en, this message translates to:
  /// **'February'**
  String get month_feb;

  /// No description provided for @month_jan.
  ///
  /// In en, this message translates to:
  /// **'January'**
  String get month_jan;

  /// No description provided for @month_jul.
  ///
  /// In en, this message translates to:
  /// **'July'**
  String get month_jul;

  /// No description provided for @month_jun.
  ///
  /// In en, this message translates to:
  /// **'June'**
  String get month_jun;

  /// No description provided for @month_mar.
  ///
  /// In en, this message translates to:
  /// **'March'**
  String get month_mar;

  /// No description provided for @month_may.
  ///
  /// In en, this message translates to:
  /// **'May'**
  String get month_may;

  /// No description provided for @month_nov.
  ///
  /// In en, this message translates to:
  /// **'November'**
  String get month_nov;

  /// No description provided for @month_oct.
  ///
  /// In en, this message translates to:
  /// **'October'**
  String get month_oct;

  /// No description provided for @month_sep.
  ///
  /// In en, this message translates to:
  /// **'September'**
  String get month_sep;

  /// No description provided for @monthly_trend_empty.
  ///
  /// In en, this message translates to:
  /// **'Not enough monthly trend data yet'**
  String get monthly_trend_empty;

  /// No description provided for @monthly_trend_title.
  ///
  /// In en, this message translates to:
  /// **'Monthly Acceptance Trend'**
  String get monthly_trend_title;

  /// No description provided for @new_inspection.
  ///
  /// In en, this message translates to:
  /// **'New Inspection'**
  String get new_inspection;

  /// No description provided for @open_pdf_folder.
  ///
  /// In en, this message translates to:
  /// **'Open PDF Folder'**
  String get open_pdf_folder;

  /// No description provided for @partial.
  ///
  /// In en, this message translates to:
  /// **'Partial'**
  String get partial;

  /// No description provided for @period_3months.
  ///
  /// In en, this message translates to:
  /// **'3 Months'**
  String get period_3months;

  /// No description provided for @period_all.
  ///
  /// In en, this message translates to:
  /// **'All Time'**
  String get period_all;

  /// No description provided for @period_decisions_title.
  ///
  /// In en, this message translates to:
  /// **'Period Decisions Breakdown'**
  String get period_decisions_title;

  /// No description provided for @period_labels_title.
  ///
  /// In en, this message translates to:
  /// **'Period Decisions Breakdown'**
  String get period_labels_title;

  /// No description provided for @period_month.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get period_month;

  /// No description provided for @period_rejection_rate.
  ///
  /// In en, this message translates to:
  /// **'Overall rejection rate: '**
  String get period_rejection_rate;

  /// No description provided for @period_total_inspections.
  ///
  /// In en, this message translates to:
  /// **'Total inspections in period: '**
  String get period_total_inspections;

  /// No description provided for @period_week.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get period_week;

  /// No description provided for @period_year.
  ///
  /// In en, this message translates to:
  /// **'Year'**
  String get period_year;

  /// No description provided for @preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get preview;

  /// No description provided for @print.
  ///
  /// In en, this message translates to:
  /// **'Print'**
  String get print;

  /// No description provided for @products.
  ///
  /// In en, this message translates to:
  /// **'Products'**
  String get products;

  /// No description provided for @rate_approval.
  ///
  /// In en, this message translates to:
  /// **'approval'**
  String get rate_approval;

  /// No description provided for @rate_approval_rate.
  ///
  /// In en, this message translates to:
  /// **'Approval rate: '**
  String get rate_approval_rate;

  /// No description provided for @recommendations_title.
  ///
  /// In en, this message translates to:
  /// **'Recommendations'**
  String get recommendations_title;

  /// No description provided for @reference.
  ///
  /// In en, this message translates to:
  /// **'Reference'**
  String get reference;

  /// No description provided for @rejected.
  ///
  /// In en, this message translates to:
  /// **'Rejected'**
  String get rejected;

  /// No description provided for @rejected_qty_short.
  ///
  /// In en, this message translates to:
  /// **'Rejected Qty'**
  String get rejected_qty_short;

  /// No description provided for @rejected_quantity.
  ///
  /// In en, this message translates to:
  /// **'Rejected Quantity'**
  String get rejected_quantity;

  /// No description provided for @rejection_rate.
  ///
  /// In en, this message translates to:
  /// **'Rejection Rate'**
  String get rejection_rate;

  /// No description provided for @rejection_rate_general.
  ///
  /// In en, this message translates to:
  /// **'Overall rejection rate: '**
  String get rejection_rate_general;

  /// No description provided for @reports.
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get reports;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @run_test.
  ///
  /// In en, this message translates to:
  /// **'Run Test'**
  String get run_test;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @security.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get security;

  /// No description provided for @session_expired.
  ///
  /// In en, this message translates to:
  /// **'Session expired.'**
  String get session_expired;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @share_whatsapp.
  ///
  /// In en, this message translates to:
  /// **'Share via WhatsApp'**
  String get share_whatsapp;

  /// No description provided for @specifications.
  ///
  /// In en, this message translates to:
  /// **'Specifications'**
  String get specifications;

  /// No description provided for @status_all.
  ///
  /// In en, this message translates to:
  /// **'All Statuses'**
  String get status_all;

  /// No description provided for @status_approved.
  ///
  /// In en, this message translates to:
  /// **'Final Approval'**
  String get status_approved;

  /// No description provided for @status_conditional_approval.
  ///
  /// In en, this message translates to:
  /// **'Conditional Approval'**
  String get status_conditional_approval;

  /// No description provided for @status_full_rejection.
  ///
  /// In en, this message translates to:
  /// **'Full Rejection'**
  String get status_full_rejection;

  /// No description provided for @status_partial_rejection.
  ///
  /// In en, this message translates to:
  /// **'Partial Rejection'**
  String get status_partial_rejection;

  /// No description provided for @status_pending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get status_pending;

  /// No description provided for @tagline.
  ///
  /// In en, this message translates to:
  /// **'Raw Material Inspection & QC System'**
  String get tagline;

  /// No description provided for @test_history.
  ///
  /// In en, this message translates to:
  /// **'Test History'**
  String get test_history;

  /// No description provided for @toggle_theme.
  ///
  /// In en, this message translates to:
  /// **'Toggle theme'**
  String get toggle_theme;

  /// No description provided for @top_materials_empty.
  ///
  /// In en, this message translates to:
  /// **'No raw material inspections'**
  String get top_materials_empty;

  /// No description provided for @top_materials_title.
  ///
  /// In en, this message translates to:
  /// **'Top Materials'**
  String get top_materials_title;

  /// No description provided for @top_suppliers_empty.
  ///
  /// In en, this message translates to:
  /// **'No supplier inspections'**
  String get top_suppliers_empty;

  /// No description provided for @top_suppliers_title.
  ///
  /// In en, this message translates to:
  /// **'Top Suppliers'**
  String get top_suppliers_title;

  /// No description provided for @total_in_period.
  ///
  /// In en, this message translates to:
  /// **'Total in period: '**
  String get total_in_period;

  /// No description provided for @total_inspections.
  ///
  /// In en, this message translates to:
  /// **'Total Inspections'**
  String get total_inspections;

  /// No description provided for @unsaved_changes_message.
  ///
  /// In en, this message translates to:
  /// **'You have unsaved changes. Discard them and continue?'**
  String get unsaved_changes_message;

  /// No description provided for @unsaved_changes_title.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get unsaved_changes_title;

  /// No description provided for @users.
  ///
  /// In en, this message translates to:
  /// **'Users'**
  String get users;

  /// No description provided for @welcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome'**
  String get welcome;

  /// No description provided for @worksheet.
  ///
  /// In en, this message translates to:
  /// **'Worksheet'**
  String get worksheet;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
