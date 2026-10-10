import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/design_system/animations/app_animations.dart';

void main() {
  late ValueNotifier<int> appearanceChanges;

  setUp(() {
    appearanceChanges = ValueNotifier(0);
    AppPageRoute.appearanceChanges = appearanceChanges;
    AppText.arabic = true;
  });

  tearDown(() {
    AppPageRoute.appearanceChanges = null;
    appearanceChanges.dispose();
    AppText.arabic = true;
  });

  for (final useMaterialRoute in [false, true]) {
    testWidgets(
      '${useMaterialRoute ? 'material' : 'app'} route updates appearance and keeps state',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Navigator(
              // NOTE: intentionally non-const. A const child is
              // canonicalized to the identical widget, which lets
              // Element.update elide the rebuild entirely — the very
              // rebuild this test exists to verify.
              onGenerateRoute: (_) => useMaterialRoute
                  ? appMaterialPageRoute<void>(
                      builder: (_) => _AppearanceProbe(),
                    )
                  : AppPageRoute<void>(
                      builder: (_) => _AppearanceProbe(),
                    ),
            ),
          ),
        );

        expect(find.text('العربية'), findsOneWidget);
        await tester.tap(find.text('Count: 0'));
        await tester.pump();
        expect(find.text('Count: 1'), findsOneWidget);

        AppText.arabic = false;
        appearanceChanges.value++;
        await tester.pump();

        expect(find.text('English'), findsOneWidget);
        expect(find.text('Count: 1'), findsOneWidget);
      },
    );
  }
}

class _AppearanceProbe extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables — see note above.
  _AppearanceProbe();

  @override
  State<_AppearanceProbe> createState() => _AppearanceProbeState();
}

class _AppearanceProbeState extends State<_AppearanceProbe> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(AppText.t('العربية', 'English')),
      TextButton(
        onPressed: () => setState(() => _count++),
        child: Text('Count: $_count'),
      ),
    ],
  );
}
