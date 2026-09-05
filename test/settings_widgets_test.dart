import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/subtitle_window_visual.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:doujin_audio/features/settings/presentation/about_page.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
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
      'section_common',
      'section_appearance',
      'section_playback',
      'section_asmr_download',
      'section_data_storage',
      'section_updates_permissions',
      'about',
    ]) {
      expect(find.text(i18n.tr(key)), findsOneWidget);
      expect(find.text(i18n.tr('${key}_subtitle')), findsOneWidget);
    }

    expect(find.text(i18n.tr('section_language')), findsNothing);
    expect(
      tester
          .widget<TopPageHeader>(find.byType(TopPageHeader))
          .collapseController,
      isNull,
    );
    final rootList = tester.widget<ListView>(find.byType(ListView).first);
    expect(
      (rootList.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(AppSpacing.sm),
    );
    await tester.tap(find.text(i18n.tr('section_common')));
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
    final categoryHeaderWidget = tester.widget<TopPageHeader>(categoryHeader);
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(categoryHeaderWidget.padding, AppPageHeaderMetrics.padding);
    expect(
      categoryHeaderWidget.bottomSpacing,
      AppPageHeaderMetrics.bottomSpacing,
    );
    final firstLanguageTile = find.widgetWithText(
      ListTile,
      i18n.tr('interface_language'),
    );
    final categoryHeaderRect = tester.getRect(categoryHeader);
    expect(categoryHeaderRect.height, greaterThan(0));
    expect(
      tester.getTopLeft(firstLanguageTile).dy,
      greaterThan(categoryHeaderRect.bottom),
    );
    final languageIcon = tester.widget<Icon>(
      find.descendant(
        of: firstLanguageTile,
        matching: find.byIcon(Icons.language_rounded),
      ),
    );
    expect(languageIcon.size, 30);
    final languageTileHeight = tester.getSize(firstLanguageTile).height;
    expect(languageTileHeight, 78);
    final languageTileContext = tester.element(firstLanguageTile);
    final languageTileTheme = ListTileTheme.of(languageTileContext);
    expect(
      languageIcon.color,
      Theme.of(languageTileContext).colorScheme.onSurface,
    );
    expect(languageTileTheme.minTileHeight, 78);
    expect(languageTileTheme.titleTextStyle?.fontSize, closeTo(16, 0.001));
    expect(languageTileTheme.subtitleTextStyle?.fontSize, closeTo(13, 0.001));
    expect(
      Theme.of(languageTileContext).textTheme.titleMedium?.fontSize,
      closeTo(16, 0.001),
    );
    expect(
      tester.getTopLeft(firstLanguageTile).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(categoryHeader).dy),
    );
    final dlsiteLanguageTile = find.widgetWithText(
      ListTile,
      i18n.tr('dlsite_metadata_language'),
    );
    final asmrLanguageTile = find.widgetWithText(
      ListTile,
      i18n.tr('asmr_page_language'),
    );
    expect(tester.getSize(dlsiteLanguageTile).height, 78);
    expect(tester.getSize(asmrLanguageTile).height, 78);
    final firstLanguageCard = find.ancestor(
      of: firstLanguageTile,
      matching: find.byType(Card),
    );
    final dlsiteLanguageCard = find.ancestor(
      of: dlsiteLanguageTile,
      matching: find.byType(Card),
    );
    expect(
      tester.getTopLeft(dlsiteLanguageCard).dy -
          tester.getBottomLeft(firstLanguageCard).dy,
      closeTo(3, 0.001),
    );
    final pageDisplayPill = find.byKey(
      const ValueKey<String>('settings_section_pill_common_1'),
    );
    expect(pageDisplayPill, findsOneWidget);
    expect(
      find.descendant(
        of: pageDisplayPill,
        matching: find.text(i18n.tr('settings_group_page_display')),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(pageDisplayPill).dy,
      greaterThan(tester.getTopLeft(firstLanguageCard).dy),
    );
    expect(
      find.byKey(const ValueKey<String>('settings_show_asmr_one_switch')),
      findsOneWidget,
    );
    expect(find.text(i18n.tr('startup_page')), findsOneWidget);
    expect(find.text(i18n.tr('portrait_lock')), findsOneWidget);
    expect(
      find.text(i18n.tr('startup_playback_restore_behavior')),
      findsOneWidget,
    );
    expect(find.text(i18n.tr('allow_duplicate_works')), findsOneWidget);
    expect(find.text(i18n.tr('reduce_animations')), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              i18n.tr('allow_duplicate_works'),
            ),
          )
          .subtitle,
      isNull,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, i18n.tr('reduce_animations')),
          )
          .subtitle,
      isNull,
    );
    final hapticFeedbackTile = find.widgetWithText(
      SwitchListTile,
      i18n.tr('haptic_feedback_enabled'),
    );
    expect(hapticFeedbackTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(hapticFeedbackTile).value, isTrue);
    await tester.ensureVisible(hapticFeedbackTile);
    await tester.pumpAndSettle();
    await tester.tap(hapticFeedbackTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(hapticFeedbackTile).value, isFalse);
    expect(harness.settingsRepository.hapticFeedbackEnabled, isFalse);
    expect(AppInteractionFeedback.hapticFeedbackEnabled, isFalse);
    await tester.tap(hapticFeedbackTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(hapticFeedbackTile).value, isTrue);
    expect(harness.settingsRepository.hapticFeedbackEnabled, isTrue);
    expect(AppInteractionFeedback.hapticFeedbackEnabled, isTrue);
    final portraitLockTile = find.widgetWithText(
      SwitchListTile,
      i18n.tr('portrait_lock'),
    );
    expect(tester.widget<SwitchListTile>(portraitLockTile).value, isFalse);
    await tester.ensureVisible(portraitLockTile);
    await tester.pumpAndSettle();
    await tester.tap(portraitLockTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(portraitLockTile).value, isTrue);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text(i18n.tr('section_playback')));
    await tester.pumpAndSettle();
    final allowVideoPlaybackTile = find.byKey(
      const ValueKey<String>('allow_video_playback_switch'),
    );
    expect(allowVideoPlaybackTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(allowVideoPlaybackTile).value, isTrue);
    await tester.ensureVisible(allowVideoPlaybackTile);
    await tester.tap(allowVideoPlaybackTile);
    await tester.pump();
    expect(harness.settingsRepository.allowVideoPlayback, isFalse);
    expect(
      tester.widget<SwitchListTile>(allowVideoPlaybackTile).value,
      isFalse,
    );
    expect(
      find.text(i18n.tr('audio_device_disconnect_behavior')),
      findsOneWidget,
    );
    expect(find.text(i18n.tr('audio_focus_strategy')), findsOneWidget);
    expect(
      find.text(i18n.tr('transient_audio_focus_loss_behavior')),
      findsOneWidget,
    );
    expect(find.text(i18n.tr('interruption_resume_behavior')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    final updatesCategory = find.text(i18n.tr('section_updates_permissions'));
    await tester.ensureVisible(updatesCategory);
    await tester.pumpAndSettle();
    await tester.tap(updatesCategory);
    await tester.pumpAndSettle();
    final notificationTile = find.text(
      i18n.tr('notification_permission_status'),
    );
    expect(notificationTile, findsOneWidget);
    expect(
      find.ancestor(of: notificationTile, matching: find.byType(Card)),
      findsOneWidget,
    );
    expect(find.text(i18n.tr('install_permission_title')), findsOneWidget);
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
    final aboutHeaderRect = tester.getRect(find.byType(TopPageHeader));
    expect(aboutHeaderRect.height, greaterThan(0));
    final aboutTitle = find.text(i18n.tr('app_title'));
    final aboutTitleContext = tester.element(aboutTitle);
    final firstAboutCard = tester
        .widgetList<Container>(
          find.ancestor(of: aboutTitle, matching: find.byType(Container)),
        )
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).color ==
                  Theme.of(aboutTitleContext).colorScheme.surfaceContainerLow,
        );
    expect(
      tester.getTopLeft(find.byWidget(firstAboutCard)).dy,
      greaterThan(aboutHeaderRect.bottom),
    );
  });

  testWidgets('settings category headers become sticky floating pills', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();
    expect(find.text(i18n.tr('settings_group_page_display')), findsNothing);

    final categoryHeader = find.byType(TopPageHeader);
    final startupPill = find.byKey(
      const ValueKey<String>('settings_section_pill_appearance_0'),
    );
    expect(startupPill, findsOneWidget);
    final startupSurface = find.descendant(
      of: startupPill,
      matching: find.byType(HeaderFloatingSurface),
    );
    expect(startupSurface, findsOneWidget);
    // Width is determined by text length rather than stretching to full width
    expect(tester.getSize(startupSurface).width, lessThan(300));
    expect(tester.getTopLeft(startupSurface).dx, equals(16.0));
    // Initial distance between title bar capsule bottom and category pill top is 14.0px
    final initialAppearanceGap =
        tester.getTopLeft(startupPill).dy -
        tester.getRect(categoryHeader).bottom;
    expect(initialAppearanceGap, closeTo(14.0, 0.5));
    expect(
      find.byKey(const ValueKey<String>('settings_sticky_section_pill')),
      findsNothing,
    );

    final categoryList = find.byType(ListView).last;
    await tester.drag(categoryList, const Offset(0, -100));
    await tester.pumpAndSettle();

    final stickyPill = find.byKey(
      const ValueKey<String>('settings_sticky_section_pill'),
    );
    expect(stickyPill, findsOneWidget);
    expect(
      find.descendant(
        of: stickyPill,
        matching: find.text(i18n.tr('settings_group_theme_layout')),
      ),
      findsOneWidget,
    );
    final stickySurface = find.descendant(
      of: stickyPill,
      matching: find.byType(HeaderFloatingSurface),
    );
    expect(tester.getSize(stickySurface).width, lessThan(300));
    expect(tester.getTopLeft(stickySurface).dx, equals(16.0));
    // Pinned gap between title bar capsule bottom and sticky pill top is 6.0px (consistent with main header two rows)
    expect(
      tester.getTopLeft(stickyPill).dy - tester.getRect(categoryHeader).bottom,
      closeTo(6.0, 0.5),
    );
    // When section is pinned, its inline pill is hidden to avoid duplicate pills on screen
    final inlineVisibility = tester.widget<Visibility>(
      find.ancestor(of: startupPill, matching: find.byType(Visibility)).first,
    );
    expect(inlineVisibility.visible, isFalse);

    final coverTitle = find.text(i18n.tr('settings_group_cover_background'));
    await Scrollable.ensureVisible(tester.element(coverTitle), alignment: 0.05);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: stickyPill,
        matching: find.text(i18n.tr('settings_group_cover_background')),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    // Check main settings page content gap
    final mainSettingsHeader = find.byType(TopPageHeader);
    final firstMainCard = find
        .ancestor(
          of: find.text(i18n.tr('section_common')),
          matching: find.byType(Card),
        )
        .first;
    final mainPageGap =
        tester.getTopLeft(firstMainCard).dy -
        tester.getRect(mainSettingsHeader).bottom;
    expect(mainPageGap, closeTo(14.0, 0.5));

    expect(find.text(i18n.tr('section_language')), findsNothing);
  });

  testWidgets(
    'data storage category places storage overview above embedded support actions',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pump();

      final i18n = harness.languageProvider;
      final category = find.text(i18n.tr('section_data_storage'));
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();

      final storage = find.byKey(
        const ValueKey('data-support-storage-unavailable'),
      );
      final exportBackup = find.byKey(
        const ValueKey<String>('data-support-export-backup'),
      );
      final restoreBackup = find.byKey(
        const ValueKey<String>('data-support-restore-backup'),
      );
      final exportDiagnostics = find.byKey(
        const ValueKey<String>('data-support-export-diagnostics'),
      );
      final privacySummary = find.byKey(
        const ValueKey<String>('data-support-privacy-summary'),
      );
      expect(storage, findsOneWidget);
      expect(exportBackup, findsOneWidget);
      expect(restoreBackup, findsOneWidget);
      expect(exportDiagnostics, findsOneWidget);
      expect(privacySummary, findsOneWidget);
      expect(
        tester.getTopLeft(storage).dy,
        lessThan(tester.getTopLeft(exportBackup).dy),
      );
      final exportCard = find.ancestor(
        of: exportBackup,
        matching: find.byType(Card),
      );
      expect(exportCard, findsOneWidget);
      final restoreCard = find.ancestor(
        of: restoreBackup,
        matching: find.byType(Card),
      );
      expect(restoreCard, findsOneWidget);
      expect(
        tester.getTopLeft(restoreCard).dy - tester.getBottomLeft(exportCard).dy,
        closeTo(3, 0.001),
      );
    },
  );

  testWidgets(
    'ASMR download settings expose metadata and folder name choices',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pump();

      final i18n = harness.languageProvider;
      final category = find.text(i18n.tr('section_asmr_download'));
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();

      final metadataTile = find.widgetWithText(
        SwitchListTile,
        i18n.tr('asmr_download_save_metadata_setting'),
      );
      expect(metadataTile, findsOneWidget);
      expect(tester.widget<SwitchListTile>(metadataTile).value, isTrue);
      final coverTile = find.widgetWithText(
        SwitchListTile,
        i18n.tr('asmr_download_save_cover'),
      );
      expect(coverTile, findsOneWidget);
      final coverListTile = tester.widget<SwitchListTile>(coverTile);
      expect(coverListTile.value, isTrue);
      expect(coverListTile.title, isA<Text>());
      expect(coverListTile.subtitle, isNull);

      final retryTile = find.widgetWithText(
        ListTile,
        i18n.tr('asmr_download_retry_count'),
      );
      final threadTile = find.widgetWithText(
        ListTile,
        i18n.tr('asmr_download_thread_count'),
      );
      expect(retryTile, findsOneWidget);
      expect(tester.widget<ListTile>(retryTile).title, isA<Text>());
      expect(tester.widget<ListTile>(retryTile).subtitle, isNull);
      expect(threadTile, findsOneWidget);
      expect(tester.widget<ListTile>(threadTile).title, isA<Text>());
      expect(tester.widget<ListTile>(threadTile).subtitle, isNull);
      expect(find.text(i18n.tr('asmr_download_thread_count')), findsOneWidget);

      final retryDropdown = find.descendant(
        of: retryTile,
        matching: find.byType(DropdownButton<int>),
      );
      final threadDropdown = find.descendant(
        of: threadTile,
        matching: find.byType(DropdownButton<int>),
      );
      expect(retryDropdown, findsOneWidget);
      expect(threadDropdown, findsOneWidget);
      expect(tester.getSize(retryDropdown).width, greaterThan(0));
      expect(
        tester.getSize(retryDropdown).width,
        greaterThan(tester.getSize(threadDropdown).width),
      );
      expect(
        find.text(i18n.tr('asmr_download_folder_name_setting')),
        findsOneWidget,
      );
      expect(
        find.text(i18n.tr('asmr_download_folder_field_work_title')),
        findsOneWidget,
      );
      final folderNameTile = find.widgetWithText(
        ListTile,
        i18n.tr('asmr_download_folder_name_setting'),
      );
      expect(folderNameTile, findsOneWidget);
      final folderNameTileTheme = ListTileTheme.of(
        tester.element(folderNameTile),
      );
      expect(folderNameTileTheme.titleAlignment, ListTileTitleAlignment.center);
      expect(tester.widget<ListTile>(folderNameTile).subtitle, isNull);
      final folderNameTitleRect = tester.getRect(
        find.text(i18n.tr('asmr_download_folder_name_setting')),
      );
      final folderNameSubtitleRect = tester.getRect(
        find.text(i18n.tr('asmr_download_folder_field_work_title')),
      );
      expect(
        (folderNameTitleRect.top + folderNameSubtitleRect.bottom) / 2,
        closeTo(tester.getRect(folderNameTile).center.dy, 1),
      );

      final folderNameSetting = find.text(
        i18n.tr('asmr_download_folder_name_setting'),
      );
      await tester.ensureVisible(folderNameSetting);
      await tester.pumpAndSettle();
      await tester.tap(folderNameSetting);
      await tester.pumpAndSettle();
      expect(
        find.text(i18n.tr('asmr_download_folder_name_hint')),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNWidgets(4));

      final workTitleCheckbox = tester.widget<CheckboxListTile>(
        find.widgetWithText(
          CheckboxListTile,
          i18n.tr('asmr_download_folder_field_work_title'),
        ),
      );
      expect(workTitleCheckbox.value, isTrue);
      expect(workTitleCheckbox.onChanged, isNull);

      await tester.tap(
        find.widgetWithText(
          CheckboxListTile,
          i18n.tr('asmr_download_folder_field_rj_code'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(
                CheckboxListTile,
                i18n.tr('asmr_download_folder_field_rj_code'),
              ),
            )
            .value,
        isTrue,
      );
    },
  );

  testWidgets('setting row icons share one horizontal center', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    final asmrCategory = find.text(i18n.tr('section_asmr_download'));
    await tester.ensureVisible(asmrCategory);
    await tester.tap(asmrCategory);
    await tester.pumpAndSettle();

    _expectIconCentersAligned(tester, const [
      Icons.folder_rounded,
      Icons.rule_folder_rounded,
      Icons.description_outlined,
      Icons.drive_file_rename_outline,
    ]);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    final updatesCategory = find.text(i18n.tr('section_updates_permissions'));
    await tester.ensureVisible(updatesCategory);
    await tester.tap(updatesCategory);
    await tester.pumpAndSettle();

    _expectIconCentersAligned(tester, const [
      Icons.notifications_rounded,
      Icons.system_update_alt_rounded,
      Icons.update_rounded,
    ]);
  });

  testWidgets('ASMR folder name reorder keeps tap identity', (tester) async {
    final settingsRepository = _DeferredFolderNameSettingsRepository();
    final harness = AppRuntimeWidgetTestFixture(
      providedSettingsRepository: settingsRepository,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    final asmrCategory = find.text(i18n.tr('section_asmr_download'));
    await tester.ensureVisible(asmrCategory);
    await tester.tap(asmrCategory);
    await tester.pumpAndSettle();
    final folderNameSetting = find.text(
      i18n.tr('asmr_download_folder_name_setting'),
    );
    await tester.ensureVisible(folderNameSetting);
    await tester.pumpAndSettle();
    await tester.tap(folderNameSetting);
    await tester.pumpAndSettle();

    final workTitle = i18n.tr('asmr_download_folder_field_work_title');
    final rjCode = i18n.tr('asmr_download_folder_field_rj_code');

    final workTile = find.widgetWithText(CheckboxListTile, workTitle);
    final workHandle = find.descendant(
      of: workTile,
      matching: find.byType(ReorderableDragStartListener),
    );
    await tester.drag(workHandle, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(settingsRepository.folderNameFieldUpdates.single, const [
      AsmrDownloadFolderNameField.rjCode,
      AsmrDownloadFolderNameField.workTitle,
    ]);
    expect(
      tester.getTopLeft(find.widgetWithText(CheckboxListTile, rjCode)).dy,
      lessThan(
        tester.getTopLeft(find.widgetWithText(CheckboxListTile, workTitle)).dy,
      ),
      reason: 'The rendered order must update before persistence completes.',
    );

    await tester.tap(find.widgetWithText(CheckboxListTile, workTitle));
    await tester.pumpAndSettle();
    expect(settingsRepository.folderNameFieldUpdates.last, const [
      AsmrDownloadFolderNameField.rjCode,
    ]);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, workTitle),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, rjCode),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('card info fields reorder like download folder name fields', (
    tester,
  ) async {
    final settingsRepository = _DeferredCardInfoSettingsRepository();
    final harness = AppRuntimeWidgetTestFixture(
      providedSettingsRepository: settingsRepository,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();
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

    final rjCode = i18n.tr('audio_detail_rj_code');
    final voiceActors = i18n.tr('audio_detail_voice_actors');
    final initialReorderableKey = tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .key;
    final rjTile = find.widgetWithText(CheckboxListTile, rjCode);
    final rjHandle = find.descendant(
      of: rjTile,
      matching: find.byType(ReorderableDragStartListener),
    );

    await tester.drag(rjHandle, const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ReorderableListView>(find.byType(ReorderableListView)).key,
      isNot(initialReorderableKey),
    );
    expect(settingsRepository.cardInfoFieldUpdates.single, const [
      CardInfoField.voiceActors,
      CardInfoField.rjCode,
    ]);
    expect(
      tester.getTopLeft(find.widgetWithText(CheckboxListTile, voiceActors)).dy,
      lessThan(
        tester.getTopLeft(find.widgetWithText(CheckboxListTile, rjCode)).dy,
      ),
      reason: 'The rendered order must update before persistence completes.',
    );

    final reorderedRjTile = find.widgetWithText(CheckboxListTile, rjCode);
    await tester.tap(
      find.descendant(of: reorderedRjTile, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(settingsRepository.cardInfoFieldUpdates.last, const [
      CardInfoField.voiceActors,
    ]);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, rjCode),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('settings home uses separated category cards', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    final headerCapsule = find.byType(HeaderTopCapsule);
    expect(headerCapsule, findsOneWidget);
    expect(find.byIcon(Icons.settings_rounded), findsOneWidget);
    final rootTile = find.widgetWithText(ListTile, i18n.tr('section_common'));
    final rootContext = tester.element(rootTile);
    final rootIcon = tester.widget<Icon>(
      find.descendant(of: rootTile, matching: find.byIcon(Icons.tune_rounded)),
    );
    expect(rootIcon.color, Theme.of(rootContext).colorScheme.onSurface);
    expect(tester.widget<ListTile>(rootTile).trailing, isNull);
    final rootCard = tester.widget<Card>(
      find.ancestor(of: rootTile, matching: find.byType(Card)).first,
    );
    final firstCardFinder = find
        .ancestor(of: rootTile, matching: find.byType(Card))
        .first;
    final headerWidget = tester.widget<HeaderTopCapsule>(headerCapsule);
    expect(
      tester.getTopLeft(firstCardFinder).dy -
          tester.getBottomLeft(headerCapsule).dy,
      closeTo(
        AppPageHeaderMetrics.contentHeight -
            headerWidget.height +
            AppPageHeaderMetrics.bottomSpacing +
            AppPageHeaderMetrics.firstContentSpacing,
        0.001,
      ),
    );
    expect(
      rootCard.color,
      Theme.of(rootContext).colorScheme.surfaceContainerLow,
    );
    final rootBorderRadius =
        (rootCard.shape! as RoundedRectangleBorder).borderRadius
            as BorderRadius;
    expect(rootBorderRadius.topLeft, const Radius.circular(12));
    expect(rootBorderRadius.bottomLeft, const Radius.circular(6));
    final aboutCard = find.ancestor(
      of: find.widgetWithText(ListTile, i18n.tr('about')),
      matching: find.byType(Card),
    );
    final lastCardShape =
        tester.widget<Card>(aboutCard.first).shape! as RoundedRectangleBorder;
    final lastBorderRadius = lastCardShape.borderRadius as BorderRadius;
    expect(lastBorderRadius.topLeft, const Radius.circular(6));
    expect(lastBorderRadius.bottomLeft, const Radius.circular(12));

    await tester.tap(rootTile);
    await tester.pumpAndSettle();

    final detailTile = find.widgetWithText(ListTile, i18n.tr('startup_page'));
    final detailContext = tester.element(detailTile);
    final detailIcon = tester.widget<Icon>(
      find.descendant(
        of: detailTile,
        matching: find.byIcon(Icons.home_rounded),
      ),
    );
    final colorScheme = Theme.of(detailContext).colorScheme;
    expect(detailIcon.color, colorScheme.onSurface);
    expect(
      find.ancestor(of: detailTile, matching: find.byType(Card)),
      findsOneWidget,
      reason: 'Settings secondary-page items should reuse the card style.',
    );
    final detailCardShape =
        tester
                .widget<Card>(
                  find
                      .ancestor(of: detailTile, matching: find.byType(Card))
                      .first,
                )
                .shape!
            as RoundedRectangleBorder;
    final detailBorderRadius = detailCardShape.borderRadius as BorderRadius;
    expect(detailBorderRadius.topLeft, const Radius.circular(12));
    expect(
      tester
          .widget<Card>(
            find.ancestor(of: detailTile, matching: find.byType(Card)).first,
          )
          .color,
      colorScheme.surfaceContainerLow,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scaffold && widget.backgroundColor == colorScheme.surface,
      ),
      findsOneWidget,
    );
  });

  testWidgets('subtitle window preview omits the explanatory hint', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final subtitleSettings = find.widgetWithText(
      ListTile,
      i18n.tr('subtitle_window_settings'),
    );
    await tester.ensureVisible(subtitleSettings);
    await tester.pumpAndSettle();
    await tester.tap(subtitleSettings);
    await tester.pumpAndSettle();

    expect(find.text(i18n.tr('subtitle_window_preview')), findsOneWidget);
    expect(find.text(i18n.tr('font_color')), findsOneWidget);
    expect(i18n.tr('font_color'), '文字颜色');
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('subtitle_window_preview_card')),
          )
          .height,
      176,
    );
    final previewText = tester.widget<Text>(
      find.text(i18n.tr('subtitle_preview_sample')),
    );
    expect(previewText.style?.color, Colors.white);
    expect(previewText.style?.fontWeight, FontWeight.normal);
    final previewSurface = tester.widget<Container>(
      find.byKey(const ValueKey<String>('subtitle_window_visual_surface')),
    );
    final previewDecoration = previewSurface.decoration! as BoxDecoration;
    final previewRadius = previewDecoration.borderRadius! as BorderRadius;
    expect(previewRadius.topLeft.x, closeTo(19.2, 0.001));
    expect(
      (previewDecoration.border! as Border).top.color,
      const Color(0x40FFFFFF),
    );
    expect((previewDecoration.border! as Border).top.width, 2);
    expect(find.text('下方继续滚动调节参数，这里会固定位置并同步刷新。'), findsNothing);
  });

  testWidgets('subtitle preview fallback text stays white in both themes', (
    tester,
  ) async {
    for (final theme in <ThemeData>[ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: SubtitleWindowVisual(
                settings: SubtitleSettingsState(),
                text: 'Theme independent subtitle',
                maxTextWidth: 260,
              ),
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Theme independent subtitle'));
      expect(text.style?.color, Colors.white);
      expect(text.style?.fontWeight, FontWeight.normal);
    }
  });

  testWidgets('settings bottom gap matches the shared mobile overlay inset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const overlayInset = 96.0;

    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      harness.build(
        const MobileOverlayInset(
          bottomInset: overlayInset,
          child: SettingsTab(),
        ),
      ),
    );
    await tester.pump();

    final aboutTile = find.widgetWithText(
      ListTile,
      harness.languageProvider.tr('about'),
    );
    await tester.scrollUntilVisible(
      aboutTile,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1000));
    await tester.pumpAndSettle();

    final viewportBottom = tester.getBottomLeft(find.byType(Scaffold).first).dy;
    final lastTileBottom = tester.getBottomLeft(aboutTile).dy;
    expect(viewportBottom - lastTileBottom, greaterThanOrEqualTo(overlayInset));
  });

  testWidgets('settings titles and choices wrap on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_common')));
    await tester.pumpAndSettle();

    final restoreTileFinder = find.widgetWithText(
      ListTile,
      i18n.tr('startup_playback_restore_behavior'),
    );
    final restoreTile = tester.widget<ListTile>(restoreTileFinder);
    final title = restoreTile.title! as Text;
    expect(title.softWrap, isTrue);
    expect(title.overflow, TextOverflow.visible);
    expect(tester.getSize(restoreTileFinder).height, greaterThan(58));

    final dropdownFinder = find.byType(
      DropdownButton<StartupPlaybackRestoreBehavior>,
    );
    final dropdown = tester
        .widget<DropdownButton<StartupPlaybackRestoreBehavior>>(dropdownFinder);
    expect(dropdown.isExpanded, isTrue);
    expect(dropdown.itemHeight, isNull);

    final optionPadding = dropdown.items!.first.child as Padding;
    final optionText = optionPadding.child! as Text;
    expect(optionText.maxLines, isNull);
    expect(optionText.softWrap, isTrue);
    expect(optionText.overflow, TextOverflow.visible);
  });

  testWidgets('interface language dropdown stays compact', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await harness.languageProvider.setLanguage(AppLanguage.zh);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pumpAndSettle();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_common')));
    await tester.pumpAndSettle();

    final interfaceLanguageTile = find.widgetWithText(
      ListTile,
      i18n.tr('interface_language'),
    );
    final dropdown = find.descendant(
      of: interfaceLanguageTile,
      matching: find.byType(DropdownButton<AppLanguagePreference>),
    );

    expect(dropdown, findsOneWidget);
    expect(tester.getSize(dropdown).width, lessThanOrEqualTo(128));
  });

  testWidgets(
    'settings dropdowns remain usable across locales and large text',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      for (final width in <double>[320, 360]) {
        await tester.binding.setSurfaceSize(Size(width, 720));
        for (final language in AppLanguage.values) {
          await harness.languageProvider.setLanguage(language);
          for (final scale in <double>[1, 2, 3]) {
            await tester.pumpWidget(
              harness.build(
                MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 720),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: const SettingsTab(),
                ),
              ),
            );
            await tester.pumpAndSettle();

            final i18n = harness.languageProvider;
            await tester.tap(find.text(i18n.tr('section_common')));
            await tester.pumpAndSettle();
            final tile = find.widgetWithText(
              ListTile,
              i18n.tr('startup_playback_restore_behavior'),
            );
            expect(tile, findsOneWidget);
            expect(tester.getSize(tile).height, greaterThanOrEqualTo(58));
            expect(
              tester.takeException(),
              isNull,
              reason: 'width=$width language=${language.name} scale=$scale',
            );

            if (scale == 3) {
              await Scrollable.ensureVisible(
                tester.element(tile),
                alignment: 0.5,
              );
              await tester.pumpAndSettle();
              final dropdown = find.byType(
                DropdownButton<StartupPlaybackRestoreBehavior>,
              );
              await tester.tap(dropdown);
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason:
                    'open menu width=$width language=${language.name} '
                    'scale=$scale',
              );
              final pauseOption = find.text(
                i18n.tr('startup_playback_restore_pause'),
              );
              expect(pauseOption, findsWidgets);
              await tester.tap(pauseOption.last);
              await tester.pumpAndSettle();
            }
          }
        }
      }
    },
  );

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

  testWidgets('appearance changes playback detail subtitle style', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final title = find.text(i18n.tr('playback_detail_subtitle_style'));
    await Scrollable.ensureVisible(tester.element(title), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<PlaybackDetailSubtitleStyle>));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(i18n.tr('playback_detail_subtitle_style_timeline')).last,
    );
    await tester.pumpAndSettle();

    expect(
      harness.settingsRepository.playbackDetailSubtitleStyle,
      PlaybackDetailSubtitleStyle.timeline,
    );
  });

  testWidgets('appearance toggles the blurred playback detail background', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final toggle = find.widgetWithText(
      SwitchListTile,
      i18n.tr('blur_player_background'),
    );
    await Scrollable.ensureVisible(tester.element(toggle), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(harness.settingsRepository.blurPlayerBackgroundEnabled, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(harness.settingsRepository.blurPlayerBackgroundEnabled, isFalse);
  });

  testWidgets('appearance offers the 1200px cover resolution', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final title = find.text(i18n.tr('cover_image_resolution'));
    await Scrollable.ensureVisible(tester.element(title), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<CoverImageResolution>));
    await tester.pumpAndSettle();

    expect(find.text('300px'), findsWidgets);
    expect(find.text('600px'), findsWidgets);
    expect(find.text('900px'), findsWidgets);
    expect(find.text('1200px'), findsOneWidget);
    expect(find.text('原画'), findsOneWidget);

    await tester.tap(find.text('1200px'));
    await tester.pumpAndSettle();
    expect(
      harness.settingsRepository.coverImageResolution,
      CoverImageResolution.ultraHigh,
    );
  });

  testWidgets('appearance changes the global cover display mode', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final title = find.text(i18n.tr('cover_image_display_mode'));
    await Scrollable.ensureVisible(tester.element(title), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<CoverImageDisplayMode>));
    await tester.pumpAndSettle();

    expect(find.text(i18n.tr('cover_image_display_mode_fill')), findsWidgets);
    expect(
      find.text(i18n.tr('cover_image_display_mode_stretch')),
      findsOneWidget,
    );
    expect(find.text(i18n.tr('cover_image_display_mode_tile')), findsOneWidget);

    await tester.tap(find.text(i18n.tr('cover_image_display_mode_tile')));
    await tester.pumpAndSettle();
    expect(
      harness.settingsRepository.coverImageDisplayMode,
      CoverImageDisplayMode.tile,
    );
  });

  testWidgets('appearance toggles embedded audio cover preference', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('prefer_embedded_audio_cover_switch'),
    );
    await Scrollable.ensureVisible(tester.element(toggle), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(harness.settingsRepository.preferEmbeddedAudioCover, isTrue);
    final initialCoverGeneration =
        harness.runtimeGraph.library.coverArtworkCacheService.generation;

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(harness.settingsRepository.preferEmbeddedAudioCover, isFalse);
    expect(
      harness.runtimeGraph.library.coverArtworkCacheService.generation,
      initialCoverGeneration + 1,
    );
  });

  testWidgets('appearance selects app and conditional ASMR theme colors', (
    tester,
  ) async {
    await AppPreferences.init();
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();
    final themeProvider = ProviderScope.containerOf(
      tester.element(find.byType(SettingsTab)),
      listen: false,
    ).read(themeProviderInstanceProvider);

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app_theme_color_tile')), findsOneWidget);
    expect(find.byKey(const ValueKey('asmr_theme_color_tile')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app_theme_color_tile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme_color_grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme_color_dialog')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester.getCenter(find.byKey(const ValueKey('theme_color_dialog'))),
      tester.getCenter(find.byType(MaterialApp)),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('theme_color_grid')),
        matching: find.byType(InkWell),
      ),
      findsNWidgets(16),
    );
    final mintChoice = find.byKey(const ValueKey('theme_color_mint'));
    final mintSwatch = tester.widget<AnimatedContainer>(
      find.descendant(of: mintChoice, matching: find.byType(AnimatedContainer)),
    );
    expect(
      (mintSwatch.decoration! as BoxDecoration).color,
      ThemeAccentPreset.mint.colorScheme(Brightness.light).primary,
    );
    await tester.tap(mintChoice);
    await tester.pumpAndSettle();
    expect(themeProvider.appThemeColor, ThemeAccentPreset.mint);
    final appIndicator = tester.widget<Container>(
      find.byKey(const ValueKey('app_theme_color_indicator')),
    );
    expect(
      (appIndicator.decoration! as BoxDecoration).color,
      themeProvider.lightTheme.colorScheme.primary,
    );

    final switchTile = find.widgetWithText(
      SwitchListTile,
      i18n.tr('differentiate_asmr_theme'),
    );
    await Scrollable.ensureVisible(tester.element(switchTile), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app_theme_color_tile')), findsOneWidget);
    expect(find.byKey(const ValueKey('asmr_theme_color_tile')), findsNothing);
    final appThemeColorTile = find.byKey(
      const ValueKey('app_theme_color_tile'),
    );
    await tester.ensureVisible(appThemeColorTile);
    expect(tester.getSize(appThemeColorTile).height, 78);

    await Scrollable.ensureVisible(tester.element(switchTile), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('asmr_theme_color_tile')), findsOneWidget);
    final asmrThemeColorTile = find.byKey(
      const ValueKey('asmr_theme_color_tile'),
    );
    await Scrollable.ensureVisible(
      tester.element(asmrThemeColorTile),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(asmrThemeColorTile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme_color_orange')));
    await tester.pumpAndSettle();
    expect(themeProvider.asmrThemeColor, ThemeAccentPreset.orange);
  });

  testWidgets('appearance reports a failed theme preference write', (
    tester,
  ) async {
    await AppPreferences.init();
    final harness = AppRuntimeWidgetTestFixture();
    final themeProvider = ThemeProvider(
      preferenceWriter: (_, _) async => false,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      harness.build(const SettingsTab(), themeProvider: themeProvider),
    );
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app_theme_color_tile')));
    await tester.pumpAndSettle();
    final targetPreset = ThemeAccentPreset.values.firstWhere(
      (preset) => preset != themeProvider.appThemeColor,
    );
    await tester.tap(find.byKey(ValueKey('theme_color_${targetPreset.name}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const ValueKey('theme_color_dialog')), findsNothing);
    expect(themeProvider.appThemeColor, isNot(targetPreset));
    expect(
      find.textContaining(i18n.tr('operation_failed_retry')),
      findsOneWidget,
    );
  });

  testWidgets(
    'pure black theme switch is hidden in light appearance and visible in dark appearance',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);

      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pump();
      final themeProvider = ProviderScope.containerOf(
        tester.element(find.byType(SettingsTab)),
        listen: false,
      ).read(themeProviderInstanceProvider);

      final i18n = harness.languageProvider;
      await tester.tap(find.text(i18n.tr('section_appearance')));
      await tester.pumpAndSettle();

      // 1. In default light appearance, the switch is not shown
      expect(find.byKey(const ValueKey('pure_black_theme_tile')), findsNothing);

      // 2. Switch to dark appearance
      await themeProvider.setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();

      final pureBlackSwitch = find.byKey(
        const ValueKey('pure_black_theme_tile'),
      );
      expect(pureBlackSwitch, findsOneWidget);
      expect(find.text(i18n.tr('black_theme')), findsOneWidget);
      expect(themeProvider.pureBlackTheme, isFalse);

      await Scrollable.ensureVisible(
        tester.element(pureBlackSwitch),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();

      await tester.tap(pureBlackSwitch);
      await tester.pumpAndSettle();

      expect(themeProvider.pureBlackTheme, isTrue);

      await tester.tap(pureBlackSwitch);
      await tester.pumpAndSettle();

      expect(themeProvider.pureBlackTheme, isFalse);

      // 3. Switch back to light appearance, the switch is hidden again
      await themeProvider.setThemeMode(ThemeMode.light);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('pure_black_theme_tile')), findsNothing);
    },
  );

  testWidgets('disabling multi-thread playback closes facade sessions', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture(
      providedNativePlaybackRepository: _SuccessfulPauseAllRepository(),
    );
    addTearDown(harness.dispose);
    await harness.settingsRepository.setMultiThreadPlaybackEnabled(true);
    harness.settingsRepository.syncSlice(isInitialized: true);
    final session = PlaybackSession(
      id: 'active-session',
      currentTrackPath: '/audio/track.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.shutdown);
    harness.playbackService.sessions[session.id] = session;
    harness.playbackService.markActiveSessionsDirty();

    await tester.pumpWidget(
      harness.build(
        const SettingsTab(),
        overrides: [
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackStateSliceData>.empty(),
          ),
        ],
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsTab)),
      listen: false,
    );
    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_playback')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(SwitchListTile, i18n.tr('multi_thread_playback')),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(subtitleSettingsProvider).isShowEnabled('active-session'),
      isFalse,
    );
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

