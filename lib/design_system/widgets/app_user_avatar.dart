import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

/// The member's avatar: the Google profile photo when one is known, otherwise
/// the first letter of the name on the brand colour.
///
/// Shared by the shell identity card (desktop sidebar and phone drawer) and the
/// account/settings panel so the picture a member set in Google is the one the
/// app shows, in every place it identifies them. A broken/blank photo URL never
/// leaves an empty circle: the letter fallback is rendered by the same
/// [errorBuilder] the network image uses.
class AppUserAvatar extends StatelessWidget {
  const AppUserAvatar({
    super.key,
    required this.name,
    this.photoUrl,
    this.radius = 18,
    this.backgroundColor,
  });

  final String name;
  final String? photoUrl;
  final double radius;
  final Color? backgroundColor;

  String get _initial {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final url = (photoUrl ?? '').trim();
    final background = backgroundColor ?? AppColors.primary;
    final letter = Text(
      _initial,
      style: TextStyle(
        color: Colors.white,
        fontSize: radius * 0.82,
        fontWeight: FontWeight.w700,
      ),
    );
    if (url.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: background,
        child: letter,
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: background,
      child: ClipOval(
        child: Image.network(
          url,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Center(child: letter),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : Center(child: letter),
        ),
      ),
    );
  }
}
