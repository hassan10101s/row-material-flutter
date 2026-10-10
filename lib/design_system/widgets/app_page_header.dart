import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_breakpoints.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_search_field.dart';

/// Modern page header: icon tile + title + subtitle + trailing actions.
///
/// One header for every list/register screen so the app reads as one product.
/// On narrow widths the actions wrap below the title instead of overflowing.
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.accent,
    this.actions = const [],
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? accent;
  final List<Widget> actions;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final accentColor = accent ?? AppColors.primary;
    final narrow = MediaQuery.sizeOf(context).width < AppBreakpoints.compact;
    final titleBlock = Row(
      children: [
        if (icon != null) ...[
          Container(
            width: 44.r,
            height: 44.r,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  accentColor.withValues(alpha: 0.2),
                  accentColor.withValues(alpha: 0.08),
                ],
              ),
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.2),
              ),
            ),
            child: Icon(icon, size: 22.r, color: accentColor),
          ),
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 20.spMax,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  color: AppColors.textStrong,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.spMax,
                    height: 1.45,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (actions.isEmpty && bottom == null) return titleBlock;

    if (narrow && actions.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          titleBlock,
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: actions,
          ),
          if (bottom != null) ...[
            const SizedBox(height: AppSpacing.md),
            bottom!,
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: titleBlock),
            if (actions.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ],
        ),
        if (bottom != null) ...[
          const SizedBox(height: AppSpacing.md),
          bottom!,
        ],
      ],
    );
  }
}

/// Modern filter bar: debounced search + wrapping filter chips/actions.
///
/// Replaces hand-rolled `TextField + Row(filter chips)` blocks that overflowed
/// on 400dp phones. Search takes the full row on phones, shares it on desktop.
class AppFilterBar extends StatelessWidget {
  const AppFilterBar({
    super.key,
    this.searchHint,
    this.searchLabel,
    this.initialSearch,
    this.onSearch,
    this.filters = const [],
    this.trailing,
  });

  final String? searchHint;
  final String? searchLabel;
  final String? initialSearch;
  final ValueChanged<String>? onSearch;
  final List<Widget> filters;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.medium;

    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onSearch != null)
            SizedBox(
              width: double.infinity,
              child: DebouncedSearchField(
                hint: searchHint,
                label: searchLabel,
                initialValue: initialSearch,
                onChanged: onSearch!,
              ),
            ),
          if (filters.isNotEmpty || trailing != null) ...[
            if (onSearch != null) const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...filters,
                ?trailing,
              ],
            ),
          ],
        ],
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onSearch != null)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
            child: DebouncedSearchField(
              hint: searchHint,
              label: searchLabel,
              initialValue: initialSearch,
              onChanged: onSearch!,
            ),
          ),
        ...filters,
        ?trailing,
      ],
    );
  }
}
