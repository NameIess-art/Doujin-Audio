import 'dart:async';

import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entry_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  final coordinator = UiInteractionCoordinator.instance;
  setUp(coordinator.resetForTest);
  tearDown(coordinator.resetForTest);

  for (final brightness in Brightness.values) {
    testWidgets(
      'menus retain v0.29 row and icon styles ($brightness)',
      (tester) async {
        const entries = [
          UnifiedMenuEntry.action(
            value: 1,
            icon: Icons.folder,
            label: 'Styled action',
          ),
        ];
        final theme = ThemeData(brightness: brightness);
        for (final mode in ['add', 'button', 'context']) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Builder(
                  builder: (context) => mode == 'add'
                      ? UnifiedPopupMenuButton<int>(
                          icon: Icons.add,
                          tooltip: 'Open styled menu',
                          entries: entries,
                          onSelected: (_) {},
                        )
                      : TextButton(
                          onPressed: () {
                            if (mode == 'context') {
                              unawaited(
                                showUnifiedContextMenu<int>(
                                  context: context,
                                  globalPosition: const Offset(200, 100),
                                  entries: entries,
                                ),
                              );
                            } else {
                              unawaited(
                                showDockAwareMenu<int>(
                                  context: context,
                                  position: const RelativeRect.fromLTRB(
                                    200,
                                    100,
                                    200,
                                    100,
                                  ),
                                  entries: entries,
                                ),
                              );
                            }
                          },
                          child: const Text('Open styled menu'),
                        ),
                ),
              ),
            ),
          );
          await tester.tap(
            mode == 'add'
                ? find.byTooltip('Open styled menu')
                : find.text('Open styled menu'),
          );
          await tester.pumpAndSettle();
          final label = find.text('Styled action');
          final row = find
              .ancestor(of: label, matching: find.byType(InkWell))
              .first;
          final iconTheme = IconTheme.of(
            tester.element(find.byIcon(Icons.folder)),
          );
          final textStyle = tester.widget<Text>(label).style;
          expect(tester.getSize(row).height, mode == 'add' ? 48 : 40);
          expect(
            textStyle,
            Theme.of(tester.element(label)).textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          );
          expect(iconTheme.size, mode == 'add' ? 21 : 18);
          expect(
            iconTheme.color,
            mode == 'add'
                ? theme.colorScheme.onSurface
                : theme.colorScheme.primary,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(label, findsNothing);
          expect(tester.takeException(), isNull);
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final dockMenu in [false, true]) {
    testWidgets(
      'outgoing menu excludes focus and semantics (dock: $dockMenu)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => dockMenu
                    ? TextButton(
                        onPressed: () async {
                          final result = await showDockAwareMenu<int>(
                            context: context,
                            position: const RelativeRect.fromLTRB(
                              10,
                              10,
                              10,
                              10,
                            ),
                            entries: const [
                              UnifiedMenuEntry.action(
                                value: 1,
                                label: 'Closing action',
                              ),
                            ],
                          );
                          if (result != null) selected++;
                        },
                        child: const Text('Open menu'),
                      )
                    : UnifiedPopupMenuButton<int>(
                        icon: Icons.more_vert,
                        tooltip: 'Open menu',
                        entries: const [
                          UnifiedMenuEntry.action(
                            value: 1,
                            label: 'Closing action',
                          ),
                        ],
                        onSelected: (_) => selected++,
                      ),
              ),
            ),
          ),
        );
        await tester.tap(
          dockMenu ? find.text('Open menu') : find.byTooltip('Open menu'),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('Closing action'), findsOneWidget);
        expect(find.semantics.byLabel('Closing action'), findsNothing);
        final action = find
            .ancestor(
              of: find.text('Closing action'),
              matching: find.byType(InkWell),
            )
            .first;
        expect(Focus.of(tester.element(action)).hasFocus, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, 0);
        expect(find.text('Closing action'), findsNothing);
        semantics.dispose();
      },
    );
  }

  testWidgets('external menu replacement waits for the full fade out', (
    tester,
  ) async {
    final dismiss = ValueNotifier<VoidCallback?>(null);
    addTearDown(dismiss.dispose);
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileOverlayInset(
            bottomInset: 0,
            menuDismiss: dismiss,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showDockAwareMenu<int>(
                    context: context,
                    position: const RelativeRect.fromLTRB(10, 10, 10, 10),
                    entries: const [
                      UnifiedMenuEntry.action(value: 1, label: 'Fading action'),
                    ],
                  );
                  completed = true;
                },
                child: const Text('Open fading menu'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open fading menu'));
    await tester.pumpAndSettle();
    dismiss.value!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Fading action'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Fading action'), findsNothing);
    expect(completed, isTrue);
  });

  for (final localOverlay in [false, true]) {
    testWidgets(
      'context menu starts without row focus and supports hover and keyboard (local: $localOverlay)',
      (tester) async {
        final overlayKey = GlobalKey<OverlayState>();
        int? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: MobileOverlayInset(
                bottomInset: 0,
                menuOverlayKey: localOverlay ? overlayKey : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Builder(
                      builder: (context) => GestureDetector(
                        onSecondaryTapDown: (event) async {
                          selected = await showUnifiedContextMenu<int>(
                            context: context,
                            globalPosition: event.globalPosition,
                            entries: const [
                              UnifiedMenuEntry.action(value: 1, label: 'First'),
                              UnifiedMenuEntry.action(
                                value: 2,
                                label: 'Second',
                              ),
                            ],
                          );
                        },
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                    if (localOverlay) Overlay(key: overlayKey),
                  ],
                ),
              ),
            ),
          ),
        );
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(200, 200));
        await mouse.down(const Offset(200, 200));
        await mouse.up();
        await tester.pumpAndSettle();
        final first = find.text('First');
        final second = find.text('Second');
        expect(Focus.of(tester.element(first)).hasFocus, isFalse);
        expect(Focus.of(tester.element(second)).hasFocus, isFalse);
        final dynamic material = Material.of(tester.element(first));
        expect(material.debugInkFeatures, anyOf(isNull, isEmpty));

        await mouse.moveTo(tester.getCenter(first));
        await tester.pumpAndSettle();
        expect(material.debugInkFeatures, isNotEmpty);
        await mouse.moveTo(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(material.debugInkFeatures, anyOf(isNull, isEmpty));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(first)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(second)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(first)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, 1);
        expect(first, findsNothing);

        await mouse.moveTo(const Offset(200, 200));
        await mouse.down(const Offset(200, 200));
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(selected, isNull);
        expect(first, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [190.0, 360.0]) {
    for (final contextMenu in [false, true]) {
      testWidgets(
        '${contextMenu ? 'context' : 'button'} menu stays within a $width pane',
        (tester) async {
          final overlayKey = GlobalKey<OverlayState>();
          final menuDismiss = ValueNotifier<VoidCallback?>(null);
          addTearDown(menuDismiss.dispose);
          int? selected;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 80),
                    child: SizedBox(
                      key: const ValueKey('menu_region'),
                      width: width,
                      height: 360,
                      child: MobileOverlayInset(
                        bottomInset: 0,
                        menuOverlayKey: overlayKey,
                        menuDismiss: menuDismiss,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Align(
                              alignment: Alignment.topRight,
                              child: Builder(
                                builder: (context) => contextMenu
                                    ? TextButton(
                                        onPressed: () async {
                                          final box =
                                              context.findRenderObject()!
                                                  as RenderBox;
                                          selected =
                                              await showUnifiedContextMenu<int>(
                                                context: context,
                                                globalPosition: box
                                                    .localToGlobal(
                                                      Offset(
                                                        box.size.width - 10,
                                                        24,
                                                      ),
                                                    ),
                                                entries: const [
                                                  UnifiedMenuEntry.action(
                                                    value: 1,
                                                    label: 'Action',
                                                  ),
                                                ],
                                              );
                                        },
                                        child: const Text('Menu'),
                                      )
                                    : UnifiedPopupMenuButton<int>(
                                        icon: Icons.more_vert,
                                        tooltip: 'Menu',
                                        entries: const [
                                          UnifiedMenuEntry.action(
                                            value: 1,
                                            label: 'Action',
                                          ),
                                        ],
                                        onSelected: (value) => selected = value,
                                      ),
                              ),
                            ),
                            Overlay(key: overlayKey),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(
            contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
          );
          await tester.pumpAndSettle();
          final region = tester.getRect(
            find.byKey(const ValueKey('menu_region')),
          );
          final menu = tester.getRect(
            find
                .ancestor(
                  of: find.text('Action'),
                  matching: find.byType(ClipRRect),
                )
                .first,
          );
          expect(menu.left, greaterThanOrEqualTo(region.left));
          expect(menu.right, lessThanOrEqualTo(region.right));
          expect(menu.top, greaterThanOrEqualTo(region.top));
          expect(menu.bottom, lessThanOrEqualTo(region.bottom));
          expect(menuDismiss.value, isNotNull);
          await tester.tap(find.text('Action'));
          await tester.pumpAndSettle();
          expect(selected, 1);
          expect(menuDismiss.value, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final contextMenu in [false, true]) {
    testWidgets(
      'Android back closes ${contextMenu ? 'context' : 'button'} menu before detail',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final root = GlobalKey<NavigatorState>();
        final navigation = WorkDetailNavigation(rootNavigatorKey: root);
        final mainMenuOverlay = GlobalKey<OverlayState>();
        addTearDown(navigation.dispose);
        await tester.pumpWidget(
          fixture.build(
            WorkDetailNavigationScope(
              navigation: navigation,
              child: MaterialApp(
                navigatorKey: root,
                home: Scaffold(
                  body: WorkDetailPane(
                    isLandscape: true,
                    sidebarWidth: 80,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 340,
                        child: MobileOverlayInset(
                          bottomInset: 0,
                          menuOverlayKey: mainMenuOverlay,
                          menuDismiss: navigation.menuDismiss,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Main retained'),
                                    Builder(
                                      builder: (context) => TextButton(
                                        onPressed: () => unawaited(
                                          showDockAwareMenu<int>(
                                            context: context,
                                            position:
                                                const RelativeRect.fromLTRB(
                                                  50,
                                                  150,
                                                  50,
                                                  150,
                                                ),
                                            entries: const [
                                              UnifiedMenuEntry.action(
                                                value: 2,
                                                label: 'Main action',
                                              ),
                                            ],
                                          ),
                                        ),
                                        child: const Text('Main menu'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Overlay(key: mainMenuOverlay),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(
          navigation.open(
            'detail',
            (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Text('Detail retained'),
                    contextMenu
                        ? TextButton(
                            onPressed: () {
                              final box =
                                  context.findRenderObject()! as RenderBox;
                              unawaited(
                                showUnifiedContextMenu<int>(
                                  context: context,
                                  globalPosition: box.localToGlobal(
                                    const Offset(100, 100),
                                  ),
                                  entries: const [
                                    UnifiedMenuEntry.action(
                                      value: 1,
                                      label: 'Action',
                                    ),
                                  ],
                                ),
                              );
                            },
                            child: const Text('Menu'),
                          )
                        : UnifiedPopupMenuButton<int>(
                            icon: Icons.more_vert,
                            tooltip: 'Menu',
                            entries: const [
                              UnifiedMenuEntry.action(
                                value: 1,
                                label: 'Action',
                              ),
                            ],
                            onSelected: (_) {},
                          ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
        );
        await tester.pumpAndSettle();
        expect(navigation.menuDismiss.value, isNotNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsNothing);
        expect(find.text('Detail retained'), findsOneWidget);
        expect(navigation.isOpen, isTrue);
        expect(navigation.menuDismiss.value, isNull);
        await tester.tap(
          contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
        );
        await tester.pumpAndSettle();
        final previousDismiss = navigation.menuDismiss.value;
        await tester.tap(find.text('Main menu'));
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsNothing);
        expect(find.text('Main action'), findsOneWidget);
        expect(navigation.menuDismiss.value, isNotNull);
        expect(
          identical(navigation.menuDismiss.value, previousDismiss),
          isFalse,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Main action'), findsNothing);
        expect(navigation.isOpen, isTrue);
        expect(navigation.menuDismiss.value, isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(navigation.isOpen, isFalse);
        expect(find.text('Main retained'), findsOneWidget);
        await tester.pump(coordinator.idleDelay);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('popup releases curve listeners after each dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedPopupMenuButton<int>(
            icon: Icons.more_vert,
            tooltip: 'Menu',
            entries: const [UnifiedMenuEntry.action(value: 1, label: 'Action')],
            onSelected: (_) {},
          ),
        ),
      ),
    );
    for (var opening = 0; opening < 3; opening++) {
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('Action'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      final curve = fade.opacity as CurvedAnimation;
      expect(curve.isDisposed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Action'), findsNothing);
      expect(curve.isDisposed, isTrue);
    }
    await tester.pump(coordinator.idleDelay);
    expect(coordinator.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final stage in ['enter', 'open', 'exit']) {
    testWidgets('removing work entry during menu $stage clears root overlay', (
      tester,
    ) async {
      var visible = true;
      var actions = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return visible
                    ? WorkDetailEntryTile(
                        item: const WorkEntryItem(
                          name: 'Track',
                          relativePath: 'Track.mp3',
                          type: WorkEntryType.audio,
                        ),
                        accentColor: Colors.blue,
                        moreLabel: 'Menu',
                        unknownSizeLabel: 'Size unknown',
                        menuEntries: const [
                          UnifiedMenuEntry.action(
                            value: WorkEntryAction.play,
                            label: 'Play',
                          ),
                        ],
                        onAction: (_) => actions++,
                      )
                    : const Text('Directory replaced');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Menu'));
      await tester.pump();
      if (stage != 'enter') await tester.pumpAndSettle();
      if (stage == 'exit') {
        await tester.tap(find.text('Play'));
        await tester.pump(const Duration(milliseconds: 40));
      }
      update(() => visible = false);
      await tester.pump();
      await tester.pump();
      expect(find.text('Play'), findsNothing);
      expect(find.text('Directory replaced'), findsOneWidget);
      expect(actions, 0);
      expect(coordinator.isInteracting, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final closing in [false, true]) {
    for (final change in ['hidden', 'reduced', 'disabled']) {
      testWidgets(
        'popup $change during ${closing ? 'exit' : 'enter'} clears protection',
        (tester) async {
          var visible = true;
          var reduced = false;
          var enabled = true;
          late StateSetter update;
          await tester.pumpWidget(
            MaterialApp(
              home: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return TickerMode(
                    enabled: visible,
                    child: MediaQuery(
                      data: MediaQueryData(disableAnimations: reduced),
                      child: Scaffold(
                        body: UnifiedPopupMenuButton<int>(
                          icon: Icons.more_vert,
                          tooltip: 'Menu',
                          enabled: enabled,
                          entries: const [
                            UnifiedMenuEntry.action(value: 1, label: 'Action'),
                          ],
                          onSelected: (_) {},
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.tap(find.byTooltip('Menu'));
          await tester.pump();
          if (closing) {
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
          }
          expect(coordinator.isInteracting, isTrue);
          update(() {
            visible = change != 'hidden';
            reduced = change == 'reduced';
            enabled = change != 'disabled';
          });
          await tester.pump();
          await tester.pump();
          expect(coordinator.isInteracting, isFalse);
          if (change == 'reduced' && !closing) {
            expect(find.text('Action'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
          }
          expect(find.text('Action'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final closing in [false, true]) {
    for (final change in ['hidden', 'reduced']) {
      testWidgets(
        'dock $change during ${closing ? 'exit' : 'enter'} clears protection',
        (tester) async {
          var visible = true;
          var reduced = false;
          late StateSetter update;
          Future<int?>? result;
          await tester.pumpWidget(
            MaterialApp(
              builder: (_, child) => StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return MediaQuery(
                    data: MediaQueryData(disableAnimations: reduced),
                    child: TickerMode(enabled: visible, child: child!),
                  );
                },
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      result = showDockAwareMenu<int>(
                        context: context,
                        position: const RelativeRect.fromLTRB(
                          100,
                          100,
                          100,
                          100,
                        ),
                        entries: const [
                          UnifiedMenuEntry.action(value: 1, label: 'Action'),
                        ],
                      );
                    },
                    child: const Text('Menu'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Menu'));
          await tester.pump();
          if (closing) {
            await tester.pumpAndSettle();
            await tester.tap(find.text('Action'));
            await tester.pump();
          }
          expect(coordinator.isInteracting, isTrue);
          update(() {
            visible = change != 'hidden';
            reduced = change == 'reduced';
          });
          await tester.pump();
          await tester.pump();
          expect(coordinator.isInteracting, isFalse);
          if (change == 'reduced' && !closing) {
            expect(find.text('Action'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
          }
          expect(await result, closing && change == 'reduced' ? 1 : isNull);
          expect(find.text('Action'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('dock menu captures theme with sibling playback overlay', (
    tester,
  ) async {
    final overlay = GlobalKey<OverlayState>();
    Future<int?>? result;
    const accent = Colors.teal;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileOverlayInset(
          bottomInset: 80,
          menuOverlayKey: overlay,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Theme(
                data: ThemeData(
                  colorScheme: ColorScheme.fromSeed(seedColor: accent),
                ),
                child: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () {
                        result = showDockAwareMenu<int>(
                          context: context,
                          position: const RelativeRect.fromLTRB(
                            100,
                            100,
                            100,
                            100,
                          ),
                          entries: const [
                            UnifiedMenuEntry.action(value: 1, label: 'Action'),
                          ],
                        );
                      },
                      child: const Text('Launch menu'),
                    ),
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 64,
                child: SizedBox(key: ValueKey('mock-playback-dock')),
              ),
              Overlay(key: overlay),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch menu'));
    await tester.pumpAndSettle();
    final menu = find.text('Action');
    expect(menu, findsOneWidget);
    expect(
      Theme.of(tester.element(menu)).colorScheme.primary,
      ColorScheme.fromSeed(seedColor: accent).primary,
    );
    final paintOrder = tester.allWidgets.toList();
    expect(
      paintOrder.indexOf(
        tester.widget(find.byKey(const ValueKey('mock-playback-dock'))),
      ),
      lessThan(paintOrder.indexOf(tester.widget(menu))),
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(await result, 1);
    expect(menu, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dockAware in [false, true]) {
    Future<void> pumpMenu(WidgetTester tester, {bool reduced = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  const entries = [
                    UnifiedMenuEntry<int>.action(value: 1, label: 'Action'),
                  ];
                  return dockAware
                      ? TextButton(
                          onPressed: () {
                            unawaited(
                              showDockAwareMenu<int>(
                                context: context,
                                position: const RelativeRect.fromLTRB(
                                  100,
                                  100,
                                  100,
                                  100,
                                ),
                                entries: entries,
                              ),
                            );
                          },
                          child: const Text('Menu'),
                        )
                      : UnifiedPopupMenuButton<int>(
                          icon: Icons.more_vert,
                          tooltip: 'Menu',
                          entries: entries,
                          onSelected: (_) {},
                        );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byTooltip('Menu').evaluate().isNotEmpty
            ? find.byTooltip('Menu')
            : find.text('Menu'),
      );
    }

    testWidgets(
      'async results wait through menu open and close (dock: $dockAware)',
      (tester) async {
        await pumpMenu(tester);
        expect(coordinator.isInteracting, isTrue);
        int? published;
        Future<void> completeResult(int value) async {
          final result = Completer<int>();
          final completion = result.future.then((value) {
            coordinator.scheduleCommit(
              key: 'menu-result',
              commit: () => published = value,
            );
          });
          result.complete(value);
          await completion;
        }

        await completeResult(1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(published, isNull);
        await tester.pumpAndSettle();
        await tester.pump(coordinator.idleDelay);
        await tester.pump();
        expect(published, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await completeResult(2);
        await completeResult(3);
        await tester.pump(const Duration(milliseconds: 50));
        expect(published, 1);
        expect(coordinator.isInteracting, isTrue);
        await tester.pumpAndSettle();
        await tester.pump(coordinator.idleDelay);
        await tester.pump();
        expect(published, 3);
        expect(coordinator.isInteracting, isFalse);
        expect(find.text('Action'), findsNothing);
      },
    );

    testWidgets('static open menu allows data commits (dock: $dockAware)', (
      tester,
    ) async {
      await pumpMenu(tester);
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
      expect(coordinator.isInteracting, isFalse);
      var committed = false;
      coordinator.scheduleCommit(
        key: 'static-menu',
        commit: () => committed = true,
      );
      await tester.pump();
      expect(committed, isTrue);
      expect(find.text('Action'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
    });

    testWidgets(
      'reduced menu opens and closes immediately (dock: $dockAware)',
      (tester) async {
        await pumpMenu(tester, reduced: true);
        await tester.pump();
        final fades = tester.widgetList<FadeTransition>(
          find.ancestor(
            of: find.text('Action'),
            matching: find.byType(FadeTransition),
          ),
        );
        expect(fades.every((fade) => fade.opacity.value == 1), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.text('Action'), findsNothing);
        await tester.pump(coordinator.idleDelay);
        expect(coordinator.isInteracting, isFalse);
      },
    );

    testWidgets(
      'host disposal during reverse releases menu (dock: $dockAware)',
      (tester) async {
        await pumpMenu(tester);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(coordinator.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final beforeLayout in [false, true]) {
    testWidgets(
      'dock menu follows route removal with root overlay retained (before layout: $beforeLayout)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        Future<int?>? result;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Root retained')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      result = showDockAwareMenu<int>(
                        context: context,
                        position: const RelativeRect.fromLTRB(
                          100,
                          100,
                          100,
                          100,
                        ),
                        entries: const [
                          UnifiedMenuEntry.action(value: 1, label: 'Action'),
                        ],
                      );
                    },
                    child: const Text('Launch menu'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Launch menu'));
        if (!beforeLayout) {
          await tester.pumpAndSettle();
          await tester.pump(coordinator.idleDelay);
          expect(find.text('Action'), findsOneWidget);
        }
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(await result, isNull);
        expect(find.text('Action'), findsNothing);
        expect(find.text('Root retained'), findsOneWidget);
        expect(coordinator.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('dock menu dismisses safely after launching context is removed', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    Future<int?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return visible
                  ? Builder(
                      builder: (context) => TextButton(
                        onPressed: () {
                          result = showDockAwareMenu<int>(
                            context: context,
                            position: const RelativeRect.fromLTRB(
                              100,
                              100,
                              100,
                              100,
                            ),
                            entries: const [
                              UnifiedMenuEntry.action(
                                value: 1,
                                label: 'Action',
                              ),
                            ],
                          );
                        },
                        child: const Text('Launch menu'),
                      ),
                    )
                  : const Text('Host retained');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch menu'));
    await tester.pumpAndSettle();
    update(() => visible = false);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('Action'), findsNothing);
    expect(coordinator.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing popup button during reverse clears its root overlay', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return visible
                  ? UnifiedPopupMenuButton<int>(
                      icon: Icons.more_vert,
                      tooltip: 'Menu',
                      entries: const [
                        UnifiedMenuEntry.action(value: 1, label: 'Action'),
                      ],
                      onSelected: (_) => selected++,
                    )
                  : const Text('Host retained');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pump(const Duration(milliseconds: 40));
    update(() => visible = false);
    await tester.pumpAndSettle();
    expect(find.text('Action'), findsNothing);
    expect(find.text('Host retained'), findsOneWidget);
    expect(selected, 0);
    expect(coordinator.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });
}
