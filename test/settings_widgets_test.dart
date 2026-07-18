import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/features/settings/presentation/settings_tab.dart';
import 'package:nameless_audio/features/settings/presentation/about_page.dart';
import 'package:nameless_audio/core/widgets/top_page_header.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  late Database testDatabase;

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

  testWidgets('settings opens categorized secondary pages', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    for (final key in [
      'section_language',
      'section_common',
      'section_appearance',
      'section_playback',
      'section_asmr_download',
      'section_data_storage',
      'section_updates_permissions',
      'about',
    ]) {
      expect(find.text(i18n.tr(key)), findsOneWidget);
    }

    await tester.tap(find.text(i18n.tr('section_language')));
    await tester.pumpAndSettle();
    expect(find.text(i18n.tr('language')), findsAtLeastNWidgets(1));
    expect(find.text(i18n.tr('interface_language')), findsOneWidget);
    expect(find.text(i18n.tr('follow_system')), findsOneWidget);
    expect(find.text(i18n.tr('dlsite_metadata_language')), findsOneWidget);
    expect(find.text(i18n.tr('asmr_page_language')), findsOneWidget);
    expect(
      find.text(i18n.tr('follow_interface_language')),
      findsAtLeastNWidgets(1),
    );
    final categoryHeader = find.byType(TopPageHeader);
    final firstLanguageTile = find.widgetWithText(
      ListTile,
      i18n.tr('interface_language'),
    );
    final languageTileWidget = tester.widget<ListTile>(firstLanguageTile);
    expect(languageTileWidget.leading, isA<Icon>());
    expect((languageTileWidget.leading! as Icon).size, 30);
    final languageTileHeight = tester.getSize(firstLanguageTile).height;
    expect(languageTileHeight, greaterThanOrEqualTo(58));
    expect(languageTileHeight, lessThan(68));
    final languageTileContext = tester.element(firstLanguageTile);
    final languageTileTheme = ListTileTheme.of(languageTileContext);
    expect(languageTileTheme.minTileHeight, 58);
    expect(
      languageTileTheme.titleTextStyle?.fontSize,
      closeTo(58 * 18 / 68, 0.001),
    );
    expect(
      languageTileTheme.subtitleTextStyle?.fontSize,
      closeTo(58 * 15 / 68, 0.001),
    );
    expect(
      Theme.of(languageTileContext).textTheme.titleMedium?.fontSize,
      closeTo(58 * 18 / 68, 0.001),
    );
    expect(
      tester.getTopLeft(firstLanguageTile).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(categoryHeader).dy),
    );
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text(i18n.tr('section_common')));
    await tester.pumpAndSettle();
    expect(find.text(i18n.tr('startup_page')), findsOneWidget);
    expect(
      find.text(i18n.tr('haptic_feedback_enabled')),
      Platform.isWindows ? findsNothing : findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    final updatesCategory = find.text(i18n.tr('section_updates_permissions'));
    await tester.ensureVisible(updatesCategory);
    await tester.pumpAndSettle();
    await tester.tap(updatesCategory);
    await tester.pumpAndSettle();
    expect(find.text(i18n.tr('check_updates')), findsOneWidget);
    expect(
      find.textContaining(i18n.tr('current_version_label', {'version': ''})),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    final aboutCategory = find.text(i18n.tr('about'));
    await tester.ensureVisible(aboutCategory);
    await tester.pumpAndSettle();
    await tester.tap(aboutCategory);
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
  });

  testWidgets('card info settings enforce the selected field limit', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();
    final bottomNavigationStyleTile = find.widgetWithText(
      SwitchListTile,
      i18n.tr('bottom_navigation_style'),
    );
    await Scrollable.ensureVisible(
      tester.element(bottomNavigationStyleTile),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(bottomNavigationStyleTile);
    await tester.pumpAndSettle();
    expect(
      harness.settingsRepository.bottomNavigationStyle,
      BottomNavigationStyle.bar,
    );

    final cardInfoTile = find.widgetWithText(
      ListTile,
      i18n.tr('card_info_display'),
    );
    await Scrollable.ensureVisible(
      tester.element(cardInfoTile),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(cardInfoTile);
    await tester.pumpAndSettle();

    expect(
      find.text(
        i18n.tr('card_info_display_subtitle', {'count': '4', 'max': '6'}),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(
        CheckboxListTile,
        i18n.tr('audio_detail_release_date'),
      ),
    );
    await tester.pump();
    expect(harness.settingsRepository.cardInfoFields, hasLength(5));
    final salesTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(
        CheckboxListTile,
        i18n.tr('audio_detail_sales_count'),
      ),
    );
    expect(salesTile.onChanged, isNotNull);

    await tester.tap(
      find.widgetWithText(
        CheckboxListTile,
        i18n.tr('audio_detail_sales_count'),
      ),
    );
    await tester.pump();

    expect(
      harness.settingsRepository.cardInfoFields,
      hasLength(CardInfoField.maxSelected),
    );
    final ratingTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, i18n.tr('audio_detail_rating')),
    );
    expect(ratingTile.onChanged, isNull);
  });

  testWidgets('update tile reflects checking and download progress', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    final updatesCategory = find.text(i18n.tr('section_updates_permissions'));
    await tester.ensureVisible(updatesCategory);
    await tester.pumpAndSettle();
    await tester.tap(updatesCategory);
    await tester.pumpAndSettle();

    final checkingCompleter = Completer<void>();
    final checking = harness.uiOperationService.run<void>(
      scope: UiOperationScope.settingsUpdate,
      labelKey: 'checking_updates',
      task: (_) => checkingCompleter.future,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(i18n.tr('checking_updates')), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, i18n.tr('check_updates')),
          )
          .onTap,
      isNull,
    );
    checkingCompleter.complete();
    await checking;
    await tester.pump();

    final downloadCompleter = Completer<void>();
    final download = harness.uiOperationService.run<void>(
      scope: UiOperationScope.settingsUpdate,
      labelKey: 'downloading_update',
      task: (progress) {
        progress.report(0.42);
        return downloadCompleter.future;
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text(i18n.tr('downloading_update', {'percent': '42'})),
      findsOneWidget,
    );
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, 0.42);
    downloadCompleter.complete();
    await download;
    await tester.pump();
  });
}
