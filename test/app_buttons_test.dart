import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/core/widgets/app_buttons.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Android buttons show feedback for a quick tap in a scroll view', (
    tester,
  ) async {
    final theme = ThemeProvider(loadPersistedState: false);
    addTearDown(theme.dispose);
    var taps = 0;
    void activate() => taps++;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.lightTheme.copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TextButton(onPressed: activate, child: const Text('Text')),
                IconButton(onPressed: activate, icon: const Icon(Icons.add)),
                AppPillButton(onPressed: activate, child: const Text('Pill')),
                Builder(
                  builder: (context) => appNoPointerInkTheme(
                    context: context,
                    androidPressHighlight: true,
                    child: ChoiceChip(
                      label: const Text('Option'),
                      selected: false,
                      onSelected: (_) {},
                    ),
                  ),
                ),
                const SizedBox(height: 800),
              ],
            ),
          ),
        ),
      ),
    );

    for (final (target, pressedScale) in [
      (find.text('Text'), 0.94),
      (find.byIcon(Icons.add), 0.84),
      (find.text('Pill'), 0.98),
    ]) {
      final before = taps;
      final gesture = await tester.startGesture(tester.getCenter(target));
      await tester.pump();
      expect(_scale(tester, target), pressedScale);
      expect(taps, before);
      await gesture.up();
      await tester.pump();
      expect(taps, before + 1);
      expect(_scale(tester, target), pressedScale);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();
      expect(_scale(tester, target), 1);
    }

    final option = find.byType(ChoiceChip);
    await tester.tap(option);
    await tester.pump();
    expect(_visibleInk(tester, option), isNotEmpty);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_visibleInk(tester, option), isEmpty);

    final text = find.text('Text');
    final cancelled = await tester.startGesture(tester.getCenter(text));
    await tester.pump();
    expect(_scale(tester, text), 0.94);
    await cancelled.moveBy(const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(_scale(tester, text), 1);
    await cancelled.up();
    expect(taps, 3);
  });

  testWidgets('action targets use a hand cursor and text fields keep the caret', (
    tester,
  ) async {
    final theme = ThemeProvider(loadPersistedState: false);
    addTearDown(theme.dispose);
    void activate() {}

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.lightTheme.copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Column(
            children: [
              TextButton(onPressed: activate, child: const Text('Text action')),
              const TextButton(onPressed: null, child: Text('Disabled action')),
              IconButton(onPressed: activate, icon: const Icon(Icons.add)),
              AppTextLink(label: 'Link', onTap: activate),
              AppEntryInkWell(
                onTap: activate,
                child: const ListTile(title: Text('Wrapped row')),
              ),
              ListTile(title: const Text('Action row'), onTap: activate),
              const ListTile(title: Text('Static row')),
              ChoiceChip(
                label: const Text('Chip'),
                selected: false,
                mouseCursor: WidgetStateMouseCursor.clickable,
                onSelected: (_) {},
              ),
              UnifiedDropdownButton<int>(
                value: 1,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('Dropdown option')),
                ],
                onChanged: (_) {},
              ),
              const TextField(key: ValueKey('editable')),
            ],
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    Future<void> expectCursor(Finder target, MouseCursor cursor) async {
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        cursor,
        reason: target.toString(),
      );
    }

    for (final label in [
      'Text action',
      'Link',
      'Wrapped row',
      'Action row',
      'Chip',
      'Dropdown option',
    ]) {
      await expectCursor(find.text(label), SystemMouseCursors.click);
    }
    await expectCursor(find.byIcon(Icons.add), SystemMouseCursors.click);
    await expectCursor(find.text('Disabled action'), SystemMouseCursors.basic);
    await expectCursor(find.text('Static row'), SystemMouseCursors.basic);
    await expectCursor(
      find.byKey(const ValueKey('editable')),
      SystemMouseCursors.text,
    );
  });

  final displayScales = ValueVariant<double>({1, 1.25, 1.5});
  for (final isPill in [false, true]) {
    testWidgets(
      'Windows ${isPill ? 'pill' : 'icon'} scale settles across rapid pointer changes',
      (tester) async {
        const buttonKey = ValueKey('button');
        const glyph = Icons.check;
        final pixelRatio = displayScales.currentValue!;
        tester.view.devicePixelRatio = pixelRatio;
        addTearDown(tester.view.resetDevicePixelRatio);
        const hoverColor = Color(0xFF0055DD);
        final theme = ThemeData(
          platform: TargetPlatform.windows,
          colorScheme: const ColorScheme.light(primary: hoverColor),
          extensions: [AppDesignTokens.light.copyWith(barGlassEnabled: true)],
        );
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: buttonKey,
                  child: isPill
                      ? SizedBox(
                          width: 160,
                          child: AppPrimaryButton(
                            onPressed: () => taps++,
                            label: 'Confirm',
                          ),
                        )
                      : HeaderFloatingButton(
                          followBarGlass: true,
                          child: IconButton(
                            onPressed: () => taps++,
                            icon: const Icon(glyph),
                          ),
                        ),
                ),
              ),
            ),
          ),
        );
        final button = find.byKey(buttonKey);
        final content = isPill ? find.text('Confirm') : find.byIcon(glyph);
        final bounds = tester.getRect(button);
        final center = tester.getCenter(content);
        final edge = bounds.centerRight - const Offset(0.5, 0);
        final outside = bounds.centerRight + const Offset(30, 0);
        const hoverScale = 1.0;
        final pressScale = isPill ? 0.975 : 0.82;

        Future<List<int>> raster() async => (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(button);
          final image = await boundary.toImage(pixelRatio: pixelRatio);
          try {
            final bytes = (await image.toByteData())!;
            return bytes.buffer.asUint8List(
              bytes.offsetInBytes,
              bytes.lengthInBytes,
            );
          } finally {
            image.dispose();
          }
        }))!;

        double sample() {
          final transform = tester
              .widgetList<Transform>(
                find.ancestor(of: content, matching: find.byType(Transform)),
              )
              .singleWhere((widget) => !widget.transformHitTests);
          expect(transform.filterQuality, isNull);
          expect((tester.getCenter(content) - center).distance, lessThan(1e-6));
          expect(tester.getRect(button), bounds);
          return transform.transform.entry(0, 0);
        }

        Future<double> advanceToward(double target, int frameCount) async {
          var previous = sample();
          for (var frame = 0; frame < frameCount; frame++) {
            await tester.pump(const Duration(milliseconds: 15));
            final current = sample();
            expect(
              current,
              inInclusiveRange(
                previous < target ? previous : target,
                previous > target ? previous : target,
              ),
            );
            previous = current;
          }
          return previous;
        }

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: outside);
        expect(sample(), 1);
        final idleRaster = await raster();
        await mouse.moveTo(edge);
        await tester.pump();
        expect(sample(), 1);
        expect(await advanceToward(hoverScale, 6), hoverScale);
        if (!isPill) {
          await tester.pump(const Duration(milliseconds: 600));
          final pixels = await raster();
          var highlightedPixels = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            if (pixels[i] == 0 &&
                pixels[i + 1] == 0x55 &&
                pixels[i + 2] == 0xDD &&
                pixels[i + 3] == 0xFF) {
              highlightedPixels++;
            }
          }
          expect(highlightedPixels, greaterThan(0));
        }

        for (var click = 0; click < 2; click++) {
          final beforePress = sample();
          await mouse.down(edge);
          await tester.pump();
          expect(sample(), beforePress);
          final pressed = await advanceToward(pressScale, 1);
          expect(pressed, lessThan(beforePress));
          await mouse.up();
          await tester.pump();
          expect(sample(), pressed);
          await advanceToward(hoverScale, 1);
          expect(taps, click + 1);
        }
        expect(await advanceToward(hoverScale, 5), hoverScale);

        await mouse.down(edge);
        await tester.pump();
        expect(await advanceToward(pressScale, 4), pressScale);
        await mouse.moveTo(outside);
        await tester.pump();
        expect(sample(), pressScale);
        expect(await advanceToward(1, 6), 1);
        await mouse.up();
        expect(taps, 2);

        await mouse.moveTo(edge);
        await tester.pump();
        expect(await advanceToward(hoverScale, 6), hoverScale);
        await mouse.moveTo(outside);
        await tester.pump();
        expect(await advanceToward(1, 6), 1);
        expect(await raster(), orderedEquals(idleRaster));
        await mouse.moveTo(edge);
        await tester.pump();
        expect(await advanceToward(hoverScale, 6), hoverScale);
        await mouse.moveTo(outside);
        await tester.pump();
        expect(await advanceToward(1, 6), 1);
        expect(await raster(), orderedEquals(idleRaster));
        expect(await advanceToward(1, 2), 1);
        expect(await raster(), orderedEquals(idleRaster));
        expect(taps, 2);
        await mouse.removePointer();
      },
      variant: displayScales,
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'text and icon buttons use foreground feedback on $platform $brightness',
        (tester) async {
          final theme = ThemeProvider(loadPersistedState: false);
          addTearDown(theme.dispose);
          final focus = FocusNode();
          addTearDown(focus.dispose);
          var taps = 0;
          const textMixed = ValueKey('text_mixed');
          const iconOnly = ValueKey('icon');
          const textOnly = ValueKey('text');
          const disabled = ValueKey('disabled');
          await tester.pumpWidget(
            MaterialApp(
              theme:
                  (brightness == Brightness.dark
                          ? theme.darkTheme
                          : theme.lightTheme)
                      .copyWith(platform: platform),
              home: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppLabelledButton(
                        TextButton.icon,
                        key: textMixed,
                        onPressed: () => taps++,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open'),
                      ),
                      IconButton(
                        key: iconOnly,
                        focusNode: focus,
                        onPressed: () => taps++,
                        icon: const Icon(Icons.play_arrow),
                      ),
                      TextButton(
                        key: textOnly,
                        onPressed: () => taps++,
                        child: const Text('Save'),
                      ),
                      const IconButton(
                        key: disabled,
                        onPressed: null,
                        icon: Icon(Icons.pause),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

          final cs = Theme.of(
            tester.element(find.byType(Scaffold)),
          ).colorScheme;
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          for (final (key, iconData, label, highlightsOnWindows) in [
            (textMixed, Icons.folder_open, 'Open', true),
            (iconOnly, Icons.play_arrow, null, true),
            (textOnly, null, 'Save', false),
            (disabled, Icons.pause, null, false),
          ]) {
            final button = find.byKey(key);
            final icon = iconData == null ? null : find.byIcon(iconData);
            final text = label == null ? null : find.text(label);
            final restColor = icon == null ? null : _glyphColor(tester, icon);
            final restTextColor = text == null ? null : _glyphColor(tester, text);
            final bounds = tester.getRect(button);
            final textBounds = text == null ? null : tester.getRect(text);
            final tapPoint = bounds.centerRight - const Offset(6, 0);
            final before = taps;
            final enabled = key != disabled;
            await mouse.moveTo(tapPoint);
            await tester.pumpAndSettle();
            if (icon != null) {
              expect(_scale(tester, icon), 1);
              final windowsHighlight =
                  restColor?.toARGB32() == cs.primary.toARGB32()
                  ? Color.lerp(cs.primary, cs.onPrimaryContainer, 0.35)
                  : cs.primary;
              if (text == null) {
                final expectedHoverColor =
                    platform == TargetPlatform.windows && highlightsOnWindows
                    ? windowsHighlight
                    : restColor;
                expect(_glyphColor(tester, icon), expectedHoverColor);
              } else if (platform == TargetPlatform.windows) {
                expect(_scale(tester, text), 1);
                final textColor = _glyphColor(tester, text);
                expect(textColor, isNot(restTextColor));
                expect(_glyphColor(tester, icon), textColor);
              }
            } else if (key == textOnly) {
              expect(_scale(tester, text!), 1.0);
              if (platform == TargetPlatform.windows) {
                expect(_surfaceColor(tester, button)?.a ?? 0, 0);
                expect(_glyphColor(tester, text), isNot(equals(restTextColor)));
              }
            }
            expect(_visibleInk(tester, button), isEmpty);
            final press = platform == TargetPlatform.windows
                ? mouse
                : await tester.startGesture(tapPoint);
            if (platform == TargetPlatform.windows) await press.down(tapPoint);
            await tester.pumpAndSettle();
            if (icon != null) {
              expect(
                _scale(tester, icon),
                enabled
                    ? (text == null
                          ? (platform == TargetPlatform.windows ? 0.82 : 0.84)
                          : 0.94)
                    : 1,
              );
              if (text != null) {
                expect(_scale(tester, text), 0.94);
                final textColor = _glyphColor(tester, text);
                expect(textColor, isNot(restTextColor));
                expect(_glyphColor(tester, icon), textColor);
                expect(
                  tester.getRect(text).center.dx,
                  closeTo(textBounds!.center.dx, 1),
                );
              }
            } else if (key == textOnly) {
              expect(_scale(tester, text!), 0.94);
            }
            expect(tester.getRect(button), bounds);
            expect(_visibleInk(tester, button), isEmpty);
            await press.up();
            expect(taps - before, enabled ? 1 : 0);
            await mouse.moveTo(Offset.zero);
            await tester.pumpAndSettle();
            if (icon != null) {
              expect(_scale(tester, icon), 1);
              expect(_glyphColor(tester, icon), restColor);
            } else if (key == textOnly) {
              expect(_scale(tester, text!), 1);
              expect(_glyphColor(tester, text), restTextColor);
            }
          }
          await mouse.removePointer();

          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.alwaysTraditional;
          addTearDown(() {
            FocusManager.instance.highlightStrategy =
                FocusHighlightStrategy.automatic;
          });
          focus.requestFocus();
          await tester.pumpAndSettle();
          expect(_visibleInk(tester, find.byKey(iconOnly)), isNotEmpty);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          expect(taps, 4);
        },
      );
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'surface and pill buttons use whole-pill hover emphasis on $platform $brightness',
        (tester) async {
          final theme = ThemeProvider(loadPersistedState: false);
          addTearDown(theme.dispose);
          var taps = 0;
          const filledMixed = ValueKey('filled_mixed');
          const tonalNeutral = ValueKey('tonal_neutral');
          const outlinedMixed = ValueKey('outlined_mixed');
          const primaryPlain = ValueKey('primary_plain');
          const secondaryPlain = ValueKey('secondary_plain');
          const floatingPill = ValueKey('floating_pill');
          const disabledPill = ValueKey('disabled_pill');
          final baseTheme = brightness == Brightness.dark
              ? theme.darkTheme
              : theme.lightTheme;

          await tester.pumpWidget(
            MaterialApp(
              theme: baseTheme.copyWith(platform: platform),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 240,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppLabelledButton(
                          FilledButton.icon,
                          key: filledMixed,
                          onPressed: () => taps++,
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Download'),
                        ),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (context) {
                            final cs = Theme.of(context).colorScheme;
                            final isDark =
                                Theme.of(context).brightness == Brightness.dark;
                            return AppLabelledButton(
                              FilledButton.tonalIcon,
                              key: tonalNeutral,
                              style: FilledButton.styleFrom(
                                backgroundColor: isDark
                                    ? cs.surfaceContainerHighest.withValues(
                                        alpha: 0.45,
                                      )
                                    : cs.surfaceContainerHigh.withValues(
                                        alpha: 0.65,
                                      ),
                                foregroundColor: cs.onSurface,
                                side: BorderSide(
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                              onPressed: () => taps++,
                              icon: const Icon(Icons.cloud_download_rounded),
                              label: const Text('Fetch Info'),
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        AppLabelledButton(
                          OutlinedButton.icon,
                          key: outlinedMixed,
                          onPressed: () => taps++,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Browse'),
                        ),
                        const SizedBox(height: 8),
                        KeyedSubtree(
                          key: primaryPlain,
                          child: AppPrimaryButton(
                            onPressed: () => taps++,
                            label: 'Continue',
                          ),
                        ),
                        const SizedBox(height: 8),
                        KeyedSubtree(
                          key: secondaryPlain,
                          child: AppSecondaryButton(
                            onPressed: () => taps++,
                            label: 'Cancel',
                          ),
                        ),
                        const SizedBox(height: 8),
                        HeaderFloatingActionPill(
                          pillKey: floatingPill,
                          icon: Icons.check_rounded,
                          label: 'Confirm',
                          onTap: () => taps++,
                        ),
                        const SizedBox(height: 8),
                        const HeaderFloatingActionPill(
                          pillKey: disabledPill,
                          icon: Icons.play_arrow_rounded,
                          label: 'Start',
                          onTap: null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

          final isWindows = platform == TargetPlatform.windows;
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);

          for (final (key, label, hasIcon, enabled) in [
            (filledMixed, 'Download', true, true),
            (tonalNeutral, 'Fetch Info', true, true),
            (outlinedMixed, 'Browse', true, true),
            (primaryPlain, 'Continue', false, true),
            (secondaryPlain, 'Cancel', false, true),
            (floatingPill, 'Confirm', true, true),
            (disabledPill, 'Start', true, false),
          ]) {
            final target = find.byKey(key);
            final labelFinder = find.descendant(
              of: target,
              matching: find.text(label),
            );
            final iconFinder = hasIcon
                ? find.descendant(of: target, matching: find.byType(Icon))
                : null;
            final beforeBg = _surfaceColor(tester, target);
            final beforeBorder = _surfaceBorderColor(tester, target);
            final restLabelColor = _glyphColor(tester, labelFinder);
            void expectHighlightedContent() {
              if (iconFinder == null) return;
              final labelColor = _glyphColor(tester, labelFinder);
              expect(labelColor, isNot(restLabelColor));
              expect(_glyphColor(tester, iconFinder), labelColor);
            }
            final center = tester.getCenter(target);
            final before = taps;

            await mouse.moveTo(center);
            await tester.pumpAndSettle();
            expect(_scale(tester, labelFinder), 1.0);
            if (iconFinder != null) {
              // Whole pill moves together; inner icon must not add a second scale.
              expect(_scale(tester, iconFinder), 1.0);
            }
            if (enabled && isWindows) {
              expect(_surfaceColor(tester, target), isNot(beforeBg));
              expectHighlightedContent();
            } else {
              expect(_surfaceColor(tester, target), beforeBg);
            }
            expect(_surfaceBorderColor(tester, target), beforeBorder);
            expect(_visibleInk(tester, target), isEmpty);

            await mouse.down(center);
            await tester.pumpAndSettle();
            final paintsPressInk = enabled && !isWindows && key != floatingPill;
            if (enabled && !paintsPressInk) {
              expect(_surfaceColor(tester, target), isNot(beforeBg));
            }
            if (enabled) expectHighlightedContent();
            expect(
              _scale(tester, labelFinder),
              enabled ? (isWindows ? 0.975 : 0.98) : 1.0,
            );
            expect(
              _visibleInk(tester, target),
              paintsPressInk ? isNotEmpty : isEmpty,
            );

            await mouse.up();
            await tester.pumpAndSettle();
            expect(taps - before, enabled ? 1 : 0);

            await mouse.moveTo(Offset.zero);
            await tester.pumpAndSettle();
            expect(_scale(tester, labelFinder), 1.0);
            expect(_surfaceColor(tester, target), beforeBg);
          }
          await mouse.removePointer();
        },
      );
    }
  }

  testWidgets(
    'reduced motion changes icon opacity and Windows color immediately',
    (tester) async {
      const action = ValueKey('action');
      var taps = 0;
      final theme = ThemeProvider(loadPersistedState: false);
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.lightTheme.copyWith(platform: TargetPlatform.windows),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Center(
                child: IconButton(
                  key: action,
                  style: appIconButtonStyle(),
                  onPressed: () => taps++,
                  icon: const Icon(Icons.play_arrow),
                ),
              ),
            ),
          ),
        ),
      );
      final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      final button = find.byKey(action);
      final icon = find.byIcon(Icons.play_arrow);
      final restColor = _glyphColor(tester, icon);
      final opacity = find.descendant(
        of: button,
        matching: find.byType(Opacity),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(button));
      await tester.pump();
      expect(_scale(tester, icon), 1);
      expect(tester.widget<Opacity>(opacity).opacity, 0.85);
      expect(_glyphColor(tester, icon), cs.primary);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(_glyphColor(tester, icon), restColor);
      await mouse.removePointer();

      final held = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      expect(_scale(tester, icon), 1);
      expect(tester.widget<Opacity>(opacity).opacity, 0.72);
      await held.cancel();
      await tester.pump();
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      expect(taps, 0);
      await tester.tap(button);
      expect(taps, 1);
    },
  );

  testWidgets('reduced motion highlights surface pill immediately on Windows', (
    tester,
  ) async {
    const pill = ValueKey('pill');
    var taps = 0;
    final theme = ThemeProvider(loadPersistedState: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.darkTheme.copyWith(platform: TargetPlatform.windows),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: HeaderFloatingActionPill(
                pillKey: pill,
                icon: Icons.check_rounded,
                label: 'Confirm',
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      ),
    );
    final target = find.byKey(pill);
    final label = find.text('Confirm');
    final restBg = _surfaceColor(tester, target);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
    expect(_scale(tester, label), 1);
    final hoverBg = _surfaceColor(tester, target);
    expect(hoverBg, isNot(restBg));
    expect(_surfaceBorderColor(tester, target), isNull);

    await mouse.down(tester.getCenter(target));
    await tester.pump();
    expect(_scale(tester, label), 1);
    expect(_surfaceColor(tester, target), isNot(hoverBg));
    await mouse.up();
    await tester.pump();
    expect(taps, 1);
    await mouse.removePointer();
  });

  testWidgets('custom styled buttons, FAB, and chips suppress pointer ink', (
    tester,
  ) async {
    final theme = ThemeProvider(loadPersistedState: false);
    addTearDown(theme.dispose);
    var filterSelected = false;
    var choiceSelected = false;
    var taps = 0;
    const customIcon = ValueKey('custom_icon');
    const customFilled = ValueKey('custom_filled');
    const fabKey = ValueKey('fab');
    const filterKey = ValueKey('filter_chip');
    const choiceKey = ValueKey('choice_chip');
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.lightTheme.copyWith(platform: TargetPlatform.windows),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            floatingActionButton: appNoPointerInkTheme(
              context: context,
              child: FloatingActionButton(
                key: fabKey,
                onPressed: () => taps++,
                child: const Icon(Icons.add),
              ),
            ),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: customIcon,
                    style: appIconButtonStyle(
                      IconButton.styleFrom(minimumSize: const Size(38, 38)),
                    ),
                    onPressed: () => taps++,
                    icon: const Icon(Icons.check),
                  ),
                  FilledButton(
                    key: customFilled,
                    style: appButtonStyle(
                      FilledButton.styleFrom(minimumSize: const Size(80, 40)),
                    ),
                    onPressed: () => taps++,
                    child: const Text('Apply'),
                  ),
                  appNoPointerInkTheme(
                    context: context,
                    child: FilterChip(
                      key: filterKey,
                      label: const Text('Tag'),
                      selected: filterSelected,
                      onSelected: (v) => setState(() => filterSelected = v),
                    ),
                  ),
                  appNoPointerInkTheme(
                    context: context,
                    child: ChoiceChip(
                      key: choiceKey,
                      label: const Text('Mode'),
                      selected: choiceSelected,
                      onSelected: (v) => setState(() => choiceSelected = v),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final key in [
      customIcon,
      customFilled,
      fabKey,
      filterKey,
      choiceKey,
    ]) {
      final target = find.byKey(key);
      final center = tester.getCenter(target);
      await mouse.moveTo(center);
      await tester.pumpAndSettle();
      if (key == customIcon) {
        expect(_scale(tester, find.byIcon(Icons.check)), 1.0);
        expect(
          _glyphColor(tester, find.byIcon(Icons.check)),
          theme.lightTheme.colorScheme.primary,
        );
      }
      expect(_visibleInk(tester, target), isEmpty, reason: '$key hover');
      await mouse.down(center);
      await tester.pumpAndSettle();
      if (key == customIcon) {
        expect(_scale(tester, find.byIcon(Icons.check)), 0.82);
      }
      expect(_visibleInk(tester, target), isEmpty, reason: '$key press');
      await mouse.up();
      await tester.pumpAndSettle();
    }
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(_scale(tester, find.byIcon(Icons.check)), 1.0);
    expect(taps, 3);
    expect(filterSelected, isTrue);
    expect(choiceSelected, isTrue);
    await mouse.removePointer();
  });

  testWidgets(
    'SegmentedButton highlights hovered segment on Windows and reacts on press',
    (tester) async {
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        final theme = ThemeProvider(loadPersistedState: false);
        addTearDown(theme.dispose);
        var selected = 'a';
        await tester.pumpWidget(
          MaterialApp(
            theme:
                (platform == TargetPlatform.windows
                        ? theme.darkTheme
                        : theme.lightTheme)
                    .copyWith(
                      platform: platform,
                      segmentedButtonTheme: SegmentedButtonThemeData(
                        style: appSegmentedButtonStyle(
                          colorScheme:
                              (platform == TargetPlatform.windows
                                      ? theme.darkTheme
                                      : theme.lightTheme)
                                  .colorScheme,
                          platform: platform,
                        ),
                      ),
                    ),
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Center(
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment<String>(
                        value: 'a',
                        icon: Icon(Icons.folder_rounded),
                        label: Text('Current'),
                      ),
                      ButtonSegment<String>(
                        value: 'b',
                        icon: Icon(Icons.folder_copy_rounded),
                        label: Text('Cross'),
                      ),
                    ],
                    selected: {selected},
                    onSelectionChanged: (next) =>
                        setState(() => selected = next.first),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final segA = find
            .ancestor(
              of: find.text('Current'),
              matching: find.byType(TextButton),
            )
            .first;
        final segB = find
            .ancestor(of: find.text('Cross'), matching: find.byType(TextButton))
            .first;

        final restFillA = _surfaceColor(tester, segA);
        final restFillB = _surfaceColor(tester, segB);
        final restGlyphColorB = _glyphColor(
          tester,
          find.byIcon(Icons.folder_copy_rounded),
        );

        if (platform == TargetPlatform.windows) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);

          await mouse.moveTo(tester.getCenter(segB));
          await tester.pumpAndSettle();

          final hoverFillB = _surfaceColor(tester, segB);
          expect(hoverFillB, isNotNull);
          expect(hoverFillB, isNot(equals(restFillB)));
          expect(hoverFillB!.a, greaterThan(0));
          expect(
            _glyphColor(tester, find.byIcon(Icons.folder_copy_rounded)),
            restGlyphColorB,
          );
          expect(_surfaceColor(tester, segA), restFillA);
          expect(_visibleInk(tester, segB), isEmpty);

          await mouse.moveTo(tester.getCenter(segA));
          await tester.pumpAndSettle();
          final hoverFillA = _surfaceColor(tester, segA);
          expect(hoverFillA, isNotNull);
          expect(hoverFillA, isNot(equals(restFillA)));

          await mouse.removePointer();
          await tester.pumpAndSettle();
        }

        // Pressing an unselected segment shows pressed fill and switches on release.
        final gesture = await tester.startGesture(tester.getCenter(segB));
        await tester.pumpAndSettle();
        final pressFillB = _surfaceColor(tester, segB);
        expect(pressFillB, isNotNull);
        if (platform == TargetPlatform.android) {
          expect(_visibleInk(tester, segB), isNotEmpty);
        } else {
          expect(pressFillB, isNot(equals(restFillB)));
        }
        expect(
          _glyphColor(tester, find.byIcon(Icons.folder_copy_rounded)),
          restGlyphColorB,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selected, 'b');
      }
    },
  );

  testWidgets(
    'appChipTheme highlights hovered ChoiceChip without pointer ink',
    (tester) async {
      final theme = ThemeProvider(loadPersistedState: false);
      addTearDown(theme.dispose);
      var selected = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme.darkTheme.copyWith(
            platform: TargetPlatform.windows,
            chipTheme: appChipTheme(
              colorScheme: theme.darkTheme.colorScheme,
              platform: TargetPlatform.windows,
            ),
          ),
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Center(
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final i in [0, 1])
                      appNoPointerInkTheme(
                        context: context,
                        child: ChoiceChip(
                          showCheckmark: false,
                          label: Text('Opt $i'),
                          selected: selected == i,
                          onSelected: (_) => setState(() => selected = i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      final chip0 = find.ancestor(
        of: find.text('Opt 0'),
        matching: find.byType(ChoiceChip),
      );
      final chip1 = find.ancestor(
        of: find.text('Opt 1'),
        matching: find.byType(ChoiceChip),
      );
      final restBg1 = _surfaceColor(tester, chip1);
      final restBorder1 = _surfaceBorderColor(tester, chip1);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(chip1));
      await tester.pumpAndSettle();
      expect(_surfaceColor(tester, chip1), isNot(equals(restBg1)));
      expect(_surfaceBorderColor(tester, chip1), restBorder1);
      expect(_glyphColor(tester, find.text('Opt 1')), cs.onSurfaceVariant);
      expect(_visibleInk(tester, chip1), isEmpty);

      final restBg0 = _surfaceColor(tester, chip0);
      final restBorder0 = _surfaceBorderColor(tester, chip0);
      await mouse.moveTo(tester.getCenter(chip0));
      await tester.pumpAndSettle();
      expect(_surfaceColor(tester, chip0), isNot(equals(restBg0)));
      expect(_surfaceBorderColor(tester, chip0), restBorder0);

      await mouse.down(tester.getCenter(chip1));
      await tester.pumpAndSettle();
      expect(_visibleInk(tester, chip1), isEmpty);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selected, 1);
    },
  );

  testWidgets(
    'text tabs keep their selected surface and scale only the label',
    (tester) async {
      final theme = ThemeProvider(loadPersistedState: false);
      addTearDown(theme.dispose);
      var selected = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme.darkTheme.copyWith(platform: TargetPlatform.windows),
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Center(
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final i in [0, 1])
                      TextButton(
                        style: appSelectablePillButtonStyle(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          selected: selected == i,
                          colorScheme: Theme.of(context).colorScheme,
                        ),
                        onPressed: () => setState(() => selected = i),
                        child: Text('Tab $i'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      final tab0 = find.ancestor(
        of: find.text('Tab 0'),
        matching: find.byType(TextButton),
      );
      final tab1 = find.ancestor(
        of: find.text('Tab 1'),
        matching: find.byType(TextButton),
      );
      final restBg0 = _surfaceColor(tester, tab0);
      final restBg1 = _surfaceColor(tester, tab1);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(tab1));
      await tester.pumpAndSettle();
      expect(_surfaceColor(tester, tab1), restBg1);
      expect(_surfaceBorderColor(tester, tab1), isNull);
      expect(_scale(tester, find.text('Tab 1')), 1.0);
      expect(_glyphColor(tester, find.text('Tab 1')), cs.primary);
      expect(_visibleInk(tester, tab1), isEmpty);

      await mouse.moveTo(tester.getCenter(tab0));
      await tester.pumpAndSettle();
      expect(_surfaceColor(tester, tab0), restBg0);
      expect(_surfaceBorderColor(tester, tab0), isNull);

      await mouse.down(tester.getCenter(tab1));
      await tester.pumpAndSettle();
      expect(_visibleInk(tester, tab1), isEmpty);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selected, 1);
    },
  );

  testWidgets(
    'AppOverlayIconButton keeps high-contrast icon with circular backdrop on Windows hover',
    (tester) async {
      final theme = ThemeProvider(loadPersistedState: false);
      addTearDown(theme.dispose);
      const overlayKey = ValueKey('overlay_action');
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.darkTheme.copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: AppOverlayIconButton(
                buttonKey: overlayKey,
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      final button = find.byKey(overlayKey);
      final icon = find.byIcon(Icons.close_rounded);
      expect(_surfaceColor(tester, button), Colors.transparent);
      expect(_glyphColor(tester, icon), Colors.white);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(_surfaceColor(tester, button), Colors.black.withValues(alpha: 0.32));
      expect(_glyphColor(tester, icon), Colors.white);

      await mouse.down(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(_surfaceColor(tester, button), Colors.black.withValues(alpha: 0.48));
      expect(_glyphColor(tester, icon), Colors.white);
      await mouse.up();
      await tester.pumpAndSettle();
    },
  );
}

double _scale(WidgetTester tester, Finder target) {
  final ancestorTransforms = find.ancestor(
    of: target,
    matching: find.byType(Transform),
  );
  final outside = tester
      .widgetList<Transform>(ancestorTransforms)
      .where((widget) => !widget.transformHitTests);
  if (outside.isNotEmpty) {
    return outside.fold<double>(
      1.0,
      (product, widget) => product * widget.transform.entry(0, 0),
    );
  }
  return 1.0;
}

Color? _surfaceColor(WidgetTester tester, Finder button) {
  final materials = tester.widgetList<Material>(
    find.descendant(of: button, matching: find.byType(Material)),
  );
  for (final material in materials) {
    if (material.type != MaterialType.transparency && material.color != null) {
      return material.color;
    }
  }
  final containers = tester.widgetList<AnimatedContainer>(
    find.descendant(of: button, matching: find.byType(AnimatedContainer)),
  );
  for (final container in containers) {
    final decoration = container.decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration.color;
    }
  }
  final inks = tester.widgetList<Ink>(
    find.descendant(of: button, matching: find.byType(Ink)),
  );
  for (final ink in inks) {
    final decoration = ink.decoration;
    if (decoration is ShapeDecoration && decoration.color != null) {
      return decoration.color;
    }
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration.color;
    }
  }
  return null;
}

