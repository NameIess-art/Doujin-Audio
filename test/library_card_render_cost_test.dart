import 'dart:ui' show Tristate;

import 'package:doujin_audio/core/widgets/library_like_cards.dart';
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
          debugPrint(
            'LIBRARY_CARD_RENDER_COST $platform uncovered=$uncovered $cost',
          );
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
