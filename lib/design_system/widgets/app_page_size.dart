import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_text_theme.dart';
import 'app_paginated_table.dart' show appTextOf;

/// Default records per page for every table in the app.
const int kDefaultPageSize = 200;

/// Page-size choices offered next to the pager arrows.
const List<int> kPageSizeOptions = [10, 25, 50, 100, 200, 500];

/// Mobile-only cap: a phone card list with 200 rows per page feels sluggish
/// (heavy SQLite LIMIT/OFFSET + hundreds of card widgets per page). Phones
/// default to 25 and may only pick from [kMobilePageSizeOptions]; desktop
/// keeps [kDefaultPageSize].
const int kMobileMaxPageSize = 25;

/// Page-size choices offered on phones.
const List<int> kMobilePageSizeOptions = [10, 25];

/// Small dropdown placed in table footers next to the prev/next arrows so the
/// user controls how many records each page shows.
class AppPageSizeSelector extends StatelessWidget {
  const AppPageSizeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.options = kPageSizeOptions,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final List<int> options;

  @override
  Widget build(BuildContext context) {
    final List<int> items;
    if (options.contains(value)) {
      items = options;
    } else {
      items = <int>[...options, value]..sort();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          appTextOf(context, 'لكل صفحة:', 'Per page:'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
        const SizedBox(width: 4),
        DropdownButton<int>(
          key: const Key('pageSizeSelector'),
          value: value,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(
            fontFamily: AppTextTheme.cairoFontFamily,
            color: AppColors.textStrong,
            fontSize: 12.spMax,
          ),
          items: [
            for (final o in items)
              DropdownMenuItem(value: o, child: Text('$o')),
          ],
          onChanged: (v) {
            if (v != null && v != value) onChanged(v);
          },
        ),
      ],
    );
  }
}
