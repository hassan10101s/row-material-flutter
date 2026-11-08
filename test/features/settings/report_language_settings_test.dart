import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/features/settings/domain/settings_repository.dart';
import 'package:material_lab/features/settings/presentation/cubit/general_settings_cubit.dart';

class _Settings extends Mock implements SettingsRepository {}

void main() {
  test(
    'report language loads and persists separately from UI language',
    () async {
      final repo = _Settings();
      when(() => repo.getSettingValue(any())).thenAnswer((_) async => null);
      when(
        () => repo.getSettingValue('report_language'),
      ).thenAnswer((_) async => 'en');
      when(() => repo.getReportLogoPath()).thenAnswer((_) async => null);
      when(() => repo.getReportLogoDataUri()).thenAnswer((_) async => null);
      when(() => repo.updateSettings(any())).thenAnswer((_) async {});
      final cubit = GeneralSettingsCubit(repo: repo);
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.reportLanguage, 'en');
      await cubit.saveReportLanguage(false);
      verify(() => repo.updateSettings({'report_language': 'ar'})).called(1);
      expect(cubit.state.reportLanguage, 'ar');
      expect(cubit.state.saving, false);
    },
  );

  test('failed language save retains the last saved language', () async {
    final repo = _Settings();
    when(
      () => repo.updateSettings(any()),
    ).thenThrow(StateError('storage error'));
    final cubit = GeneralSettingsCubit(repo: repo);
    addTearDown(cubit.close);
    await expectLater(cubit.saveReportLanguage(true), throwsStateError);
    expect(cubit.state.reportLanguage, 'ar');
    expect(cubit.state.saving, false);
  });
}
