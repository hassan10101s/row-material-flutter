import 'package:flutter/material.dart';

/// Icon helper wrapping FontAwesome/Material icons with tone mapping.
class AppIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final double size;

  const AppIcon(this.icon, {super.key, this.color, this.size = 18});

  @override
  Widget build(BuildContext context) => Icon(icon, color: color, size: size);
}

/// Central registry so screens refer to semantic names (mirrors uiIcon()).
class AppIcons {
  static const IconData dashboard = Icons.space_dashboard_outlined;
  static const IconData inspections = Icons.fact_check_outlined;
  static const IconData newInspection = Icons.add_circle_outline;
  static const IconData materials = Icons.biotech_outlined;
  static const IconData lab = Icons.science_outlined;
  static const IconData reports = Icons.description_outlined;
  static const IconData settings = Icons.settings_outlined;
  static const IconData logout = Icons.logout;
  static const IconData login = Icons.login;
  static const IconData pdf = Icons.picture_as_pdf;
  static const IconData whatsapp = Icons.chat;
  static const IconData save = Icons.save_outlined;
  static const IconData refresh = Icons.refresh;
  static const IconData details = Icons.info_outline;
  static const IconData users = Icons.group_outlined;
  static const IconData userAdd = Icons.person_add_alt;
  static const IconData folder = Icons.folder_open;
  static const IconData import = Icons.file_download_outlined;
  static const IconData export = Icons.file_upload_outlined;
  static const IconData chart = Icons.insert_chart_outlined;
  static const IconData check = Icons.check_circle_outline;
  static const IconData alert = Icons.warning_amber_rounded;
  static const IconData add = Icons.add;
  static const IconData edit = Icons.edit_outlined;
  static const IconData delete = Icons.delete_outline;
  static const IconData close = Icons.close;
  static const IconData search = Icons.search;
  static const IconData inventory = Icons.inventory_2_outlined;
  static const IconData analysis = Icons.bubble_chart_outlined;
  static const IconData products = Icons.inventory_outlined;
  static const IconData constants = Icons.functions;
  static const IconData history = Icons.history;
  static const IconData worksheet = Icons.grid_view_outlined;
  static const IconData database = Icons.storage_outlined;
  static const IconData sun = Icons.light_mode_outlined;
  static const IconData moon = Icons.dark_mode_outlined;
  static const IconData print = Icons.print;
  static const IconData share = Icons.share_outlined;
  static const IconData calendar = Icons.calendar_month_outlined;
  static const IconData quick = Icons.bolt;
  static const IconData trending = Icons.trending_up;
  static const IconData supplier = Icons.local_shipping_outlined;
  static const IconData lock = Icons.lock_outline;
  static const IconData qrCode = Icons.qr_code_2;
  static const IconData menu = Icons.menu;
  static const IconData back = Icons.arrow_back;
  static const IconData arrowForward = Icons.arrow_forward;
  static const IconData note = Icons.sticky_note_2_outlined;
  static const IconData swap = Icons.swap_horiz;
}