Color? _surfaceBorderColor(WidgetTester tester, Finder button) {
  final materials = tester.widgetList<Material>(
    find.descendant(of: button, matching: find.byType(Material)),
  );
  for (final material in materials) {
    final shape = material.shape;
    if (shape is OutlinedBorder && shape.side != BorderSide.none) {
      return shape.side.color;
    }
  }
  final containers = tester.widgetList<AnimatedContainer>(
    find.descendant(of: button, matching: find.byType(AnimatedContainer)),
  );
  for (final container in containers) {
    final decoration = container.decoration;
    if (decoration is BoxDecoration && decoration.border is Border) {
      return (decoration.border! as Border).top.color;
    }
  }
  return null;
}

Color? _glyphColor(WidgetTester tester, Finder icon) => tester
    .widget<RichText>(
      find.descendant(of: icon, matching: find.byType(RichText)),
    )
    .text
    .style
    ?.color;

Iterable<InteractiveInkFeature> _visibleInk(
  WidgetTester tester,
  Finder button,
) {
  final ink = find.descendant(
    of: button,
    matching: find.bySubtype<InkResponse>(),
  );
  final dynamic controller = Material.of(tester.element(ink.first));
  final features = controller.debugInkFeatures as List<InkFeature>? ?? [];
  return features.whereType<InteractiveInkFeature>().where(
    (feature) => feature.color.a > 0,
  );
}
