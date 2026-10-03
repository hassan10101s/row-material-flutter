import 'package:flutter/widgets.dart';

import '../../design_system/tokens/app_spacing.dart';
import 'form_factor.dart';

/// The resolved, form-factor-specific metrics a screen needs.
///
/// A screen reads these instead of branching on width, which keeps every
/// "which experience am I" decision in one place and leaves the screen free to
/// describe *only* its own layout.
///
/// The values are fixed per form factor. Nothing here is derived from the live
/// window size, so a resized desktop window keeps the desktop numbers.
@immutable
class LayoutSpec {
  const LayoutSpec._({required this.formFactor});

  /// Desktop: the 1280x720 authoring grid every existing `.w`/`.h`/`.spMax`
  /// call site was tuned against. Unchanged, so the desktop build must not
  /// move by a single pixel.
  static const LayoutSpec desktop = LayoutSpec._(formFactor: AppFormFactor.desktop);

  /// Mobile: a 400x860 authoring grid. At that ratio `.w` behaves as a
  /// fraction of a 400dp reference, `.r` lands near 1.0 so authored corner
  /// radii survive, and `.spMax` floors text at its authored size.
  static const LayoutSpec mobile = LayoutSpec._(formFactor: AppFormFactor.mobile);

  static LayoutSpec of(AppFormFactor formFactor) =>
      formFactor == AppFormFactor.mobile ? mobile : desktop;

  final AppFormFactor formFactor;

  bool get isMobile => formFactor.isMobile;

  bool get isDesktop => formFactor.isDesktop;

  /// Horizontal page padding.
  double get pageGutter => isMobile ? 12 : AppSpacing.page;

  /// Vertical gap between stacked cards.
  double get blockGap => isMobile ? 10 : AppSpacing.lg;

  /// Minimum interactive height. 48dp is the accessibility floor for a touch
  /// target; a mouse is far more forgiving than a finger, so desktop keeps the
  /// tighter authored heights.
  double get minTouchTarget => isMobile ? 48 : 34;

  /// Row height for list-style data surfaces.
  double get dataRowHeight => isMobile ? 56 : 52;

  /// Whether a data surface renders as a table at all. False means the
  /// horizontal-scroll fallback is not a degraded experience, it is the wrong
  /// one, so callers must use a card list.
  bool get supportsTable => isDesktop;

  /// Whether a modal may use fixed pixel dimensions. On a phone a
  /// 1040x780 dialog does not fit, so these become full-screen routes.
  bool get allowsFixedDialog => isDesktop;

  /// Density of a list section: how many cards sit side by side.
  int get listColumns => isMobile ? 1 : 2;

  @override
  bool operator ==(Object other) =>
      other is LayoutSpec && other.formFactor == formFactor;

  @override
  int get hashCode => formFactor.hashCode;

  @override
  String toString() => 'LayoutSpec(${formFactor.name})';
}
