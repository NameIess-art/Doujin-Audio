import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'header mask stretches immediately in both directions without fading',
    (tester) async {
      late StateSetter update;
      var tall = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: AppHeaderTransition(
                      child: SizedBox(
                        key: ValueKey(tall),
                        height: tall ? 88 : 44,
                        child: const ColoredBox(color: Colors.blue),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      final mask = find.byType(AppEdgeFadeMask);
      final maskElement = tester.element(mask);
      expect(tester.getSize(mask).height, 44);
      update(() => tall = true);
      await tester.pump();
      expect(tester.getSize(mask).height, 44);
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getSize(mask).height, inExclusiveRange(44, 88));
      await tester.pumpAndSettle();
      expect(tester.getSize(mask).height, 88);
      update(() => tall = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getSize(mask).height, inExclusiveRange(44, 88));
      final reversingHeight = tester.getSize(mask).height;
      update(() => tall = true);
      await tester.pump();
      expect(tester.getSize(mask).height, closeTo(reversingHeight, 1e-6));
      await tester.pumpAndSettle();
      expect(tester.getSize(mask).height, 88);
      update(() => tall = false);
      await tester.pumpAndSettle();
      expect(tester.getSize(mask).height, 44);
      expect(tester.element(mask), same(maskElement));
      final fades = find.descendant(
        of: find.byType(AppHeaderTransition),
        matching: find.byType(FadeTransition),
      );
      expect(find.ancestor(of: mask, matching: fades), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'selection header fades for 300ms with an unfaded mask (reduced: $reducedMotion)',
      (tester) async {
        late StateSetter update;
        var selecting = false;
        var normalBuilds = 0;
        var selectionBuilds = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  final selected = selecting;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: AppHeaderTransition(
                      child: TopPageHeader(
                        key: ValueKey(selected),
                        useSafeAreaTop: false,
                        topCapsuleTitle: selected ? 'Selected 1' : 'Library',
                        titleWidget: Builder(
                          builder: (_) {
                            if (selected) {
                              selectionBuilds++;
                            } else {
                              normalBuilds++;
                            }
                            return Text(selected ? 'Batch actions' : 'Browse');
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        final mask = find.byType(AppEdgeFadeMask);
        expect(mask, findsOneWidget);
        final maskElement = tester.element(mask);
        update(() => selecting = true);
        await tester.pump();
        if (!reducedMotion) {
          final builds = (normalBuilds, selectionBuilds);
          await tester.pump(const Duration(milliseconds: 150));
          final fades = find.descendant(
            of: find.byType(AppHeaderTransition),
            matching: find.byWidgetPredicate((widget) => widget is FadeTransition),
          );
          expect(fades, findsNWidgets(2));
          for (final fade in tester.widgetList<FadeTransition>(fades)) {
            expect(
              fade.opacity.value,
              closeTo(kAppFadeCurve.transform(0.5), 0.001),
            );
          }
          expect((normalBuilds, selectionBuilds), builds);
          expect(mask, findsOneWidget);
          expect(find.ancestor(of: mask, matching: fades), findsNothing);
          await tester.pump(const Duration(milliseconds: 150));
        }
        await tester.pump(const Duration(milliseconds: 1));
        expect(find.text('Browse'), findsNothing);
        expect(find.text('Batch actions'), findsOneWidget);
        expect(mask, findsOneWidget);
        // Reverse before the previous outgoing entry has finished.
        update(() => selecting = false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        if (!reducedMotion) {
          expect(mask, findsOneWidget);
          expect(tester.element(mask), same(maskElement));
        }
        update(() => selecting = true);
        await tester.pumpAndSettle();
        expect(mask, findsOneWidget);
        expect(find.byType(TopPageHeader), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('header boundary enables glass without changing body capsules', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TopPageHeader(
                title: 'Header',
                useSafeAreaTop: false,
                leading: HeaderFloatingButton(
                  key: const ValueKey('transparent-header'),
                  backgroundOpacity: 0,
                  child: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.add),
                  ),
                ),
                trailing: HeaderFloatingButton(
                  key: const ValueKey('partial-header'),
                  backgroundOpacity: 0.5,
                  child: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
              const HeaderFloatingSurface(
                key: ValueKey('body-capsule'),
                child: Text('Body'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(AppGlassSurface), findsNWidgets(3));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('body-capsule')),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(
      tester.widget<BackdropFilter>(find.descendant(
        of: find.byKey(const ValueKey('transparent-header')),
        matching: find.byType(BackdropFilter),
      )).enabled,
      isFalse,
    );
    expect(
      tester.widget<AppGlassSurface>(find.descendant(
        of: find.byKey(const ValueKey('partial-header')),
        matching: find.byType(AppGlassSurface),
      )).backgroundColor.a,
      0.45,
    );
  });

  testWidgets('full-width title bar owns a single bounded glass surface', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(appBar: AppPageAppBar(title: Text('Title'))),
    ));
    expect(find.byType(BackdropFilter), findsOneWidget);
    final glass = find.byType(AppGlassSurface);
    expect(
      tester.getSize(glass).height,
      tester.getSize(find.byType(AppBar)).height,
    );
    expect(tester.getSize(glass).height, lessThan(100));
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.elevation, 0);
    expect(appBar.scrolledUnderElevation, 0);
  });

  testWidgets('header safe area and margins block input behind its controls', (
    tester,
  ) async {
    var bodyTaps = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(top: 24),
          ),
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => bodyTaps++,
                  child: const SizedBox.expand(),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: TopPageHeader(
                    title: 'Title',
                    leading: IconButton(
                      key: const ValueKey('header-back'),
                      onPressed: () => buttonTaps++,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(TopPageHeader));
    for (final point in [
      const Offset(4, 8),
      Offset(rect.right - 2, rect.center.dy),
      Offset(rect.center.dx, rect.bottom - 1),
    ]) {
      await tester.tapAt(point);
    }
    expect(bodyTaps, 0);
    await tester.tap(find.byKey(const ValueKey('header-back')));
    expect(buttonTaps, 1);
    await tester.tapAt(Offset(rect.center.dx, rect.bottom + 10));
    expect(bodyTaps, 1);
  });

  testWidgets(
    'scrolling rebuilds only changing header geometry',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      const additionalChild = SizedBox(key: ValueKey('header-extra'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ListView.builder(
                  controller: controller,
                  itemExtent: 80,
                  itemCount: 100,
                  itemBuilder: (_, index) => Text('item $index'),
                ),
                TopPageHeader(
                  topCapsuleTitle: 'Library',
                  title: 'Actions',
                  collapseController: controller,
                  floatingReveal: true,
                  additionalChild: additionalChild,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final expandedHeight = tester.getSize(find.byType(TopPageHeader)).height;
      final headerFilters = find.descendant(
        of: find.byType(TopPageHeader),
        matching: find.byType(BackdropFilter),
      );
      final topFilter = tester.renderObject<RenderBackdropFilter>(
        find.descendant(
          of: find.byType(HeaderTopCapsule),
          matching: find.byType(BackdropFilter),
        ),
      );
      final rowFilter = tester.renderObject<RenderBackdropFilter>(
        headerFilters.last,
      );
      final rowKey = rowFilter.backdropKey;
      expect(rowKey, isNotNull);
      expect(topFilter.backdropKey, isNot(rowKey));
      final geometryElement = tester.element(
        find.byWidgetPredicate(
          (widget) =>
              widget is AnimatedBuilder && widget.child == additionalChild,
        ),
      );
      var geometryBuilds = 0;
      var capsuleBuilds = 0;
      final previousCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousCallback?.call(element, builtOnce);
        if (element == geometryElement) geometryBuilds++;
        if (element.widget is HeaderTopCapsule) capsuleBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousCallback);

      for (var offset = 8.0; offset <= 80; offset += 8) {
        controller.jumpTo(offset);
        await tester.pump();
        expect(rowFilter.backdropKey, same(rowKey));
        expect(topFilter.backdropKey, isNot(rowKey));
      }
      expect(geometryBuilds, greaterThan(0));
      expect(capsuleBuilds, 0);
      final collapsedHeight = tester.getSize(find.byType(TopPageHeader)).height;
      expect(collapsedHeight, lessThan(expandedHeight));

      geometryBuilds = 0;
      for (var offset = 100.0; offset <= 500; offset += 20) {
        controller.jumpTo(offset);
        await tester.pump();
      }
      expect(geometryBuilds, 0);
      expect(
        tester.getSize(find.byType(TopPageHeader)).height,
        collapsedHeight,
      );

      // Reversing first crosses the reveal threshold, then expands the header.
      controller.jumpTo(380);
      await tester.pump();
      expect(geometryBuilds, 0);
      controller.jumpTo(310);
      await tester.pump();
      expect(tester.getSize(find.byType(TopPageHeader)).height, expandedHeight);
      expect(capsuleBuilds, 0);
      controller.jumpTo(0);
      await tester.pump();
      expect(tester.getSize(find.byType(TopPageHeader)).height, expandedHeight);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  Widget header({required int trailingButtons, int actionButtons = 4}) {
    return MaterialApp(
      home: Scaffold(
        body: TopPageHeader(
          topCapsuleTitle: 'Library',
          titleWidget: HeaderActionPill(
            children: List.generate(
              actionButtons,
              (index) => IconButton(
                key: ValueKey('action_$index'),
                onPressed: () {},
                icon: const Icon(Icons.add),
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: HeaderActionPill.buttonConstraints,
              ),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < trailingButtons; index++) ...[
                if (index != 0) const SizedBox(width: 8),
                HeaderFloatingButton(
                  child: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.search),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('portrait action pill keeps original button spacing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(header(trailingButtons: 2));

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const ValueKey('action_0'))).width, 48);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('action_1'))).dx -
          tester.getTopLeft(find.byKey(const ValueKey('action_0'))).dx,
      48,
    );
  });

  for (final width in [320.0, 349.0]) {
    testWidgets('action pill fits $width wide content and restores spacing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(header(trailingButtons: 3));

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('action_0'))).width,
        inExclusiveRange(28, 48),
      );
      final lastAction = tester.getRect(find.byKey(const ValueKey('action_3')));
      final firstTrailing = tester.getRect(
        find.byType(HeaderFloatingButton).first,
      );
      expect(lastAction.right, lessThan(firstTrailing.left));
      expect(firstTrailing.left - lastAction.right, closeTo(12, 0.01));

      await tester.binding.setSurfaceSize(const Size(510, 600));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey('action_0'))).width, 48);
    });
  }

  testWidgets(
    'split library action pill uses the space before trailing buttons',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(349.5, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(header(trailingButtons: 4, actionButtons: 3));

      expect(tester.takeException(), isNull);
      final first = tester.getRect(find.byKey(const ValueKey('action_0')));
      final second = tester.getRect(find.byKey(const ValueKey('action_1')));
      final last = tester.getRect(find.byKey(const ValueKey('action_2')));
      final trailing = tester.getRect(find.byType(HeaderFloatingButton).first);
      expect(first.width, inExclusiveRange(28, 48));
      expect(second.width, closeTo(first.width, 0.01));
      expect(last.width, closeTo(first.width, 0.01));
      expect(second.left - first.left, closeTo(first.width, 0.01));
      expect(trailing.left - last.right, closeTo(12, 0.01));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
