import 'dart:async';

import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entry_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  final coordinator = UiInteractionCoordinator.instance;
  setUp(coordinator.resetForTest);
  tearDown(coordinator.resetForTest);

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
