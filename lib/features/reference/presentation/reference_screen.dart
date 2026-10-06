import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../../lab/domain/lab_result_repository.dart';
import '../domain/parameter_type.dart';
import '../domain/reference_repository.dart';
import 'cubit/params_cubit.dart';
import 'cubit/products_cubit.dart';
import 'cubit/reference_cubit.dart';
import 'cubit/units_cubit.dart';
import 'materials_tab.dart';
import 'params_tab.dart';
import 'products_tab.dart';
import 'units_tab.dart';

class _RefTab {
  final String label;
  final IconData icon;
  final Widget child;
  const _RefTab(this.label, this.icon, this.child);
}

/// Reference app shell — port of `ReferenceAppView` (web/src/57_reference_app.js):
/// Reference Materials | Products | Chemical Parameters | Physical Aspects | Units.
class ReferenceScreen extends StatefulWidget {
  const ReferenceScreen({super.key});

  @override
  State<ReferenceScreen> createState() => _ReferenceScreenState();
}

class _ReferenceScreenState extends State<ReferenceScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final refRepo = getIt<ReferenceRepository>();
    final labConfig = getIt<LabConfigurationRepository>();
    final tabs = <_RefTab>[
      _RefTab(
        AppText.t('المواد المرجعية', 'Materials'),
        Icons.science_outlined,
        BlocProvider(
          create: (_) => ReferenceCubit(repo: refRepo)..load(),
          child: MaterialsTab(refRepo: refRepo, labConfig: labConfig),
        ),
      ),
      _RefTab(
        AppText.t('المنتجات', 'Products'),
        Icons.inventory_2_outlined,
        BlocProvider(
          create: (_) => ProductsCubit(repo: labConfig)..load(),
          child: const ProductsTab(),
        ),
      ),
      _RefTab(
        AppText.t('التحليل الكيميائي', 'Chemical'),
        Icons.biotech_outlined,
        BlocProvider(
          create: (_) => ParamsCubit.chemical(repo: refRepo)..load(),
          child: ParamsTab(parameterType: ParameterType.chemical.value),
        ),
      ),
      _RefTab(
        AppText.t('الفحص الظاهري', 'Physical'),
        Icons.remove_red_eye_outlined,
        BlocProvider(
          create: (_) => ParamsCubit.physical(repo: refRepo)..load(),
          child: ParamsTab(parameterType: ParameterType.physical.value),
        ),
      ),
      _RefTab(
        AppText.t('إعدادات الوحدات', 'Units'),
        Icons.straighten_outlined,
        BlocProvider(
          create: (_) => UnitsCubit(repo: refRepo)..load(),
          child: const UnitsTab(),
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.page,
            AppSpacing.page,
            0,
          ),
          child: Text(
            AppStrings.reference,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 46.h,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: ChoiceChip(
                      label: Text(tabs[i].label),
                      avatar: Icon(tabs[i].icon, size: 18.r),
                      selected: _tab == i,
                      onSelected: (_) => setState(() => _tab = i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: IndexedStack(
              index: _tab,
              children: [for (final t in tabs) t.child],
            ),
          ),
        ),
      ],
    );
  }
}
