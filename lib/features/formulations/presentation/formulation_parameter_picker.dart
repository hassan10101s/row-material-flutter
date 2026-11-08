import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_search_field.dart';
import '../../../design_system/widgets/app_window.dart';

/// Selection changes only the graph view; cancelling keeps the existing set.
Future<Set<String>?> showFormulationParameterPicker(
  BuildContext context, {
  required bool fullScreen,
  required Map<String, String> options,
  required Set<String> selected,
  required Set<String> plotted,
}) {
  final draft = {...selected};
  var query = '';
  final entries = options.entries.toList()
    ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
  return showAppContent<Set<String>>(
    context,
    fullScreen: fullScreen,
    title: AppText.t('إعداد التحاليل', 'Analysis settings'),
    icon: Icons.tune,
    height: 560,
    scrollBody: false,
    actionsBuilder: (_, close) => [
      AppButton(
        label: AppText.t('إلغاء', 'Cancel'),
        style: AppButtonStyle.secondary,
        onPressed: () => close(),
      ),
      AppButton(
        label: AppText.t('تطبيق', 'Apply'),
        onPressed: () => close({...draft}),
      ),
    ],
    builder: (_, _) => StatefulBuilder(
      builder: (context, update) {
        final visible = entries
            .where(
              (entry) =>
                  entry.value.toLowerCase().contains(query) ||
                  entry.key.toLowerCase().contains(query),
            )
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppText.t(
                'أضف تحليلًا موجودًا إلى الرسم أو أزل تحديده. الاختيار لا يضيف قياسات جديدة.',
                'Add an existing analysis to the chart or deselect it. Selection does not create measurements.',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            DebouncedSearchField(
              label: AppText.t('بحث عن تحليل', 'Search analyses'),
              onChanged: (value) =>
                  update(() => query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        AppText.t(
                          'لا توجد تحاليل مطابقة',
                          'No matching analyses',
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final entry = visible[index];
                        return CheckboxListTile(
                          key: ValueKey('formulation-parameter-${entry.key}'),
                          title: Text(entry.value),
                          subtitle: plotted.contains(entry.key)
                              ? null
                              : Text(
                                  AppText.t(
                                    'لا توجد نقاط مكتملة للفترة الحالية',
                                    'No complete points for the current period',
                                  ),
                                ),
                          value: draft.contains(entry.key),
                          onChanged: (checked) => update(() {
                            if (checked == true) {
                              draft.add(entry.key);
                            } else {
                              draft.remove(entry.key);
                            }
                          }),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}