final class _SuccessfulPauseAllRepository extends NativePlaybackRepository {
  @override
  Future<NativeResult<void>> pauseAll() async {
    return const NativeSuccess<void>();
  }

  @override
  Future<void> dispose() async {}
}

void _expectIconCentersAligned(WidgetTester tester, List<IconData> icons) {
  final listFinder = find.byType(ListView);
  final expectedCenter = tester
      .getCenter(
        find.descendant(of: listFinder, matching: find.byIcon(icons.first)),
      )
      .dx;
  for (final icon in icons.skip(1)) {
    expect(
      tester
          .getCenter(
            find.descendant(of: listFinder, matching: find.byIcon(icon)),
          )
          .dx,
      closeTo(expectedCenter, 0.01),
      reason: '$icon should use the same leading slot as ${icons.first}.',
    );
  }
}

final class _DeferredFolderNameSettingsRepository extends SettingsRepository {
  _DeferredFolderNameSettingsRepository() {
    asmrDownloadFolderNameFields = const [
      AsmrDownloadFolderNameField.workTitle,
      AsmrDownloadFolderNameField.rjCode,
    ];
    syncSlice(isInitialized: true);
  }

  final List<List<AsmrDownloadFolderNameField>> folderNameFieldUpdates = [];
  final Completer<void> _pendingPersistence = Completer<void>();

  @override
  Future<void> setAsmrDownloadFolderNameFields(
    Iterable<AsmrDownloadFolderNameField> fields,
  ) {
    folderNameFieldUpdates.add(List.of(fields));
    return _pendingPersistence.future;
  }
}

final class _DeferredCardInfoSettingsRepository extends SettingsRepository {
  _DeferredCardInfoSettingsRepository() {
    cardInfoFields = const [CardInfoField.rjCode, CardInfoField.voiceActors];
    syncSlice(isInitialized: true);
  }

  final List<List<CardInfoField>> cardInfoFieldUpdates = [];
  final Completer<void> _pendingPersistence = Completer<void>();

  @override
  Future<void> setCardInfoFields(Iterable<CardInfoField> fields) {
    cardInfoFieldUpdates.add(List.of(fields));
    return _pendingPersistence.future;
  }
}
