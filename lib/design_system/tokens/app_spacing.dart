import 'package:flutter/material.dart';

/// Spacing scale.
class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double page = 24;
}

class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
}

class AppShadows {
  static List<BoxShadow> get card => const [
        BoxShadow(
          color: Color(0x0A071528),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ];
}