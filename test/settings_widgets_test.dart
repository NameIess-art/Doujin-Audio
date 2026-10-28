import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/core/widgets/subtitle_window_visual.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_command_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:doujin_audio/features/settings/presentation/subtitle_window_settings_sheet.dart';
import 'package:doujin_audio/features/settings/presentation/asmr_download_folder_name_settings_sheet.dart';
import 'package:doujin_audio/features/data_support/application/storage_usage_service.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/settings/presentation/about_page.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/app/presentation/app_settings_group_card.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
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

  testWidgets(
    'download directory selection blocks row and duplicate commands',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final manager = _DeferredDestinationDownloadManager();
      addTearDown(fixture.dispose);
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        fixture.build(
          const SettingsTab(),
          overrides: [asmrDownloadManagerProvider.overrideWithValue(manager)],
        ),
      );
      await tester.pumpAndSettle();
      final i18n = fixture.languageProvider;
      await tester.tap(find.text(i18n.tr('section_asmr_download')));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text(i18n.tr('asmr_download_path_setting')),
        matching: find.byType(ListTile),
      );
      final choose = tester.widget<ListTile>(row).onTap!;
      choose();
      choose();
      expect(manager.pickCalls, 1);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ListTile>(row).onTap, isNull);
      expect(tester.widget<ListTile>(row).enabled, isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: row, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );
      manager.destination.complete(null);
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(row).onTap, isNotNull);
      expect(tester.widget<ListTile>(row).enabled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'cache clearing failure reports an error and allows retry',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          const SettingsTab(),
          overrides: [
            settingsCommandControllerProvider.overrideWithValue(
              SettingsCommandController(
                settings: fixture.settingsRepository,
                playback: fixture.playback,
                clearApplicationCacheFiles: () async =>
                    throw StateError('cache unavailable'),
              ),
            ),
            dataSupportStorageUsageServiceProvider.overrideWithValue(
              StorageUsageService(
                fileCacheGateway: _UnavailableStorageGateway(),
                libraryTracks: () => const [],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final i18n = fixture.languageProvider;
      await tester.tap(find.text(i18n.tr('section_data_storage')));
      await tester.pumpAndSettle();
      final clear = find.text(i18n.tr('clear_app_cache'));
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear.last);
      await tester.pumpAndSettle();
      expect(find.text(i18n.tr('operation_failed_retry')), findsOneWidget);
      expect(find.text(i18n.tr('retry')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        fixture.uiOperationService
            .operationFor(UiOperationScope.settingsCache)
            .hasError,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'settings display rows immediately without skeletons and retain category scroll',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.build(const SettingsTab()));
      final i18n = fixture.languageProvider;
      expect(find.byType(TopPageHeader), findsOneWidget);
      expect(find.text(i18n.tr('section_common')), findsOneWidget);
      expect(find.byType(OperationSkeletonList), findsNothing);
      await tester.pumpAndSettle();
      final homeController = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      await tester.tap(find.text(i18n.tr('section_common')));
      await tester.pump();
      expect(
        find.text(i18n.tr('interface_language'), skipOffstage: false),
        findsOneWidget,
      );
      await tester.pump();
      expect(find.text(i18n.tr('section_common')), findsWidgets);
      expect(find.text(i18n.tr('interface_language')), findsOneWidget);
      expect(find.byType(OperationSkeletonList), findsNothing);
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text(i18n.tr('interface_language')), findsOneWidget);
      expect(find.byType(OperationSkeletonList), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text(i18n.tr('interface_language')), findsOneWidget);
      final list = find.byType(ListView);
      final controller = tester.widget<ListView>(list).controller!;
      await tester.drag(list, const Offset(0, -180));
      await tester.pumpAndSettle();
      final offset = controller.offset;
      expect(offset, greaterThan(0));
      final context = tester.element(find.byType(TopPageHeader));
      final navigator = Navigator.of(context);
      unawaited(
        navigator.push(
          buildAppPageRoute<void>(
            context: context,
            child: const Scaffold(body: Text('Cover settings')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(controller),
      );
      expect(controller.offset, offset);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(homeController),
      );
      expect(find.text(i18n.tr('section_common')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Windows scrollbar starts below the page header',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.build(const SettingsTab()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      void expectTrackBelowHeader() {
        final headerBottom = tester
            .getBottomLeft(find.byType(TopPageHeader))
            .dy;
        final paints = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter is ScrollbarPainter,
        );
        expect(paints, findsWidgets);
        for (final element in paints.evaluate()) {
          final painter =
              (element.widget as CustomPaint).foregroundPainter!
                  as ScrollbarPainter;
          final top = tester.getTopLeft(find.byWidget(element.widget)).dy;
          expect(
            top + painter.padding.resolve(TextDirection.ltr).top,
            greaterThanOrEqualTo(headerBottom),
          );
        }
      }

      expectTrackBelowHeader();
      await tester.tap(
        find.text(fixture.languageProvider.tr('section_common')),
      );
      await tester.pumpAndSettle();
      expectTrackBelowHeader();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows hides Android permissions, cache and mobile settings',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pumpAndSettle();
      final i18n = harness.languageProvider;
      for (final entry in {
        'section_common': ['haptic_feedback_enabled'],
        'section_playback': [
          'audio_focus_strategy',
          'transient_audio_focus_loss_behavior',
        ],
        'section_data_storage': [
          'storage_usage_title',
          'settings_group_cache',
          'max_cache_size',
          'clear_app_cache',
        ],
        'section_updates_permissions': ['settings_group_permissions'],
      }.entries) {
        await tester.ensureVisible(find.text(i18n.tr(entry.key)));
        await tester.tap(find.text(i18n.tr(entry.key)));
        await tester.pumpAndSettle();
        for (final key in entry.value) {
          expect(find.text(i18n.tr(key)), findsNothing);
        }
        Navigator.of(tester.element(find.byType(TopPageHeader))).pop();
        await tester.pumpAndSettle();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

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
    expect(
      find.descendant(
        of: categoryHeader,
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
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
    expect(languageTileHeight, 64);
    final languageTileContext = tester.element(firstLanguageTile);
    final languageTileTheme = ListTileTheme.of(languageTileContext);
    expect(
      languageIcon.color,
      Theme.of(languageTileContext).colorScheme.primary,
    );
    expect(languageTileTheme.minTileHeight, 64);
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
    expect(tester.getSize(dlsiteLanguageTile).height, 64);
    expect(tester.getSize(asmrLanguageTile).height, 64);
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
    expect(find.byIcon(Icons.screen_lock_portrait_rounded), findsNothing);
    expect(find.text('允许添加相同作品'), findsNothing);
    expect(find.byIcon(Icons.copy_all_rounded), findsNothing);
    expect(find.text(i18n.tr('reduce_animations')), findsOneWidget);
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
    final backgroundRunTile = find.text(i18n.tr('allow_background_run'));
    expect(backgroundRunTile, findsOneWidget);
    expect(
      find.ancestor(of: backgroundRunTile, matching: find.byType(Card)),
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
    final firstAboutCard = tester
        .widgetList<Container>(
          find.ancestor(of: aboutTitle, matching: find.byType(Container)),
        )
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).borderRadius != null,
        );
    final aboutDecoration = firstAboutCard.decoration! as BoxDecoration;
    expect(
      aboutDecoration.color,
      Theme.of(tester.element(aboutTitle)).colorScheme.surfaceContainerLow,
    );
    expect(aboutDecoration.border, isNull);
    expect(
      tester.getTopLeft(find.byWidget(firstAboutCard)).dy,
      greaterThan(aboutHeaderRect.bottom),
    );
  });

  testWidgets(
    'settings category headers become sticky floating pills',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
        tester.getTopLeft(stickyPill).dy -
            tester.getRect(categoryHeader).bottom,
        closeTo(6.0, 0.5),
      );
      // When section is pinned, its inline pill is hidden to avoid duplicate pills on screen
      final inlineVisibility = tester.widget<Visibility>(
        find.ancestor(of: startupPill, matching: find.byType(Visibility)).first,
      );
      expect(inlineVisibility.visible, isFalse);

      final coverPill = find.byKey(
        const ValueKey<String>('settings_section_pill_appearance_1'),
      );
      final controller = tester.widget<ListView>(categoryList).controller!;
      final pinnedTop = tester.getTopLeft(stickyPill).dy;
      controller.jumpTo(
        controller.offset + tester.getTopLeft(coverPill).dy - pinnedTop - 20,
      );
      await tester.pumpAndSettle();
      final overlappingPill = find.byKey(
        const ValueKey<String>('settings_overlapping_section_pill'),
      );
      expect(overlappingPill, findsOneWidget);
      expect(
        tester.getTopLeft(overlappingPill).dy,
        closeTo(pinnedTop + 20, 0.5),
      );
      final contentColumn = find
          .descendant(of: categoryList, matching: find.byType(Column))
          .first;
      final content = tester.widget<Column>(contentColumn);
      for (final distance in [4.0, 6.0]) {
        final previousTop = tester.getTopLeft(overlappingPill).dy;
        controller.jumpTo(controller.offset + distance);
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(overlappingPill).dy,
          closeTo(previousTop - distance, 0.5),
        );
        expect(tester.widget<Column>(contentColumn), same(content));
      }

      controller.jumpTo(controller.offset + 20);
      await tester.pumpAndSettle();
      expect(overlappingPill, findsNothing);
      expect(
        find.descendant(
          of: stickyPill,
          matching: find.text(i18n.tr('settings_group_cover_background')),
        ),
        findsOneWidget,
      );

      controller.jumpTo(controller.offset - 20);
      await tester.pumpAndSettle();
      expect(overlappingPill, findsOneWidget);
      expect(
        tester.getTopLeft(overlappingPill).dy,
        closeTo(pinnedTop + 10, 0.5),
      );
      expect(
        find.descendant(
          of: stickyPill,
          matching: find.text(i18n.tr('settings_group_theme_layout')),
        ),
        findsOneWidget,
      );
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(stickyPill, findsNothing);
      expect(overlappingPill, findsNothing);
      expect(
        tester
            .widget<Visibility>(
              find
                  .ancestor(of: startupPill, matching: find.byType(Visibility))
                  .first,
            )
            .visible,
        isTrue,
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
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'data storage category places storage overview above embedded support actions',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        harness.build(
          const SettingsTab(),
          overrides: [
            dataSupportStorageUsageServiceProvider.overrideWithValue(
              StorageUsageService(
                fileCacheGateway: _UnavailableStorageGateway(),
                libraryTracks: () => const [],
              ),
            ),
          ],
        ),
      );
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
        matching: find.byType(UnifiedDropdownButton<int>),
      );
      final threadDropdown = find.descendant(
        of: threadTile,
        matching: find.byType(UnifiedDropdownButton<int>),
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
        findsNothing,
      );
      final headerIcon = find.byKey(
        const ValueKey('asmr_download_folder_name_header_icon'),
      );
      expect(headerIcon, findsOneWidget);
      expect(tester.widget<Icon>(headerIcon).size, 24);
      expect(
        tester.widget<Icon>(headerIcon).icon,
        Icons.drive_file_rename_outline,
      );
      expect(find.byType(CheckboxListTile), findsNWidgets(4));
      expect(find.byType(AppBottomSheetHeader), findsOneWidget);
      for (final tile in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(tile.controlAffinity, ListTileControlAffinity.leading);
        expect(tile.checkboxShape, isA<CircleBorder>());
        expect(tile.dense, isNull);
        expect(tile.visualDensity, const VisualDensity(vertical: -1));
      }
      final optionInkWells = tester.widgetList<InkWell>(
        find.descendant(
          of: find.byType(CheckboxListTile),
          matching: find.byType(InkWell),
        ),
      );
      expect(optionInkWells, hasLength(4));
      for (final ink in optionInkWells) {
        final shape = ink.customBorder! as RoundedRectangleBorder;
        final radius = shape.borderRadius.resolve(TextDirection.ltr);
        expect(radius.topLeft, radius.topRight);
        expect(radius.topLeft, radius.bottomLeft);
        expect(radius.topLeft, radius.bottomRight);
      }

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
      expect(find.text(i18n.tr('done')), findsNothing);
      expect(
        find.byKey(const ValueKey('asmr_download_folder_name_cancel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('asmr_download_folder_name_confirm')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('asmr_download_folder_name_confirm')),
      );
      await tester.pumpAndSettle();
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
      Icons.battery_saver_rounded,
      Icons.system_update_alt_rounded,
      Icons.update_rounded,
    ]);
  });

  testWidgets(
    'folder name drawer swipes closed without saving draft choices',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      final original = harness.settingsRepository.asmrDownloadFolderNameFields.toList();
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pumpAndSettle();
      final i18n = harness.languageProvider;
      await tester.tap(find.text(i18n.tr('section_asmr_download')));
      await tester.pumpAndSettle();
      final entry = find.text(i18n.tr('asmr_download_folder_name_setting'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      final rjCode = find.widgetWithText(
        CheckboxListTile,
        i18n.tr('asmr_download_folder_field_rj_code'),
      );
      await tester.tap(rjCode);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(rjCode).value, isTrue);
      final bounds = tester.getRect(find.byType(BottomSheet));
      await tester.dragFrom(
        Offset(bounds.center.dx, bounds.top + 24),
        Offset(0, bounds.height),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AsmrDownloadFolderNameSettingsSheet), findsNothing);
      expect(harness.settingsRepository.asmrDownloadFolderNameFields, original);
      expect(entry, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
    expect(
      tester.getTopLeft(find.widgetWithText(CheckboxListTile, rjCode)).dy,
      lessThan(
        tester.getTopLeft(find.widgetWithText(CheckboxListTile, workTitle)).dy,
      ),
      reason: 'The rendered order must update before persistence completes.',
    );

    await tester.tap(find.widgetWithText(CheckboxListTile, workTitle));
    await tester.pumpAndSettle();
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
    expect(settingsRepository.folderNameFieldUpdates, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('asmr_download_folder_name_confirm')),
    );
    await tester.pump();
    expect(settingsRepository.folderNameFieldUpdates.single, const [
      AsmrDownloadFolderNameField.rjCode,
    ]);
    settingsRepository._pendingPersistence.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ASMR folder name cancellation leaves repository state unchanged',
    (tester) async {
      final settingsRepository = _DeferredFolderNameSettingsRepository();
      final harness = AppRuntimeWidgetTestFixture(
        providedSettingsRepository: settingsRepository,
      );
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        harness.build(const AsmrDownloadFolderNameSettingsSheet()),
      );
      await tester.pumpAndSettle();

      final workTitle = harness.languageProvider.tr(
        'asmr_download_folder_field_work_title',
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, workTitle));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, workTitle),
            )
            .value,
        isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey('asmr_download_folder_name_cancel')),
      );
      await tester.pumpAndSettle();
      expect(settingsRepository.folderNameFieldUpdates, isEmpty);
      expect(settingsRepository.asmrDownloadFolderNameFields, const [
        AsmrDownloadFolderNameField.workTitle,
        AsmrDownloadFolderNameField.rjCode,
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings options have no fill or border and retain shaped ink',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pumpAndSettle();

      void expectMatchingInkCorners() {
        final settingsCards = find.byType(AppSettingsCard);
        expect(settingsCards, findsWidgets);
        for (final element in settingsCards.evaluate()) {
          final settingsCard = find.byWidget(element.widget);
          final card = tester.widget<Card>(
            find.descendant(of: settingsCard, matching: find.byType(Card)).first,
          );
          expect(card.color, Colors.transparent);
          expect(card.surfaceTintColor, Colors.transparent);
          expect((card.shape! as RoundedRectangleBorder).side, BorderSide.none);
          final tiles = find.descendant(
            of: settingsCard,
            matching: find.byType(ListTile),
          );
          for (final tileElement in tiles.evaluate()) {
            final ink = tester.widget<InkWell>(
              find.descendant(
                of: find.byWidget(tileElement.widget),
                matching: find.byType(InkWell),
              ).first,
            );
            expect(ink.customBorder, isA<RoundedRectangleBorder>());
            expect(
              (ink.customBorder! as RoundedRectangleBorder).borderRadius,
              (card.shape! as RoundedRectangleBorder).borderRadius,
              reason: 'The item highlight must follow its card corners.',
            );
          }
        }
      }

      expectMatchingInkCorners();
      final i18n = harness.languageProvider;
      for (final category in [
        'section_common',
        'section_appearance',
        'section_playback',
        'section_asmr_download',
        'section_data_storage',
        'section_network',
        'section_updates_permissions',
      ]) {
        final entry = find.text(i18n.tr(category));
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expectMatchingInkCorners();
        if (category == 'section_data_storage' &&
            Theme.of(tester.element(find.byType(TopPageHeader))).platform ==
                TargetPlatform.android) {
          final cardFinder = find.descendant(
            of: find.byKey(const ValueKey('data-support-storage-usage')),
            matching: find.byType(Card),
          );
          final card = tester.widget<Card>(cardFinder);
          final context = tester.element(cardFinder);
          expect(
            card.color,
            Theme.of(
              context,
            ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
          );
          final shape =
              (card.shape ?? CardTheme.of(context).shape)!
                  as RoundedRectangleBorder;
          expect(shape.side, BorderSide.none);
        }
        await tester.tap(find.byIcon(Icons.arrow_back_rounded));
        await tester.pumpAndSettle();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'settings option rows share 64 dp height and primary icons',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pumpAndSettle();
      await harness.settingsRepository.setAsmrDownloadDestinationRoot(
        r'E:\音频下载\Favorite audio library\很长的作品目录名称用于验证设置行保持一致高度',
      );
      await tester.pumpAndSettle();

      void expectRows() {
        for (final element in find.byType(ListTile).evaluate()) {
          final tile = element.widget as ListTile;
          final finder = find.byWidget(tile);
          // Storage usage is an information card, rather than an option row.
          if (find
              .ancestor(
                of: finder,
                matching: find.byKey(
                  const ValueKey('data-support-storage-usage'),
                ),
              )
              .evaluate()
              .isNotEmpty) {
            continue;
          }
          expect(
            tester.getSize(finder).height,
            64,
            reason: 'Settings row: ${tile.title}',
          );
          if (tile.leading == null) continue;
          for (final icon in tester.widgetList<Icon>(
            find.descendant(of: finder, matching: find.byType(Icon)),
          )) {
            // The setting identity icon is 30 dp; arrows and controls retain
            // their own state colors.
            if (icon.size == 30) {
              expect(icon.color, Theme.of(element).colorScheme.primary);
            }
          }
        }
      }

      expectRows();
      final i18n = harness.languageProvider;
      for (final category in [
        'section_common',
        'section_appearance',
        'section_playback',
        'section_asmr_download',
        'section_data_storage',
        'section_updates_permissions',
      ]) {
        final entry = find.text(i18n.tr(category));
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expectRows();
        await tester.tap(find.byIcon(Icons.arrow_back_rounded));
        await tester.pumpAndSettle();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('settings home uses transparent separated category rows', (
    tester,
  ) async {
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
    expect(rootIcon.color, Theme.of(rootContext).colorScheme.primary);
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
    expect(rootCard.color, Colors.transparent);
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
    expect(detailIcon.color, colorScheme.primary);
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
      Colors.transparent,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scaffold && widget.backgroundColor == colorScheme.surface,
      ),
      findsOneWidget,
    );
  });

  for (final finish in ['release', 'close', 'background']) {
    testWidgets(
      'subtitle slider previews immediately and saves on $finish',
      (tester) async {
        final harness = AppRuntimeWidgetTestFixture();
        addTearDown(harness.dispose);
        final visible = ValueNotifier(true);
        addTearDown(visible.dispose);
        await tester.pumpWidget(
          harness.build(
            ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => show
                  ? const SubtitleWindowSettingsSheet()
                  : const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SubtitleWindowSettingsSheet)),
          listen: false,
        );
        final notifier = container.read(subtitleSettingsProvider.notifier);
        final preferences = await SharedPreferences.getInstance();
        final slider = find.byType(Slider).first;
        final gesture = await tester.startGesture(tester.getCenter(slider));
        await gesture.moveBy(const Offset(100, 0));
        await tester.pump();
        final fontSize = container.read(subtitleSettingsProvider).fontSize;
        expect(fontSize, isNot(16));
        final preview = tester.widget<Text>(
          find.text(harness.languageProvider.tr('subtitle_preview_sample')),
        );
        expect(preview.style?.fontSize, fontSize);
        expect(preferences.getString('subtitle_font_size'), isNull);

        switch (finish) {
          case 'release':
            await gesture.up();
          case 'close':
            visible.value = false;
            await tester.pump();
            await gesture.up();
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            await tester.pump();
            await gesture.up();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
        }
        await notifier.flushAppearancePersistence();
        expect(
          preferences.getString('subtitle_font_size'),
          fontSize.toString(),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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
    expect(
      find.widgetWithText(
        AppBottomSheetHeader,
        i18n.tr('subtitle_window_settings'),
      ),
      findsOneWidget,
    );
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
    await tester.pumpAndSettle();

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

    final startupTileFinder = find.widgetWithText(
      ListTile,
      i18n.tr('startup_page'),
    );
    final startupTile = tester.widget<ListTile>(startupTileFinder);
    final title = startupTile.title! as Text;
    expect(title.softWrap, isTrue);
    expect(title.overflow, TextOverflow.visible);
    expect(tester.getSize(startupTileFinder).height, greaterThan(58));

    final dropdownFinder = find.byType(UnifiedDropdownButton<StartupPage>);
    final dropdown = tester.widget<UnifiedDropdownButton<StartupPage>>(
      dropdownFinder,
    );
    expect(dropdown.isExpanded, isTrue);
    expect(dropdown.multilineItems, isTrue);

    final optionText = dropdown.items.first.child as Text;
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
      matching: find.byType(UnifiedDropdownButton<AppLanguagePreference>),
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
            final tile = find.widgetWithText(ListTile, i18n.tr('startup_page'));
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
              final dropdown = find.byType(UnifiedDropdownButton<StartupPage>);
              await tester.tap(dropdown);
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason:
                    'open menu width=$width language=${language.name} '
                    'scale=$scale',
              );
              final playlistOption = find.text(
                i18n.tr('startup_page_playlist'),
              );
              expect(playlistOption, findsWidgets);
              await tester.tap(playlistOption.last);
              await tester.pumpAndSettle();
            }
          }
        }
      }
    },
  );

  testWidgets(
    'appearance omits the removed blur settings',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build(const SettingsTab()));
      await tester.pump();

      final i18n = harness.languageProvider;
      await tester.tap(find.text(i18n.tr('section_appearance')));
      await tester.pumpAndSettle();

      expect(find.text('界面毛玻璃'), findsNothing);
      expect(find.text('播放页模糊背景'), findsNothing);
      expect(find.text(i18n.tr('subtitle_window_settings')), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'appearance applies and persists the bar glass switch immediately',
    (tester) async {
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
      final toggle = find.byKey(const ValueKey('bar_glass_enabled_tile'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text(i18n.tr('bar_glass_enabled')), findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).subtitle, isNull);
      await Scrollable.ensureVisible(tester.element(toggle), alignment: 0.5);
      await tester.pumpAndSettle();

      await tester.tap(toggle);
      await tester.pump();
      expect(themeProvider.barGlassEnabled, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.text(i18n.tr('bar_glass_enabled')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        AppDesignTokens.of(tester.element(toggle)).barGlassEnabled,
        isTrue,
      );
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('barGlassEnabled'), isTrue);

      await tester.tap(toggle);
      await tester.pump();
      expect(themeProvider.barGlassEnabled, isFalse);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text(i18n.tr('bar_glass_enabled')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        AppDesignTokens.of(tester.element(toggle)).barGlassEnabled,
        isFalse,
      );
      expect(preferences.getBool('barGlassEnabled'), isFalse);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
    await tester.tap(find.byType(UnifiedDropdownButton<CoverImageResolution>));
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

  testWidgets('page display switches the local work name', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    await tester.tap(find.text(harness.languageProvider.tr('section_common')));
    await tester.pumpAndSettle();
    final title = find.text(harness.languageProvider.tr('work_name_display'));
    await Scrollable.ensureVisible(tester.element(title), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(harness.settings.workNameDisplay, WorkNameDisplay.workTitle);

    await tester.tap(find.byType(UnifiedDropdownButton<WorkNameDisplay>));
    await tester.pumpAndSettle();
    expect(
      find.text(harness.languageProvider.tr('work_name_display_folderName')),
      findsOneWidget,
    );
    await tester.tap(
      find.text(harness.languageProvider.tr('work_name_display_folderName')),
    );
    await tester.pumpAndSettle();
    expect(harness.settings.workNameDisplay, WorkNameDisplay.folderName);
  });

  testWidgets(
    'appearance omits the cover display mode setting',
    (tester) async {
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
      expect(
        find.byType(UnifiedDropdownButton<CoverImageResolution>),
        findsOneWidget,
      );
      expect(find.text('封面图片显示'), findsNothing);
      expect(find.byIcon(Icons.aspect_ratio_rounded), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('appearance toggles own cover preference', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_appearance')));
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('prefer_embedded_cover_switch'),
    );
    await Scrollable.ensureVisible(tester.element(toggle), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(harness.settingsRepository.preferEmbeddedCover, isFalse);
    final initialCoverGeneration =
        harness.runtimeGraph.library.coverArtworkCacheService.generation;

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(harness.settingsRepository.preferEmbeddedCover, isTrue);
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
    expect(tester.getSize(appThemeColorTile).height, 64);

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

  testWidgets('playback settings omit the multi-thread toggle', (tester) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();
    final i18n = harness.languageProvider;
    await tester.tap(find.text(i18n.tr('section_playback')));
    await tester.pumpAndSettle();

    expect(find.text('多线程播放'), findsNothing);
  });

  testWidgets('playback setting reports a rejected save', (tester) async {
    final harness = AppRuntimeWidgetTestFixture(
      providedSettingsRepository: _RejectedSettingsRepository(),
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();
    await tester.tap(
      find.text(harness.languageProvider.tr('section_playback')),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(
      const ValueKey<String>('allow_video_playback_switch'),
    );
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<SwitchListTile>(toggle).value, true);
    expect(
      find.textContaining(
        harness.languageProvider.tr('operation_failed_retry'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'folder naming saves once and finishes safely after swipe dismissal',
    (tester) async {
      final repository = _DeferredFolderNameSettingsRepository();
      final fixture = AppRuntimeWidgetTestFixture(
        providedSettingsRepository: repository,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(const SettingsTab()),
      );
      await tester.pumpAndSettle();
      final i18n = fixture.languageProvider;
      await tester.tap(find.text(i18n.tr('section_asmr_download')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(i18n.tr('asmr_download_folder_name_setting')));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(tester.widget<BottomSheet>(sheet).enableDrag, isTrue);
      expect(tester.widget<BottomSheet>(sheet).showDragHandle, isTrue);
      final sheetBounds = tester.getRect(sheet);
      final confirm = find.byKey(
        const ValueKey('asmr_download_folder_name_confirm'),
      );
      final save = tester.widget<TextButton>(confirm).onPressed!;
      save();
      save();
      await tester.pump();
      expect(repository.folderNameFieldUpdates, hasLength(1));
      expect(tester.widget<TextButton>(confirm).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('asmr_download_folder_name_cancel')),
            )
            .onPressed,
        isNull,
      );
      await tester.dragFrom(
        Offset(sheetBounds.center.dx, sheetBounds.top + 24),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      expect(confirm, findsNothing);
      repository._pendingPersistence.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AsmrDownloadFolderNameSettingsSheet), findsNothing);
      expect(find.text(i18n.tr('asmr_download_folder_name_setting')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder name selection restores repository state after save failure',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture(
        providedSettingsRepository: _RejectedSettingsRepository(),
      );
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        harness.build(const AsmrDownloadFolderNameSettingsSheet()),
      );
      await tester.pumpAndSettle();
      final workTitle = find.widgetWithText(
        CheckboxListTile,
        harness.languageProvider.tr('asmr_download_folder_field_work_title'),
      );
      expect(tester.widget<CheckboxListTile>(workTitle).value, true);
      await tester.tap(workTitle);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(workTitle).value, false);

      await tester.tap(
        find.byKey(const ValueKey('asmr_download_folder_name_confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<CheckboxListTile>(workTitle).value, true);
      expect(
        find.textContaining(
          harness.languageProvider.tr('operation_failed_retry'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

class _DeferredDestinationDownloadManager extends AsmrDownloadManager {
  _DeferredDestinationDownloadManager() : super(persistTasks: false);

  final destination = Completer<String?>();
  var pickCalls = 0;

  @override
  Future<String?> pickDestinationFolder({String? dialogTitle}) {
    pickCalls++;
    return destination.future;
  }
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

class _UnavailableStorageGateway extends FileCachePlatformGateway {
  @override
  Future<StorageUsagePlatformSnapshot?> readStorageUsage() async => null;
}

final class _RejectedSettingsRepository extends SettingsRepository {
  _RejectedSettingsRepository() {
    asmrDownloadFolderNameFields = const [
      AsmrDownloadFolderNameField.workTitle,
      AsmrDownloadFolderNameField.rjCode,
    ];
    syncSlice(isInitialized: true);
  }

  @override
  Future<void> setAllowVideoPlayback(bool value) async {
    throw StateError('save rejected');
  }

  @override
  Future<void> setAsmrDownloadFolderNameFields(
    Iterable<AsmrDownloadFolderNameField> fields,
  ) async {
    throw StateError('save rejected');
  }
}
