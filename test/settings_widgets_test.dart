import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/app_language.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:nameless_audio/core/widgets/subtitle_window_visual.dart';
import 'package:nameless_audio/app/state/subtitle_settings_provider.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
import 'package:nameless_audio/features/settings/presentation/settings_tab.dart';
import 'package:nameless_audio/features/settings/presentation/about_page.dart';
import 'package:nameless_audio/core/widgets/top_page_header.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:nameless_audio/app/theme/app_styles.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
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
      expect(find.text(i18n.tr('${key}_subtitle')), findsOneWidget);
    }

    final rootLanguageTile = find.widgetWithText(
      ListTile,
      i18n.tr('section_language'),
    );
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
    final rootHeaderRect = tester.getRect(find.byType(TopPageHeader));
    final rootFirstItemSpacing =
        tester.getTopLeft(rootLanguageTile).dy - rootHeaderRect.bottom;
    final rootLanguageIcon = tester.widget<Icon>(
      find.descendant(
        of: rootLanguageTile,
        matching: find.byIcon(Icons.language_rounded),
      ),
    );
    expect(rootLanguageIcon.size, 30);
    expect(tester.getSize(rootLanguageTile).height, 78);
    final rootTileTheme = ListTileTheme.of(tester.element(rootLanguageTile));
    expect(rootTileTheme.minTileHeight, 78);
    expect(rootTileTheme.titleTextStyle?.fontSize, 18);
    expect(rootTileTheme.titleTextStyle?.fontWeight, FontWeight.bold);
    expect(rootTileTheme.subtitleTextStyle?.fontSize, 14);
    expect(rootTileTheme.subtitleTextStyle?.fontWeight, FontWeight.normal);
    final rootLanguageContext = tester.element(rootLanguageTile);
    expect(
      rootTileTheme.subtitleTextStyle?.color,
      Theme.of(
        rootLanguageContext,
      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.68),
    );
    final rootTitleRect = tester.getRect(
      find.text(i18n.tr('section_language')),
    );
    final rootSubtitleRect = tester.getRect(
      find.text(i18n.tr('section_language_subtitle')),
    );
    expect(
      (rootTitleRect.top + rootSubtitleRect.bottom) / 2,
      closeTo(tester.getRect(rootLanguageTile).center.dy, 0.5),
    );
    final rootCards = find.ancestor(
      of: rootLanguageTile,
      matching: find.byType(Card),
    );
    expect(rootCards, findsOneWidget);
    expect(tester.widget<ListTile>(rootLanguageTile).subtitle, isNull);

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
    final categoryHeaderWidget = tester.widget<TopPageHeader>(categoryHeader);
    expect(
      find.byKey(const ValueKey<String>('app_page_header_blur')),
      findsOneWidget,
    );
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
    expect(categoryHeaderRect.height, closeTo(rootHeaderRect.height, 0.001));
    expect(
      tester.getTopLeft(firstLanguageTile).dy - categoryHeaderRect.bottom,
      closeTo(rootFirstItemSpacing, 0.001),
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
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text(i18n.tr('section_common')));
    await tester.pumpAndSettle();
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
    expect(find.text(i18n.tr('haptic_feedback_enabled')), findsOneWidget);
    final portraitLockTile = find.widgetWithText(
      SwitchListTile,
      i18n.tr('portrait_lock'),
    );
    expect(tester.widget<SwitchListTile>(portraitLockTile).value, isFalse);
    await tester.tap(portraitLockTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(portraitLockTile).value, isTrue);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text(i18n.tr('section_playback')));
    await tester.pumpAndSettle();
    expect(
      find.text(i18n.tr('audio_device_disconnect_behavior')),
      findsOneWidget,
    );
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
    expect(aboutHeaderRect.height, closeTo(rootHeaderRect.height, 0.001));
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
      tester.getTopLeft(find.byWidget(firstAboutCard)).dy -
          aboutHeaderRect.bottom,
      closeTo(rootFirstItemSpacing, 0.001),
    );
  });

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
      expect(
        find.text(i18n.tr('asmr_download_folder_name_setting')),
        findsOneWidget,
      );
      expect(
        find.text(i18n.tr('asmr_download_folder_field_work_title')),
        findsOneWidget,
      );

      await tester.tap(find.text(i18n.tr('asmr_download_folder_name_setting')));
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
      Icons.admin_panel_settings_rounded,
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
    await tester.tap(find.text(i18n.tr('section_asmr_download')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.tr('asmr_download_folder_name_setting')));
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
    expect(
      rootCard.color,
      Theme.of(rootContext).colorScheme.surfaceContainerLow,
    );
    final rootBorderRadius =
        (rootCard.shape! as RoundedRectangleBorder).borderRadius
            as BorderRadius;
    expect(rootBorderRadius, BorderRadius.circular(6));
    final languageCard = find.ancestor(
      of: find.widgetWithText(ListTile, i18n.tr('section_language')),
      matching: find.byType(Card),
    );
    final commonCard = find.ancestor(of: rootTile, matching: find.byType(Card));
    expect(
      tester.getTopLeft(commonCard).dy - tester.getBottomLeft(languageCard).dy,
      closeTo(3, 0.001),
    );
    final firstCardShape =
        tester.widget<Card>(languageCard.first).shape!
            as RoundedRectangleBorder;
    final firstBorderRadius = firstCardShape.borderRadius as BorderRadius;
    expect(firstBorderRadius.topLeft, const Radius.circular(16));
    expect(firstBorderRadius.bottomLeft, const Radius.circular(6));
    final aboutCard = find.ancestor(
      of: find.widgetWithText(ListTile, i18n.tr('about')),
      matching: find.byType(Card),
    );
    final lastCardShape =
        tester.widget<Card>(aboutCard.first).shape! as RoundedRectangleBorder;
    final lastBorderRadius = lastCardShape.borderRadius as BorderRadius;
    expect(lastBorderRadius.topLeft, const Radius.circular(6));
    expect(lastBorderRadius.bottomLeft, const Radius.circular(16));

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
    expect(detailBorderRadius.topLeft, const Radius.circular(16));
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
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app_theme_color_tile')), findsOneWidget);
    expect(find.byKey(const ValueKey('asmr_theme_color_tile')), findsNothing);
    final appThemeColorTile = find.byKey(
      const ValueKey('app_theme_color_tile'),
    );
    final bottomNavigationTile = find.widgetWithText(
      SwitchListTile,
      i18n.tr('bottom_navigation_style'),
    );
    expect(tester.getSize(appThemeColorTile).height, 78);
    expect(tester.getSize(bottomNavigationTile).height, 78);
    final appThemeColorCard = find.ancestor(
      of: appThemeColorTile,
      matching: find.byType(Card),
    );
    final bottomNavigationCard = find.ancestor(
      of: bottomNavigationTile,
      matching: find.byType(Card),
    );
    expect(
      tester.getTopLeft(bottomNavigationCard).dy -
          tester.getBottomLeft(appThemeColorCard).dy,
      closeTo(3, 0.001),
    );

    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('asmr_theme_color_tile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('asmr_theme_color_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme_color_orange')));
    await tester.pumpAndSettle();
    expect(themeProvider.asmrThemeColor, ThemeAccentPreset.orange);
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

void _expectIconCentersAligned(WidgetTester tester, List<IconData> icons) {
  final expectedCenter = tester.getCenter(find.byIcon(icons.first)).dx;
  for (final icon in icons.skip(1)) {
    expect(
      tester.getCenter(find.byIcon(icon)).dx,
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
