import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/features/settings/presentation/settings_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

Future<void> _scrollTo(
  WidgetTester tester,
  ScrollableState scrollable,
  Finder finder,
) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byWidget(scrollable.widget),
  );
  await tester.pumpAndSettle();
}

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

  testWidgets('settings renders six sections in order with critical entries', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    expect(find.text(i18n.tr('dlsite_metadata_language')), findsOneWidget);
    expect(find.text(i18n.tr('follow_page_language')), findsOneWidget);
    expect(
      harness.settingsRepository.dlsiteMetadataLanguage,
      ContentLanguagePreference.followPage,
    );
    expect(
      harness.settingsRepository.dlsiteMetadataLanguage.resolve(
        harness.languageProvider.language,
      ),
      AppLanguage.zh,
    );
    await i18n.setLanguage(AppLanguage.en);
    await tester.pumpAndSettle();
    expect(
      harness.settingsRepository.dlsiteMetadataLanguage.resolve(
        harness.languageProvider.language,
      ),
      AppLanguage.en,
    );
    expect(find.text(i18n.tr('startup_page')), findsOneWidget);
    final scrollableFinder = find
        .descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollable = tester.state<ScrollableState>(scrollableFinder);
    final sections = <String, String>{
      'section_general': 'startup_page',
      'section_appearance': 'dark_mode',
      'section_playback': 'auto_play_added_sessions',
      'section_asmr_download': 'asmr_download_path_setting',
      'section_data_storage': 'data_and_support',
      'section_system_updates': 'check_updates',
    };
    var previousOffset = -1.0;

    for (final entry in sections.entries) {
      final header = find.text(i18n.tr(entry.key));
      await _scrollTo(tester, scrollable, header);
      expect(header, findsOneWidget);
      expect(find.text(i18n.tr(entry.value)), findsOneWidget);
      expect(scrollable.position.pixels, greaterThanOrEqualTo(previousOffset));
      previousOffset = scrollable.position.pixels;
    }

    expect(find.text(i18n.tr('data_and_support')), findsOneWidget);
    expect(
      find.text(i18n.tr('permission_center')),
      Platform.isWindows ? findsNothing : findsOneWidget,
    );

    final updateTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, i18n.tr('check_updates')),
    );
    expect(updateTile.onTap, isNotNull);
    expect(find.text(i18n.tr('auto_check_updates')), findsOneWidget);
    expect(
      find.textContaining(i18n.tr('current_version_label', {'version': ''})),
      findsOneWidget,
    );
  });

  testWidgets('card info settings enforce the selected field limit', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    final scrollableFinder = find
        .descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollable = tester.state<ScrollableState>(scrollableFinder);
    final bottomNavigationStyle = find.text(i18n.tr('bottom_navigation_style'));
    await _scrollTo(tester, scrollable, bottomNavigationStyle);
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

    final cardInfo = find.text(i18n.tr('card_info_display'));
    await _scrollTo(tester, scrollable, cardInfo);
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
    final scrollableFinder = find
        .descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollable = tester.state<ScrollableState>(scrollableFinder);
    final updateLabel = find.text(i18n.tr('check_updates'));
    await _scrollTo(tester, scrollable, updateLabel);

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
