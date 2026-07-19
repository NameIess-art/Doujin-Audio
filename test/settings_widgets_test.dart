import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/app_language.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
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
    expect(
      find.text(i18n.tr('haptic_feedback_enabled')),
      Platform.isWindows ? findsNothing : findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text(i18n.tr('section_playback')));
    await tester.pumpAndSettle();
    expect(
      find.text(i18n.tr('audio_device_disconnect_behavior')),
      Platform.isAndroid ? findsOneWidget : findsNothing,
    );
    expect(
      find.text(i18n.tr('transient_audio_focus_loss_behavior')),
      Platform.isAndroid ? findsOneWidget : findsNothing,
    );
    expect(
      find.text(i18n.tr('interruption_resume_behavior')),
      Platform.isAndroid ? findsOneWidget : findsNothing,
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

  testWidgets('settings pages use monochrome icons and a light surface', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(const SettingsTab()));
    await tester.pump();

    final i18n = harness.languageProvider;
    final rootTile = find.widgetWithText(ListTile, i18n.tr('section_common'));
    final rootContext = tester.element(rootTile);
    final rootIcon = tester.widget<ListTile>(rootTile).leading! as Icon;
    expect(rootIcon.color, Theme.of(rootContext).colorScheme.onSurface);
    final rootSurface = tester
        .widgetList<Container>(
          find.ancestor(of: rootTile, matching: find.byType(Container)),
        )
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).color ==
                  Theme.of(rootContext).colorScheme.surfaceContainerLow,
        );
    expect(
      (rootSurface.decoration! as BoxDecoration).border,
      isNull,
      reason: 'Settings root items should not paint a card outline.',
    );

    await tester.tap(rootTile);
    await tester.pumpAndSettle();

    final detailTile = find.widgetWithText(ListTile, i18n.tr('startup_page'));
    final detailContext = tester.element(detailTile);
    final detailIcon = tester.widget<ListTile>(detailTile).leading! as Icon;
    final colorScheme = Theme.of(detailContext).colorScheme;
    expect(detailIcon.color, colorScheme.onSurface);
    final detailSurface = tester
        .widgetList<Container>(
          find.ancestor(of: detailTile, matching: find.byType(Container)),
        )
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).color ==
                  colorScheme.surfaceContainerLow,
        );
    expect(
      (detailSurface.decoration! as BoxDecoration).border,
      isNull,
      reason: 'Settings secondary-page items should remain borderless.',
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scaffold && widget.backgroundColor == colorScheme.surface,
      ),
      findsOneWidget,
    );
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
    await tester.pumpAndSettle();

    final viewportBottom = tester.getBottomLeft(find.byType(Scaffold).first).dy;
    final lastTileBottom = tester.getBottomLeft(aboutTile).dy;
    expect(viewportBottom - lastTileBottom, closeTo(overlayInset + 8, 1));
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
