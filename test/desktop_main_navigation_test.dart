import 'dart:ui' as ui;

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'navigation rail blocks its transparent padding only on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await AppPreferences.init();
        final i18n = AppLanguageProvider();
        final activePage = ValueNotifier(0);
        final iconKeys = List.generate(
          MainDestinationType.values.length,
          (_) => GlobalKey(),
        );
        final destinations = resolveMainDestinations(
          showLocalLibrary: true,
          showAsmrOne: true,
        );
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          i18n.dispose();
          activePage.dispose();
        });
        var collapsed = false;
        var backgroundEvents = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) => backgroundEvents++,
                      onPointerMove: (_) => backgroundEvents++,
                      onPointerSignal: (_) => backgroundEvents++,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DesktopMainNavigation(
                        i18n: i18n,
                        overlaySessions: const [],
                        destinations: destinations,
                        isMenuCollapsed: collapsed,
                        activePageIndex: activePage,
                        menuIconKeys: iconKeys,
                        menuIconLinks: List.generate(
                          MainDestinationType.values.length,
                          (_) => LayerLink(),
                        ),
                        collapseOffset: (_, _) => Offset.zero,
                        onSwitchPage: (index) => activePage.value = index,
                        onToggleMenu: () =>
                            setState(() => collapsed = !collapsed),
                        playbackGeometryKey: GlobalKey(),
                        onReportPlaybackRect:
                            ({
                              required dockCollapsed,
                              required dockAreaWidth,
                              required expandedDockWidth,
                            }) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.playlist_play_rounded), findsOneWidget);
        double indicatorScale(int index) => tester
            .widget<Transform>(
              find.descendant(
                of: find.byKey(
                  ValueKey<String>(
                    'main_destination_indicator_${destinations[index].navigationKey}',
                  ),
                ),
                matching: find.byType(Transform),
              ),
            )
            .transform
            .entry(0, 0);
        expect(
          tester.widget<Icon>(find.byIcon(Icons.playlist_play_rounded)).size,
          closeTo(24.15, 0.001),
        );
        for (var state = 0; state < 2; state++) {
          final bounds = tester.getRect(find.byType(DesktopMainNavigation));
          final point = bounds.bottomLeft + const Offset(1, -1);
          final previousEvents = backgroundEvents;
          await tester.tapAt(point);
          await tester.longPressAt(point);
          await tester.tapAt(point, buttons: kSecondaryMouseButton);
          await tester.dragFrom(point, const Offset(0, -80));
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: point,
              scrollDelta: const Offset(0, 60),
            ),
          );
          expect(backgroundEvents, previousEvents);
          await tester.tapAt(Offset(bounds.right + 1, bounds.center.dy));
          expect(backgroundEvents, previousEvents + 1);
          await tester.tapAt(
            tester.getCenter(
              find.byKey(iconKeys[destinations[state + 1].type.index]),
            ),
          );
          await tester.pump();
          expect(indicatorScale(state + 1), 0);
          await tester.pump(const Duration(milliseconds: 150));
          expect(indicatorScale(state + 1), inExclusiveRange(0, 1));
          await tester.pump(const Duration(milliseconds: 149));
          expect(indicatorScale(state + 1), lessThan(1));
          await tester.pump(const Duration(milliseconds: 1));
          expect(indicatorScale(state + 1), 1);
          await tester.pumpAndSettle();
          expect(activePage.value, state + 1);
          if (!collapsed) {
            await tester.tap(find.byIcon(Icons.menu_open_rounded));
            await tester.pumpAndSettle();
          }
        }
        expect(
          tester.widget<Icon>(find.byIcon(Icons.playlist_play_rounded)).size,
          closeTo(25.3, 0.001),
        );
        activePage.value = 0;
        await tester.pump();
        expect(indicatorScale(0), 0);
        await tester.pump(const Duration(milliseconds: 100));
        activePage.value = 1;
        await tester.pump();
        expect(indicatorScale(1), 0);
        await tester.pump(const Duration(milliseconds: 300));
        expect(indicatorScale(1), 1);
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pump();
        activePage.value = 0;
        await tester.pump();
        expect(indicatorScale(0), 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'landscape rail motion leaves ${platform.name} content constraints stable',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await AppPreferences.init();
        final i18n = AppLanguageProvider();
        final activePage = ValueNotifier(0);
        final iconKeys = List.generate(
          MainDestinationType.values.length,
          (_) => GlobalKey(),
        );
        final iconLinks = List.generate(
          MainDestinationType.values.length,
          (_) => LayerLink(),
        );
        final destinations = resolveMainDestinations(
          showLocalLibrary: true,
          showAsmrOne: true,
        );
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          i18n.dispose();
          activePage.dispose();
        });
        var collapsed = false;
        var contentLayouts = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Row(
                  children: [
                    RepaintBoundary(
                      key: const ValueKey('sidebar_capture'),
                      child: DesktopMainNavigation(
                        i18n: i18n,
                        overlaySessions: const [],
                        destinations: destinations,
                        isMenuCollapsed: collapsed,
                        activePageIndex: activePage,
                        menuIconKeys: iconKeys,
                        menuIconLinks: iconLinks,
                        collapseOffset: (_, _) => Offset.zero,
                        onSwitchPage: (index) => activePage.value = index,
                        onToggleMenu: () => setState(() {
                          collapsed = !collapsed;
                        }),
                        playbackGeometryKey: GlobalKey(),
                        onReportPlaybackRect:
                            ({
                              required dockCollapsed,
                              required dockAreaWidth,
                              required expandedDockWidth,
                            }) {},
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          contentLayouts++;
                          return const ColoredBox(
                            key: ValueKey('content'),
                            color: Colors.white,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final target = find.byKey(iconKeys[MainDestinationType.library.index]);
        final toggle = find.widgetWithIcon(IconButton, Icons.menu_open_rounded);
        expect(tester.getSize(target), tester.getSize(toggle));
        Future<void> expectSidebarBackgroundAtEdges() async {
          final colors = (await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('sidebar_capture')),
            );
            final image = await boundary.toImage();
            final bytes = (await image.toByteData())!;
            Color pixel(int x, int y) {
              final offset = (y * image.width + x) * 4;
              return Color.fromARGB(
                bytes.getUint8(offset + 3),
                bytes.getUint8(offset),
                bytes.getUint8(offset + 1),
                bytes.getUint8(offset + 2),
              );
            }

            final result = [
              pixel(2, 2),
              pixel(image.width - 3, 2),
              pixel(2, image.height - 3),
              pixel(image.width - 3, image.height - 3),
              pixel(image.width ~/ 2, 0),
              pixel(image.width ~/ 2, image.height - 1),
              pixel(0, image.height ~/ 2),
              pixel(image.width - 1, image.height ~/ 2),
            ];
            image.dispose();
            return result;
          }))!;
          final theme = Theme.of(tester.element(target));
          final background = theme.colorScheme.surfaceContainerLow;
          expect(colors, everyElement(background));
        }

        await expectSidebarBackgroundAtEdges();
        final center = tester.getCenter(target);
        final railBounds = tester.getRect(find.byType(NavigationRail));
        final capsule = Rect.fromLTRB(
          center.dx - 24,
          center.dy - 24,
          railBounds.right - 8,
          center.dy + 24,
        );
        final samples = [
          Offset(capsule.left + 8, capsule.center.dy),
          Offset(capsule.right - 8, capsule.center.dy),
          capsule.topLeft + const Offset(2, 2),
          capsule.topRight + const Offset(-2, 2),
        ];
        Future<List<int>> capsulePixels() async =>
            (await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('sidebar_capture')),
              );
              final image = await boundary.toImage();
              final data = (await image.toByteData())!;
              final pixels = samples.map((point) {
                final local = boundary.globalToLocal(point);
                return data.getUint32(
                  (local.dy.floor() * image.width + local.dx.floor()) * 4,
                );
              }).toList();
              image.dispose();
              return pixels;
            }))!;
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: const Offset(1000, 400));
        await tester.pumpAndSettle();
        final idlePixels = await capsulePixels();
        void expectCapsule(List<int> pixels) {
          expect(pixels[0], isNot(idlePixels[0]));
          expect(pixels[1], isNot(idlePixels[1]));
          expect(pixels.skip(2), idlePixels.skip(2));
        }

        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        final labelFinder = find.byWidget(rail.destinations[1].label);
        Color? labelColor() => tester
            .widget<RichText>(
              find.descendant(of: labelFinder, matching: find.byType(RichText)),
            )
            .text
            .style
            ?.color;
        final idleLabelColor = labelColor();
        final labelRect = tester.getRect(labelFinder);
        final primary = Theme.of(
          tester.element(find.byType(DesktopMainNavigation)),
        ).colorScheme.primary;
        expect(idleLabelColor, isNot(primary));
        await mouse.moveTo(tester.getCenter(labelFinder));
        await tester.pumpAndSettle();
        expect(
          labelColor(),
          platform == TargetPlatform.windows ? primary : idleLabelColor,
        );
        expect(tester.getRect(labelFinder), labelRect);
        expect(activePage.value, 0);
        expectCapsule(await capsulePixels());
        await mouse.down(
          tester.getCenter(find.byWidget(rail.destinations[1].label)),
        );
        await tester.pumpAndSettle();
        expectCapsule(await capsulePixels());
        expect(activePage.value, 0);
        await mouse.cancel();
        await tester.pumpAndSettle();
        await mouse.moveTo(center);
        await tester.pumpAndSettle();
        expect(labelColor(), idleLabelColor);
        expectCapsule(await capsulePixels());
        await mouse.down(center);
        await tester.pumpAndSettle();
        expectCapsule(await capsulePixels());
        await mouse.cancel();
        await tester.pumpAndSettle();
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(await capsulePixels(), idlePixels);
        for (final offset in [
          const Offset(25, 0),
          const Offset(-25, 0),
          const Offset(0, 25),
          const Offset(0, -25),
        ]) {
          await tester.tapAt(center + offset);
          await tester.pumpAndSettle();
          expect(activePage.value, 0);
        }
        await tester.tapAt(center + const Offset(23, 23));
        await tester.pumpAndSettle();
        expect(activePage.value, 1);
        expectCapsule(await capsulePixels());

        final toggleCenter = tester.getCenter(toggle);
        final destinationIcons = destinations
            .map(
              (destination) => find.byKey(
                ValueKey<String>(
                  'main_destination_${destination.navigationKey}',
                ),
              ),
            )
            .toList();
        final iconCenters = destinationIcons.map(tester.getCenter).toList();
        final selectedIndicator = find.byKey(
          ValueKey<String>(
            'main_destination_indicator_${destinations[1].navigationKey}',
          ),
        );
        for (final icon in [Icons.menu_open_rounded, Icons.menu_rounded]) {
          await tester.tap(find.byIcon(icon));
          await tester.pump();
          expect(destinationIcons.map(tester.getCenter), iconCenters);
          expect(tester.getSize(selectedIndicator).width, collapsed ? 228 : 48);
          final transitionLayouts = contentLayouts;
          final contentWidth = tester
              .getSize(find.byKey(const ValueKey('content')))
              .width;
          expect(contentWidth, collapsed ? 1200 : 1020);
          expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
          var previousWidth = tester.getSize(selectedIndicator).width;
          for (final step in [1, 15, 30, 30, 30, 30, 30]) {
            await tester.pump(Duration(milliseconds: step));
            expect(destinationIcons.map(tester.getCenter), iconCenters);
            final indicator = tester.getRect(selectedIndicator);
            expect(indicator.left, center.dx - 24);
            expect(indicator.height, 48);
            expect(
              indicator.width,
              collapsed ? lessThan(previousWidth) : greaterThan(previousWidth),
            );
            previousWidth = indicator.width;
            expect(
              tester.getCenter(
                find.widgetWithIcon(
                  IconButton,
                  collapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
                ),
              ),
              toggleCenter,
            );
            expect(contentLayouts, transitionLayouts);
            expect(
              tester.getSize(find.byKey(const ValueKey('content'))).width,
              contentWidth,
            );
          }
          await tester.pumpAndSettle();
          expect(
            tester.getSize(selectedIndicator),
            Size(collapsed ? 48 : 228, 48),
          );
          await expectSidebarBackgroundAtEdges();
          final otherTarget = find.byKey(
            iconKeys[MainDestinationType.settings.index],
          );
          final otherCenter = tester.getCenter(otherTarget);
          for (final offset in [
            const Offset(25, 0),
            const Offset(-25, 0),
            const Offset(0, 25),
            const Offset(0, -25),
          ]) {
            await tester.tapAt(otherCenter + offset);
            await tester.pumpAndSettle();
            expect(activePage.value, 1);
          }
          if (!collapsed) {
            final rail = tester.widget<NavigationRail>(
              find.byType(NavigationRail),
            );
            await tester.tap(find.byWidget(rail.destinations.last.label));
            await tester.pumpAndSettle();
            expect(activePage.value, destinations.length - 1);
            activePage.value = 1;
            await tester.pumpAndSettle();
          }
          final nextToggle = find.widgetWithIcon(
            IconButton,
            collapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
          );
          expect(destinationIcons.map(tester.getCenter), iconCenters);
          expect(tester.getCenter(nextToggle), toggleCenter);
          expect(tester.getSize(target), tester.getSize(nextToggle));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
