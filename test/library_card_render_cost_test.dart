import 'dart:ui' show Tristate;

import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _lines = [
  LibraryLikeInfoLineData('Voice', 'Actor', icon: Icons.record_voice_over),
  LibraryLikeInfoLineData('Circle', 'Studio', icon: Icons.storefront),
  LibraryLikeInfoLineData('Tags', 'ASMR', icon: Icons.label),
  LibraryLikeInfoLineData(
    'Date',
    '2026-10-29',
    icon: Icons.event,
    isSecondary: true,
  ),
  LibraryLikeInfoLineData('Rating', '4.5', icon: Icons.star, isSecondary: true),
];

({int elements, int renderObjects, int states}) _countTree(Element root) {
  var elements = 0;
  var renderObjects = 0;
  var states = 0;
  void visit(Element element) {
    elements++;
    if (element is RenderObjectElement) renderObjects++;
    if (element is StatefulElement) states++;
    element.visitChildren(visit);
  }

  visit(root);
  return (elements: elements, renderObjects: renderObjects, states: states);
}

void main() {
  double scaleOf(WidgetTester tester, IconData icon) {
    final transforms = find.ancestor(
      of: find.byIcon(icon),
      matching: find.byType(Transform),
    );
    return tester
        .widgetList<Transform>(transforms)
        .firstWhere((widget) => !widget.transformHitTests)
        .transform
        .entry(0, 0);
  }

  testWidgets(
    'Windows card actions scale only their icon without pointer ink',
    (tester) async {
      final hoverColor = ValueNotifier(Colors.black26);
      addTearDown(hoverColor.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: hoverColor,
          builder: (context, color, child) => MaterialApp(
            theme: ThemeData(hoverColor: color),
            home: child,
          ),
          child: Material(
            child: Center(
              child: LibraryLikeCardActions(
                addLabel: 'Add',
                playLabel: 'Play',
                onAdd: () {},
                onPlay: () {},
              ),
            ),
          ),
        ),
      );
      final add = find.byTooltip('Add');
      final play = find.byTooltip('Play');
      final dynamic material = Material.of(tester.element(add));
      Iterable<InteractiveInkFeature> visibleInk() =>
          (material.debugInkFeatures as List<InkFeature>? ?? [])
              .whereType<InteractiveInkFeature>()
              .where((feature) => feature.color.a > 0);
      Color? iconColor(IconData icon) =>
          tester.widget<Icon>(find.byIcon(icon)).color;

      final cs = Theme.of(
        tester.element(find.byType(LibraryLikeCardActions)),
      ).colorScheme;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (final (action, activeIcon, otherIcon) in [
        (add, Icons.add_circle_rounded, Icons.play_arrow_rounded),
        (play, Icons.play_arrow_rounded, Icons.add_circle_rounded),
      ]) {
        final center = tester.getCenter(action);
        await mouse.moveTo(center);
        await tester.pump();
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 15));
          expect(scaleOf(tester, activeIcon), 1.0);
          if (frame == 2) {
            hoverColor.value = hoverColor.value == Colors.black26
                ? Colors.black12
                : Colors.black26;
            await tester.pump();
            expect(scaleOf(tester, activeIcon), 1.0);
          }
        }
        expect(scaleOf(tester, activeIcon), 1.0);
        expect(scaleOf(tester, otherIcon), 1.0);
        expect(iconColor(activeIcon), cs.primary);
        expect(iconColor(otherIcon), cs.onSurfaceVariant);
        expect(visibleInk(), isEmpty);
        await mouse.down(center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(scaleOf(tester, activeIcon), 0.82);
        expect(scaleOf(tester, otherIcon), 1.0);
        expect(visibleInk(), isEmpty);
        await mouse.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 140));
        expect(scaleOf(tester, activeIcon), 1.0);
      }
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 15));
        expect(scaleOf(tester, Icons.play_arrow_rounded), 1.0);
      }
      expect(scaleOf(tester, Icons.add_circle_rounded), 1.0);
      expect(scaleOf(tester, Icons.play_arrow_rounded), 1.0);
      expect(iconColor(Icons.add_circle_rounded), cs.onSurfaceVariant);
      expect(iconColor(Icons.play_arrow_rounded), cs.onSurfaceVariant);
      expect(visibleInk(), isEmpty);
      await mouse.removePointer();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'large font cards retain their row height on $platform',
      (tester) async {
        final cards = [
          const LibraryLikeSingleAudioCardContent(
            title: 'Title',
            lines: _lines,
          ),
          LibraryLikeWorkCardContent(
            title: 'Title',
            lines: _lines,
            coverBuilder: (width) => SizedBox(width: width, height: 90),
          ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Material(
                child: SizedBox(width: 420, child: ListView(children: cards)),
              ),
            ),
          ),
        );
        for (final card in cards) {
          expect(tester.getSize(find.byWidget(card)).height, 90);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
    for (final uncovered in [false, true]) {
      testWidgets(
        'card render cost ${uncovered ? 'uncovered' : 'covered'} on $platform',
        (tester) async {
          final actions = LibraryLikeCardActions(
            addLabel: 'Add',
            playLabel: 'Play',
            onAdd: () {},
            onPlay: () {},
          );
          final content = uncovered
              ? LibraryLikeSingleAudioCardContent(
                  title: 'A work title',
                  lines: _lines,
                  trailingActions: actions,
                )
              : LibraryLikeWorkCardContent(
                  title: 'A work title',
                  lines: _lines,
                  trailingActions: actions,
                  coverBuilder: (width) => SizedBox(width: width, height: 90),
                );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(useMaterial3: true),
              home: Material(
                child: Center(child: SizedBox(width: 420, child: content)),
              ),
            ),
          );
          final root = find.byWidget(content).evaluate().single;
          final cost = _countTree(root);
          // The previous row mounted 256-258 elements, 144-146 render objects
          // and 42 states, before adding actual artwork or a swipe shell.
          expect(cost.elements, lessThanOrEqualTo(215));
          expect(cost.renderObjects, lessThanOrEqualTo(130));
          expect(cost.states, lessThanOrEqualTo(32));
          expect(
            find.descendant(
              of: find.byType(LibraryLikeCardActions),
              matching: find.byType(Material),
            ),
            findsNothing,
          );
          expect(tester.getSize(find.byWidget(content)).height, 90);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      'compact card actions keep pointer keyboard and disabled semantics on $platform',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          var additions = 0;
          var plays = 0;
          Widget page({required bool enabled}) => MaterialApp(
            home: Material(
              child: Center(
                child: LibraryLikeCardActions(
                  addLabel: 'Add',
                  playLabel: 'Play',
                  onAdd: enabled ? () => additions++ : null,
                  onPlay: enabled ? () => plays++ : null,
                ),
              ),
            ),
          );
          await tester.pumpWidget(page(enabled: true));
          await tester.tap(find.byTooltip('Add'));
          await tester.tap(find.byTooltip('Play'));
          expect(additions, 1);
          expect(plays, 1);
          final addContext = tester.element(
            find.byIcon(Icons.add_circle_rounded),
          );
          Focus.of(addContext).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(additions, 2);
          await tester.pumpWidget(page(enabled: false));
          for (final label in ['Add', 'Play']) {
            final node = tester.getSemantics(find.bySemanticsLabel(label));
            final flags = node.getSemanticsData().flagsCollection;
            expect(flags.isButton, isTrue);
            expect(flags.isEnabled, Tristate.isFalse);
            await tester.tap(find.byTooltip(label));
          }
          await tester.pump();
          expect(additions, 2);
          expect(plays, 1);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
