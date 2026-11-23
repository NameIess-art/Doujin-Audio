import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_audio_features.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/core/widgets/app_buttons.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'changing a digit preserves the position of adjacent text',
    (tester) async {
      await tester.runAsync(() async {
        final font = FontLoader('Outfit')
          ..addFont(rootBundle.load('assets/fonts/Outfit-Variable.ttf'));
        await font.load();
      });
      final provider = ThemeProvider(loadPersistedState: false);
      addTearDown(provider.dispose);

      const valueKey = ValueKey('changing_value');
      const unitKey = ValueKey('fixed_unit');
      double? previousUnitPosition;
      for (var digit = 0; digit <= 9; digit++) {
        await tester.pumpWidget(
          MaterialApp(
            theme: provider.lightTheme,
            home: Scaffold(
              body: Row(
                children: [
                  Text(
                    '01:0$digit',
                    key: valueKey,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text(' min', key: unitKey),
                ],
              ),
            ),
          ),
        );

        expect(
          DefaultTextStyle.of(
            tester.element(find.byKey(valueKey)),
          ).style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
        final unitPosition = tester.getTopLeft(find.byKey(unitKey)).dx;
        previousUnitPosition ??= unitPosition;
        expect(unitPosition, closeTo(previousUnitPosition, 0.001));
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'typography uses tabular digits and platform sizes across themes and locales',
    (tester) async {
      final platform = defaultTargetPlatform;
      final provider = ThemeProvider(loadPersistedState: false);
      addTearDown(provider.dispose);
      final isWindows = platform == TargetPlatform.windows;
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        for (final locale in const [Locale('zh'), Locale('ja'), Locale('en')]) {
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              supportedLocales: const [
                Locale('zh'),
                Locale('ja'),
                Locale('en'),
              ],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: provider.lightTheme,
              darkTheme: provider.darkTheme,
              themeMode: mode,
              home: const Scaffold(body: Text('音声・播放 / Playback 01:23')),
            ),
          );
          await tester.pumpAndSettle();

          final sample = find.byType(Text);
          final context = tester.element(sample);
          final theme = Theme.of(context).textTheme;
          expect(Localizations.localeOf(context), locale);
          expect(theme.bodyMedium!.fontFamily, 'Outfit');
          expect(theme.titleLarge!.fontFamily, 'Outfit');
          expect(theme.labelSmall!.fontSize, isWindows ? 12 : 10);
          expect(
            theme.displayLarge!.fontFeatures,
            contains(const FontFeature.tabularFigures()),
          );
          expect(
            Theme.of(context).primaryTextTheme.bodyMedium!.fontFeatures,
            contains(const FontFeature.tabularFigures()),
          );
          expect(
            theme.titleMedium!.fontWeight,
            isWindows ? FontWeight.w600 : FontWeight.w700,
          );
          expect(
            DefaultTextStyle.of(context).style.fontFamily,
            theme.bodyMedium!.fontFamily,
          );
        }
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final featureRow in [false, true]) {
      testWidgets(
        '$platform ${featureRow ? 'feature' : 'settings'} switch uses row hover',
        (tester) async {
          final provider = ThemeProvider(loadPersistedState: false);
          addTearDown(provider.dispose);
          var value = false;
          var changes = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: provider.darkTheme.copyWith(platform: platform),
              home: Scaffold(
                body: Center(
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      void onChanged(bool next) => setState(() {
                        value = next;
                        changes++;
                      });
                      return featureRow
                          ? FeatureSwitchTile(
                              title: 'Noise reduction',
                              subtitle: 'Reduce background noise',
                              icon: Icons.graphic_eq,
                              value: value,
                              onChanged: onChanged,
                            )
                          : SwitchListTile(
                              title: const Text('Noise reduction'),
                              value: value,
                              onChanged: onChanged,
                            );
                    },
                  ),
                ),
              ),
            ),
          );
          final toggle = find.byType(Switch);
          final overlay = SwitchTheme.of(tester.element(toggle)).overlayColor!;
          expect(overlay.resolve({WidgetState.hovered}), Colors.transparent);
          expect(overlay.resolve({WidgetState.focused}), isNull);
          expect(overlay.resolve({WidgetState.pressed}), Colors.transparent);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(toggle));
          await tester.pumpAndSettle();
          final dynamic controller = Material.of(
            tester.element(find.byType(InkWell)),
          );
          final highlights = (controller.debugInkFeatures as List<InkFeature>)
              .whereType<InkHighlight>()
              .where((feature) => feature.color.a > 0);
          expect(highlights, isNotEmpty);
          expect(
            tester.widget<InkWell>(find.byType(InkWell)).highlightShape,
            BoxShape.rectangle,
          );
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(value, isTrue);
          expect(changes, 1);
          await tester.tap(find.text('Noise reduction'));
          await tester.pumpAndSettle();
          expect(value, isFalse);
          expect(changes, 2);
          await mouse.removePointer();
        },
      );
    }
  }

  test(
    'theme flush captures submitted writes without waiting for later ones',
    () async {
      final firstGate = Completer<bool>();
      final laterGate = Completer<bool>();
      final provider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (key, value) =>
            key == 'themeMode' ? firstGate.future : laterGate.future,
      );
      addTearDown(provider.dispose);
      final first = provider.setThemeMode(ThemeMode.dark);
      final flushing = provider.flushPendingWrites();
      final later = provider.setPureBlackTheme(true);
      firstGate.complete(true);
      await flushing;
      expect(await first, isTrue);
      laterGate.complete(true);
      expect(await later, isTrue);
    },
  );

  test(
    'theme flush preserves failed saves while later writes recover',
    () async {
      final gate = Completer<bool>();
      final provider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (key, value) =>
            key == 'themeMode' ? gate.future : Future.value(true),
      );
      addTearDown(provider.dispose);
      final failed = provider.setThemeMode(ThemeMode.dark);
      final succeeding = provider.setPureBlackTheme(true);
      final flushing = expectLater(
        provider.flushPendingWrites(),
        throwsStateError,
      );
      gate.complete(false);
      expect(await failed, isFalse);
      expect(await succeeding, isTrue);
      await flushing;
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.pureBlackTheme, isTrue);
      await provider.flushPendingWrites();
    },
  );

  test('defaults to system theme', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();

    final provider = ThemeProvider();
    expect(provider.themeMode, ThemeMode.system);
    expect(provider.appThemeColor, ThemeAccentPreset.rose);
    expect(provider.pureBlackTheme, isFalse);
    expect(provider.barGlassEnabled, isFalse);
    expect(
      provider.lightTheme.extension<AppDesignTokens>()!.barGlassEnabled,
      isFalse,
    );
    expect(
      provider.darkTheme.extension<AppDesignTokens>()!.barGlassEnabled,
      isFalse,
    );
    expect(ThemeAccentPreset.values, hasLength(16));
  });

  test(
    'bootstrap defaults load persisted theme only on initialization',
    () async {
      SharedPreferences.setMockInitialValues({
        'themeMode': 'dark',
        'appThemeColor': 'teal',
        'pureBlackTheme': true,
        'barGlassEnabled': true,
      });
      await AppPreferences.init();
      final provider = ThemeProvider(loadPersistedState: false);
      addTearDown(provider.dispose);
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.appThemeColor, ThemeAccentPreset.rose);
      expect(provider.pureBlackTheme, false);
      expect(provider.barGlassEnabled, false);
      await provider.reloadPersistedState();
      expect(provider.themeMode, ThemeMode.dark);
      expect(provider.appThemeColor, ThemeAccentPreset.teal);
      expect(provider.pureBlackTheme, true);
      expect(provider.barGlassEnabled, true);
    },
  );

  testWidgets('touch long press does not show icon tooltips', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final theme = ThemeProvider().lightTheme;

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Row(
            children: [
              IconButton(
                tooltip: 'Search',
                onPressed: () {},
                icon: const Icon(Icons.search),
              ),
              Tooltip(
                message: 'More',
                child: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    await tester.longPress(find.byIcon(Icons.search));
    await tester.pump();
    expect(find.text('Search'), findsNothing);
    await tester.longPress(find.byIcon(Icons.more_horiz));
    await tester.pump();
    expect(find.text('More'), findsNothing);
  });

  test('theme presets cover core hues, monochrome black/white, and readable palettes', () {
    expect(ThemeAccentPreset.values, const <ThemeAccentPreset>[
      ThemeAccentPreset.red,
      ThemeAccentPreset.rose,
      ThemeAccentPreset.pink,
      ThemeAccentPreset.purple,
      ThemeAccentPreset.indigo,
      ThemeAccentPreset.blue,
      ThemeAccentPreset.sky,
      ThemeAccentPreset.cyan,
      ThemeAccentPreset.teal,
      ThemeAccentPreset.green,
      ThemeAccentPreset.olive,
      ThemeAccentPreset.yellow,
      ThemeAccentPreset.orange,
      ThemeAccentPreset.brown,
      ThemeAccentPreset.gray,
      ThemeAccentPreset.monochrome,
    ]);
    for (final preset in ThemeAccentPreset.values) {
      final lightScheme = preset.colorScheme(Brightness.light);
      final darkScheme = preset.colorScheme(Brightness.dark);
      expect(
        _contrastRatio(lightScheme.onPrimary, lightScheme.primary),
        greaterThan(4.5),
        reason: '${preset.name} light onPrimary contrast',
      );
      expect(
        _contrastRatio(darkScheme.onPrimary, darkScheme.primary),
        greaterThan(4.5),
        reason: '${preset.name} dark onPrimary contrast',
      );
      expect(
        lightScheme.surface,
        preset.bootstrapSurfaceColor(Brightness.light),
      );
      expect(
        lightScheme.surfaceContainerLowest.computeLuminance(),
        greaterThanOrEqualTo(lightScheme.surfaceContainerLow.computeLuminance()),
      );
      expect(
        lightScheme.surfaceContainerLow.computeLuminance(),
        greaterThan(lightScheme.surfaceContainer.computeLuminance()),
      );
      expect(
        lightScheme.surfaceContainer.computeLuminance(),
        greaterThan(lightScheme.surfaceContainerHigh.computeLuminance()),
      );
      expect(
        darkScheme.surfaceContainerLow.computeLuminance(),
        lessThan(darkScheme.surfaceContainer.computeLuminance()),
      );
      expect(
        darkScheme.surfaceContainer.computeLuminance(),
        lessThan(darkScheme.surfaceContainerHigh.computeLuminance()),
      );
      expect(
        darkScheme.surfaceContainerHigh.computeLuminance(),
        lessThan(darkScheme.surfaceContainerHighest.computeLuminance()),
      );
      if (preset == ThemeAccentPreset.gray) {
        expect(lightScheme.primary, const Color(0xFF5A6068));
        expect(darkScheme.primary, preset.primaryColor);
        continue;
      }
      if (preset == ThemeAccentPreset.monochrome) {
        expect(lightScheme.primary, const Color(0xFF141417));
        expect(lightScheme.onPrimary, const Color(0xFFFFFFFF));
        expect(darkScheme.primary, const Color(0xFFF5F5F7));
        expect(darkScheme.onPrimary, const Color(0xFF111114));
        expect(
          preset.colorScheme(Brightness.light, highContrast: true).primary,
          const Color(0xFF000000),
        );
        expect(
          preset.colorScheme(Brightness.dark, highContrast: true).primary,
          const Color(0xFFFFFFFF),
        );
        continue;
      }
      final generatedLightScheme = ColorScheme.fromSeed(
        seedColor: preset.lightSeedColor,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      expect(lightScheme.primary, generatedLightScheme.primary);
      expect(lightScheme.primary, isNot(preset.primaryColor));
      expect(darkScheme.primary, preset.primaryColor);
    }
  });

  test('legacy persisted preset names migrate cleanly to new presets', () async {
    for (final (legacyName, expected) in const [
      ('coral', ThemeAccentPreset.red),
      ('lavender', ThemeAccentPreset.purple),
      ('periwinkle', ThemeAccentPreset.indigo),
      ('mint', ThemeAccentPreset.teal),
      ('lightGreen', ThemeAccentPreset.green),
      ('lime', ThemeAccentPreset.olive),
      ('amber', ThemeAccentPreset.yellow),
      ('peach', ThemeAccentPreset.brown),
    ]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'appThemeColor': legacyName,
      });
      await AppPreferences.init();
      expect(ThemeProvider.readAppThemeColorSync(), expected);
    }
  });

  test('loads and saves the current theme mode preference', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'themeMode': 'dark',
    });
    await AppPreferences.init();
    final provider = ThemeProvider();

    expect(provider.themeMode, ThemeMode.dark);

    await provider.setThemeMode(ThemeMode.light);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('themeMode'), 'light');
  });

  test('loads and saves pure black theme preference', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'pureBlackTheme': true,
    });
    await AppPreferences.init();
    final provider = ThemeProvider();

    expect(provider.pureBlackTheme, isTrue);

    await provider.setPureBlackTheme(false);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('pureBlackTheme'), isFalse);
  });

  test('bar glass preference persists and updates both theme modes', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();
    addTearDown(provider.dispose);

    expect(await provider.setBarGlassEnabled(true), isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('barGlassEnabled'), isTrue);
    final restored = ThemeProvider();
    addTearDown(restored.dispose);
    expect(restored.barGlassEnabled, isTrue);
    for (final theme in [restored.lightTheme, restored.darkTheme]) {
      final tokens = theme.extension<AppDesignTokens>()!;
      expect(tokens.barGlassEnabled, isTrue);
      expect(tokens.copyWith(success: Colors.red).barGlassEnabled, isTrue);
      final disabled = tokens.copyWith(barGlassEnabled: false);
      expect(tokens.lerp(disabled, 0).barGlassEnabled, isFalse);
      expect(disabled.lerp(tokens, 0).barGlassEnabled, isTrue);
    }

    expect(await provider.setBarGlassEnabled(false), isTrue);
    expect(preferences.getBool('barGlassEnabled'), isFalse);
    await restored.reloadPersistedState();
    expect(restored.barGlassEnabled, isFalse);
    expect(
      restored.lightTheme.extension<AppDesignTokens>()!.barGlassEnabled,
      isFalse,
    );
    expect(
      restored.darkTheme.extension<AppDesignTokens>()!.barGlassEnabled,
      isFalse,
    );
  });

  test(
    'an older failed bar glass write keeps the latest optimistic value',
    () async {
      final writes = <Completer<bool>>[];
      final provider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (_, _) {
          final write = Completer<bool>();
          writes.add(write);
          return write.future;
        },
      );
      addTearDown(provider.dispose);
      final first = provider.setBarGlassEnabled(true);
      final second = provider.setBarGlassEnabled(false);
      final latest = provider.setBarGlassEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(writes, hasLength(1));
      writes.first.complete(false);
      expect(await first, isFalse);
      expect(provider.barGlassEnabled, isTrue);
      await Future<void>.delayed(Duration.zero);
      writes[1].complete(false);
      expect(await second, isFalse);
      expect(provider.barGlassEnabled, isTrue);
      await Future<void>.delayed(Duration.zero);
      writes.last.complete(true);
      expect(await latest, isTrue);
      expect(
        provider.lightTheme.extension<AppDesignTokens>()!.barGlassEnabled,
        isTrue,
      );
    },
  );

  test(
    'failed preference writes roll back all optimistic theme changes',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final provider = ThemeProvider(preferenceWriter: (_, _) async => false);

      expect(await provider.setThemeMode(ThemeMode.dark), isFalse);
      expect(provider.themeMode, ThemeMode.system);

      expect(await provider.setAppThemeColor(ThemeAccentPreset.teal), isFalse);
      expect(provider.appThemeColor, ThemeAccentPreset.rose);

      expect(await provider.setPureBlackTheme(true), isFalse);
      expect(provider.pureBlackTheme, isFalse);

      expect(await provider.setBarGlassEnabled(true), isFalse);
      expect(provider.barGlassEnabled, isFalse);
      expect(
        provider.lightTheme.extension<AppDesignTokens>()!.barGlassEnabled,
        isFalse,
      );
    },
  );

  test(
    'an older failed theme write does not replace a newer success',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final writes = <Completer<bool>>[];
      final provider = ThemeProvider(
        preferenceWriter: (_, _) {
          final write = Completer<bool>();
          writes.add(write);
          return write.future;
        },
      );
      final older = provider.setThemeMode(ThemeMode.dark);
      final newer = provider.setThemeMode(ThemeMode.light);

      expect(provider.themeMode, ThemeMode.light);
      await Future<void>.delayed(Duration.zero);
      expect(writes, hasLength(1));
      writes.first.complete(false);
      expect(await older, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(provider.themeMode, ThemeMode.light);
      expect(writes, hasLength(2));

      writes.last.complete(true);
      expect(await newer, isTrue);
      expect(provider.themeMode, ThemeMode.light);
    },
  );

  test('light and dark themes expose the shared design tokens', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    final lightTokens = provider.lightTheme.extension<AppDesignTokens>()!;
    final darkTokens = provider.darkTheme.extension<AppDesignTokens>()!;

    expect(lightTokens, isNotNull);
    expect(darkTokens, isNotNull);
    expect(
      <double>[
        lightTokens.radiusSmall,
        lightTokens.radiusControl,
        lightTokens.radiusCard,
        lightTokens.radiusSection,
        lightTokens.radiusOverlay,
      ],
      <double>[8, 10, 12, 16, 20],
    );
    expect(lightTokens.radiusCard, darkTokens.radiusCard);
    expect(lightTokens.spaceXxs, 4);
    expect(lightTokens.spaceXxl, 32);
    expect(lightTokens.minimumTapTarget, 48);
    expect(lightTokens.success, isNot(darkTokens.success));
    expect(lightTokens.warning, isNot(darkTokens.warning));
    expect(lightTokens.folderColor, isNot(darkTokens.folderColor));
    expect(lightTokens.textFileColor, isNot(darkTokens.textFileColor));
    expect(lightTokens.imageFileColor, isNot(darkTokens.imageFileColor));
  });

  test('shared legacy radii use the compact corner scale', () {
    expect(
      <double>[
        AppRadius.small,
        AppRadius.medium,
        AppRadius.card,
        AppRadius.section,
        AppRadius.dialog,
      ],
      <double>[6, 10, 12, 16, 20],
    );
  });

  test('loads and saves the app theme color', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'appThemeColor': 'teal',
    });
    await AppPreferences.init();
    final provider = ThemeProvider();

    expect(provider.appThemeColor, ThemeAccentPreset.teal);

    await provider.setAppThemeColor(ThemeAccentPreset.purple);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appThemeColor'), 'purple');
  });

  test('selected app color updates both brightness theme schemes', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();
    final previousLightPrimary = provider.lightTheme.colorScheme.primary;
    final previousDarkPrimary = provider.darkTheme.colorScheme.primary;

    await provider.setAppThemeColor(ThemeAccentPreset.teal);

    final expectedLight = ThemeAccentPreset.teal.colorScheme(Brightness.light);
    final expectedDark = ThemeAccentPreset.teal.colorScheme(Brightness.dark);
    expect(provider.lightTheme.colorScheme.primary, expectedLight.primary);
    expect(provider.darkTheme.colorScheme.primary, expectedDark.primary);
    expect(provider.lightTheme.colorScheme.secondary, expectedLight.secondary);
    expect(provider.lightTheme.colorScheme.tertiary, expectedLight.tertiary);
    expect(
      provider.lightTheme.colorScheme.surfaceContainer,
      expectedLight.surfaceContainer,
    );
    expect(
      provider.lightTheme.colorScheme.primary,
      isNot(previousLightPrimary),
    );
    expect(provider.darkTheme.colorScheme.primary, isNot(previousDarkPrimary));
  });

  test(
    'selected app color updates page surfaces in both appearance modes',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final provider = ThemeProvider();

      await provider.setAppThemeColor(ThemeAccentPreset.teal);

      expect(
        provider.lightTheme.colorScheme.surface,
        ThemeAccentPreset.teal.bootstrapSurfaceColor(Brightness.light),
      );
      expect(
        provider.darkTheme.colorScheme.surface,
        ThemeAccentPreset.teal.bootstrapSurfaceColor(Brightness.dark),
      );
      expect(
        provider.lightTheme.scaffoldBackgroundColor,
        ThemeAccentPreset.teal.bootstrapSurfaceColor(Brightness.light),
      );
      expect(
        provider.darkTheme.scaffoldBackgroundColor,
        ThemeAccentPreset.teal.bootstrapSurfaceColor(Brightness.dark),
      );
    },
  );

  test(
    'pure black theme sets dark background and surfaces to pure black while keeping accents',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final provider = ThemeProvider();

      await provider.setAppThemeColor(ThemeAccentPreset.blue);
      await provider.setPureBlackTheme(true);

      // Dark theme background is pure black
      expect(
        provider.darkTheme.scaffoldBackgroundColor,
        const Color(0xFF000000),
      );
      expect(provider.darkTheme.colorScheme.surface, const Color(0xFF000000));
      expect(
        provider.darkTheme.colorScheme.surfaceDim,
        const Color(0xFF000000),
      );

      // Primary accent and text remain consistent
      expect(
        provider.darkTheme.colorScheme.primary,
        ThemeAccentPreset.blue.primaryColor,
      );
      expect(
        _contrastRatio(
          provider.darkTheme.colorScheme.onSurface,
          const Color(0xFF000000),
        ),
        greaterThan(4.5),
      );

      // Light theme remains unchanged (not pure black)
      expect(
        provider.lightTheme.scaffoldBackgroundColor,
        isNot(const Color(0xFF000000)),
      );
      expect(
        provider.lightTheme.colorScheme.surface,
        isNot(const Color(0xFF000000)),
      );
    },
  );

  test('cards and overlays use rounded shapes without outlines', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final theme = ThemeProvider().darkTheme;
    final tokens = theme.extension<AppDesignTokens>()!;

    final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
    final dialogShape = theme.dialogTheme.shape! as RoundedRectangleBorder;
    final sheetShape = theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
    final menuShape = theme.popupMenuTheme.shape! as RoundedRectangleBorder;

    for (final shape in [cardShape, dialogShape, sheetShape, menuShape]) {
      expect(shape.side, BorderSide.none);
    }
    expect(cardShape.borderRadius, BorderRadius.circular(tokens.radiusCard));
    expect(
      dialogShape.borderRadius,
      BorderRadius.circular(tokens.radiusOverlay),
    );
    expect(
      sheetShape.borderRadius,
      BorderRadius.vertical(top: Radius.circular(tokens.radiusOverlay)),
    );
    expect(menuShape.borderRadius, BorderRadius.circular(tokens.radiusCard));
    expect(theme.scrollbarTheme.radius, const Radius.circular(AppRadius.small));
  });

  test('interactive component themes keep the minimum tap target', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final theme = ThemeProvider().lightTheme;
    final tokens = theme.extension<AppDesignTokens>()!;

    expect(
      theme.iconButtonTheme.style?.minimumSize?.resolve(<WidgetState>{}),
      Size.square(tokens.minimumTapTarget),
    );
    expect(
      theme.textButtonTheme.style?.minimumSize?.resolve(<WidgetState>{}),
      Size.square(tokens.minimumTapTarget),
    );
    expect(
      theme.inputDecorationTheme.constraints?.minHeight,
      tokens.minimumTapTarget,
    );
    expect(
      theme.filledButtonTheme.style?.shape?.resolve(const <WidgetState>{}),
      isA<StadiumBorder>(),
    );
    expect(
      theme.outlinedButtonTheme.style?.shape?.resolve(const <WidgetState>{}),
      isA<StadiumBorder>(),
    );
    expect(
      theme.textButtonTheme.style?.shape?.resolve(const <WidgetState>{}),
      isA<StadiumBorder>(),
    );
  });

  test('light and dark text colors keep readable visual hierarchy', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    for (final theme in <ThemeData>[provider.lightTheme, provider.darkTheme]) {
      final scheme = theme.colorScheme;
      final textTheme = theme.textTheme;
      final titleColor = textTheme.titleMedium!.color!;
      final bodyColor = textTheme.bodyMedium!.color!;
      final supportingColor = textTheme.bodySmall!.color!;

      expect(titleColor, scheme.onSurface);
      expect(bodyColor, isNot(titleColor));
      expect(supportingColor, scheme.onSurfaceVariant);
      expect(supportingColor, isNot(bodyColor));
      expect(titleColor, isNot(Colors.black));
      expect(titleColor, isNot(Colors.white));
      expect(
        _contrastRatio(scheme.onPrimary, scheme.primary),
        greaterThan(4.5),
      );
      expect(_contrastRatio(titleColor, scheme.surface), greaterThan(4.5));
      expect(_contrastRatio(bodyColor, scheme.surface), greaterThan(4.5));
      expect(_contrastRatio(supportingColor, scheme.surface), greaterThan(4.5));
    }
  });

  test('blue preset surfaces avoid greenish tint in dark and light modes', () {
    const bluePresets = <ThemeAccentPreset>[
      ThemeAccentPreset.blue,
      ThemeAccentPreset.sky,
      ThemeAccentPreset.cyan,
    ];

    for (final preset in bluePresets) {
      final darkSurface = preset.bootstrapSurfaceColor(Brightness.dark);
      expect(darkSurface, const Color(0xFF101218));
      expect(darkSurface.b, greaterThan(darkSurface.g));
      expect(darkSurface.b, greaterThan(darkSurface.r));

      final lightSurface = preset.bootstrapSurfaceColor(Brightness.light);
      expect(lightSurface, const Color(0xFFF7F9FF));
      expect(lightSurface.b, greaterThan(lightSurface.g));
      expect(lightSurface.b, greaterThan(lightSurface.r));
    }
  });

  test('pure black surfaces preserve elevation hierarchy and token flag', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();
    addTearDown(provider.dispose);

    await provider.setPureBlackTheme(true);
    final scheme = provider.darkTheme.colorScheme;
    final tokens = provider.darkTheme.extension<AppDesignTokens>()!;
    expect(tokens.pureBlack, isTrue);
    expect(scheme.surface, const Color(0xFF000000));
    expect(scheme.surfaceContainerLowest, const Color(0xFF000000));
    expect(landscapeNavigationBackground(scheme), const Color(0xFF000000));
    expect(
      scheme.surfaceContainerLow.computeLuminance(),
      greaterThan(scheme.surface.computeLuminance()),
    );
    expect(
      scheme.surfaceContainer.computeLuminance(),
      greaterThan(scheme.surfaceContainerLow.computeLuminance()),
    );
    expect(
      scheme.surfaceContainerHigh.computeLuminance(),
      greaterThan(scheme.surfaceContainer.computeLuminance()),
    );
    expect(
      provider.darkTheme.dialogTheme.backgroundColor,
      scheme.surfaceContainerHigh,
    );
    expect(
      provider.darkTheme.bottomSheetTheme.backgroundColor,
      scheme.surfaceContainerHigh,
    );
    expect(
      provider.darkTheme.snackBarTheme.backgroundColor,
      scheme.surfaceContainerHigh,
    );
  });

  test('custom and system accent colors persist, apply, and clear on preset selection', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();
    addTearDown(provider.dispose);

    const customGreen = Color(0xFF2E9C8B);
    expect(await provider.setCustomThemeColor(customGreen), isTrue);
    expect(provider.customThemeColor, customGreen);
    expect(provider.effectiveStartupPreset, ThemeAccentPreset.teal);

    final restored = ThemeProvider();
    addTearDown(restored.dispose);
    expect(restored.customThemeColor, customGreen);

    restored.setSystemAccentColor(const Color(0xFF1E88E5));
    expect(await restored.setUseSystemAccentColor(true), isTrue);
    expect(restored.useSystemAccentColor, isTrue);
    expect(restored.activeCustomSeedColor, const Color(0xFF1E88E5));
    expect(restored.effectiveStartupPreset, ThemeAccentPreset.blue);

    expect(await restored.setAppThemeColor(ThemeAccentPreset.purple), isTrue);
    expect(restored.customThemeColor, isNull);
    expect(restored.useSystemAccentColor, isFalse);
    expect(restored.effectiveStartupPreset, ThemeAccentPreset.purple);
  });

  test('high contrast themes increase foreground contrast in both brightnesses', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();
    addTearDown(provider.dispose);

    for (final (standard, highContrast) in [
      (provider.lightTheme.colorScheme, provider.highContrastLightTheme.colorScheme),
      (provider.darkTheme.colorScheme, provider.highContrastDarkTheme.colorScheme),
    ]) {
      expect(
        _contrastRatio(highContrast.primary, highContrast.onPrimary),
        greaterThanOrEqualTo(
          _contrastRatio(standard.primary, standard.onPrimary),
        ),
      );
      expect(
        _contrastRatio(highContrast.onSurface, highContrast.surface),
        greaterThanOrEqualTo(
          _contrastRatio(standard.onSurface, standard.surface),
        ),
      );
    }
  });

  test(
    'setSystemAccentColor updates listenable without theme churn when disabled',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final provider = ThemeProvider();
      addTearDown(provider.dispose);

      final initialLight = provider.lightTheme;
      var providerNotifications = 0;
      Color? observedAccent;
      provider.addListener(() => providerNotifications++);
      provider.systemAccentColorListenable.addListener(
        () => observedAccent = provider.systemAccentColorListenable.value,
      );

      expect(provider.useSystemAccentColor, isFalse);
      provider.setSystemAccentColor(const Color(0xFF1E88E5));

      expect(provider.systemAccentColor, const Color(0xFF1E88E5));
      expect(observedAccent, const Color(0xFF1E88E5));
      expect(providerNotifications, 0);
      expect(provider.lightTheme, same(initialLight));

      expect(await provider.setUseSystemAccentColor(true), isTrue);
      expect(providerNotifications, 1);

      provider.setSystemAccentColor(const Color(0xFF43A047));
      expect(provider.systemAccentColor, const Color(0xFF43A047));
      expect(observedAccent, const Color(0xFF43A047));
      expect(providerNotifications, 2);
    },
  );

  test(
    'windowBorderColorFor matches light and dark color schemes across modes',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final provider = ThemeProvider();
      addTearDown(provider.dispose);

      int expectedBorder(ColorScheme colors) {
        final border = Color.alphaBlend(
          colors.outlineVariant.withValues(
            alpha: colors.brightness == Brightness.dark ? 0.45 : 0.65,
          ),
          colors.surface,
        );
        return border.toARGB32() & 0xffffff;
      }

      for (final pureBlack in [false, true]) {
        await provider.setPureBlackTheme(pureBlack);
        expect(
          provider.windowBorderColorFor(Brightness.light),
          expectedBorder(provider.lightTheme.colorScheme),
        );
        expect(
          provider.windowBorderColorFor(Brightness.dark),
          expectedBorder(provider.darkTheme.colorScheme),
        );
      }

      await provider.setCustomThemeColor(const Color(0xFF2E9C8B));
      expect(
        provider.windowBorderColorFor(Brightness.light),
        expectedBorder(provider.lightTheme.colorScheme),
      );
      expect(
        provider.windowBorderColorFor(Brightness.dark),
        expectedBorder(provider.darkTheme.colorScheme),
      );
    },
  );

  test(
    'refined light surfaces, semantic tokens, high-contrast tokens, and readable helpers meet contrast targets',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final provider = ThemeProvider();
      addTearDown(provider.dispose);

      for (final preset in ThemeAccentPreset.values) {
        final light = preset.colorScheme(Brightness.light);
        final floatingLight = appFloatingSurfaceColor(light);
        expect(
          floatingLight.computeLuminance(),
          greaterThan(light.surface.computeLuminance()),
          reason: '${preset.name} light floating surface should lift above canvas',
        );
        expect(
          _contrastRatio(AppDesignTokens.light.folderColor, light.surfaceContainerLow),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.name} light folder icon contrast on card',
        );
        expect(
          _contrastRatio(AppDesignTokens.light.textFileColor, light.surfaceContainerLow),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrastRatio(AppDesignTokens.light.imageFileColor, light.surfaceContainerLow),
          greaterThanOrEqualTo(4.5),
        );
      }

      final hcLightTokens =
          provider.highContrastLightTheme.extension<AppDesignTokens>()!;
      final hcDarkTokens =
          provider.highContrastDarkTheme.extension<AppDesignTokens>()!;
      expect(hcLightTokens.highContrast, isTrue);
      expect(hcDarkTokens.highContrast, isTrue);
      expect(
        hcLightTokens.standardBorderAlpha,
        greaterThan(AppDesignTokens.light.standardBorderAlpha),
      );
      expect(
        hcDarkTokens.standardBorderAlpha,
        greaterThan(AppDesignTokens.dark.standardBorderAlpha),
      );

      final darkSurface = provider.darkTheme.colorScheme.surface;
      final lightSurface = provider.lightTheme.colorScheme.surface;
      expect(
        _contrastRatio(
          appReadableAccentColor(
            const Color(0xFF0A0A0A),
            darkSurface,
            targetContrast: 3.5,
          ),
          darkSurface,
        ),
        greaterThanOrEqualTo(3.5),
      );
      expect(
        _contrastRatio(
          appReadableAccentColor(
            const Color(0xFFFFF0A0),
            lightSurface,
            targetContrast: 3.5,
          ),
          lightSurface,
        ),
        greaterThanOrEqualTo(3.5),
      );

      final darkMonochrome = ThemeAccentPreset.monochrome.colorScheme(
        Brightness.dark,
      );
      final monoFeedback = appAccentFeedbackColor(
        darkMonochrome,
        darkMonochrome.primary,
      );
      expect(monoFeedback, isNot(darkMonochrome.primary));
      expect(
        monoFeedback.computeLuminance(),
        lessThan(darkMonochrome.primary.computeLuminance()),
      );
    },
  );

  test(
    'disposal guards setSystemAccentColor and post-await notifications',
    () async {
      final gate = Completer<bool>();
      final provider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (_, _) => gate.future,
      );
      var notifications = 0;
      provider.addListener(() => notifications++);

      final pending = provider.setThemeMode(ThemeMode.dark);
      expect(notifications, 1);
      provider.dispose();

      // Must not throw after disposal.
      provider.setSystemAccentColor(const Color(0xFF1E88E5));
      gate.complete(false);
      expect(await pending, isFalse);
      expect(notifications, 1);
    },
  );

  test(
    'partial multi-key write failure keeps succeeded keys synced and rolls back failed keys',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      var failKey = '';
      final provider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (key, _) async => key != failKey,
      );
      addTearDown(provider.dispose);

      const customColor = Color(0xFF2E9C8B);
      expect(await provider.setCustomThemeColor(customColor), isTrue);
      expect(await provider.setUseSystemAccentColor(true), isTrue);

      failKey = 'customThemeColor';
      expect(await provider.setAppThemeColor(ThemeAccentPreset.teal), isFalse);
      // appThemeColor and useSystemAccentColor succeeded; only customThemeColor rolled back.
      expect(provider.appThemeColor, ThemeAccentPreset.teal);
      expect(provider.useSystemAccentColor, isFalse);
      expect(provider.customThemeColor, customColor);

      // A later failure on appThemeColor must roll back to teal (the last persisted value), not rose.
      failKey = 'appThemeColor';
      expect(await provider.setAppThemeColor(ThemeAccentPreset.blue), isFalse);
      expect(provider.appThemeColor, ThemeAccentPreset.teal);

      // Verify setCustomThemeColor per-key partial outcome as well.
      failKey = '';
      expect(await provider.setUseSystemAccentColor(true), isTrue);
      failKey = 'useSystemAccentColor';
      const nextCustom = Color(0xFF1E88E5);
      expect(await provider.setCustomThemeColor(nextCustom), isFalse);
      expect(provider.customThemeColor, nextCustom);
      expect(provider.useSystemAccentColor, isTrue);
    },
  );

  test(
    'reloadPersistedState awaits pending writes and suppresses stale rollbacks',
    () async {
      SharedPreferences.setMockInitialValues({'themeMode': 'light'});
      await AppPreferences.init();
      final gate = Completer<bool>();
      final provider = ThemeProvider(
        preferenceWriter: (_, _) => gate.future,
      );
      addTearDown(provider.dispose);
      expect(provider.themeMode, ThemeMode.light);

      final write = provider.setThemeMode(ThemeMode.dark);
      SharedPreferences.setMockInitialValues({'themeMode': 'system'});
      await AppPreferences.init();

      var reloadDone = false;
      final reload = provider.reloadPersistedState().then((_) {
        reloadDone = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(reloadDone, isFalse);

      gate.complete(false);
      await Future.wait([write, reload]);
      expect(reloadDone, isTrue);
      expect(provider.themeMode, ThemeMode.system);
    },
  );

  test(
    'setPureBlackTheme notifies listeners in light mode on change and rollback',
    () async {
      var shouldPersist = true;
      final provider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (_, _) async => shouldPersist,
      );
      addTearDown(provider.dispose);

      expect(await provider.setThemeMode(ThemeMode.light), isTrue);
      var notifications = 0;
      provider.addListener(() => notifications++);

      expect(await provider.setPureBlackTheme(true), isTrue);
      expect(provider.pureBlackTheme, isTrue);
      expect(notifications, 1);

      shouldPersist = false;
      expect(await provider.setPureBlackTheme(false), isFalse);
      expect(provider.pureBlackTheme, isTrue);
      // One notification for optimistic update, one for rollback.
      expect(notifications, 3);
    },
  );

  test(
    'overlapping reloadPersistedState calls discard stale reload',
    () async {
      SharedPreferences.setMockInitialValues({'themeMode': 'light'});
      await AppPreferences.init();
      final gates = <Completer<bool>>[];
      final provider = ThemeProvider(
        preferenceWriter: (_, _) {
          final gate = Completer<bool>();
          gates.add(gate);
          return gate.future;
        },
      );
      addTearDown(provider.dispose);
      expect(provider.themeMode, ThemeMode.light);

      // Start write1 and reload1 awaiting write1.
      final write1 = provider.setThemeMode(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(1));
      final reload1 = provider.reloadPersistedState();

      // Queue write2 and a newer reload2 before write1 completes.
      final write2 = provider.setThemeMode(ThemeMode.system);
      SharedPreferences.setMockInitialValues({'themeMode': 'light'});
      await AppPreferences.init();
      final reload2 = provider.reloadPersistedState();

      // Complete write1; reload1 resumes with stale generation and must NOT
      // overwrite the current state or notify.
      var notifications = 0;
      provider.addListener(() => notifications++);
      gates[0].complete(true);
      await write1;
      await reload1;
      expect(notifications, 0);
      expect(provider.themeMode, ThemeMode.system);

      // Now update storage for reload2 and complete write2.
      SharedPreferences.setMockInitialValues({'themeMode': 'dark'});
      await AppPreferences.init();
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(2));
      gates[1].complete(true);
      await Future.wait([write2, reload2]);
      expect(provider.themeMode, ThemeMode.dark);
      expect(notifications, 1);
    },
  );
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
