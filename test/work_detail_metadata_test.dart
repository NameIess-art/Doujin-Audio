import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_metadata.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'metadata builds visible capsules and keeps all items reachable at scale $scale',
      (tester) async {
        final copied = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SizedBox(
                  width: 320,
                  child: WorkDetailMetadata(
                    voiceActors: List.generate(60, (i) => 'Voice actor $i'),
                    tags: List.generate(60, (i) => 'Long work tag $i'),
                    onCopy: copied.add,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Voice actor 0'), findsOneWidget);
        expect(find.text('#Long work tag 0'), findsOneWidget);
        expect(find.text('Voice actor 59'), findsNothing);
        expect(find.text('#Long work tag 59'), findsNothing);
        expect(find.byType(InkWell).evaluate().length, lessThan(30));
        for (final prefix in ['voice_actor', 'tag']) {
          final list = find.byKey(ValueKey('work_detail_${prefix}_scroller'));
          final scrollable = find.descendant(
            of: list,
            matching: find.byType(Scrollable),
          );
          final state = tester.state<ScrollableState>(scrollable);
          if (defaultTargetPlatform == TargetPlatform.windows) {
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: tester.getCenter(list),
                scrollDelta: const Offset(0, 100),
              ),
            );
            await tester.pump();
            expect(state.position.pixels, greaterThan(0));
          }
          final last = find.text(
            prefix == 'tag' ? '#Long work tag 59' : 'Voice actor 59',
          );
          await tester.scrollUntilVisible(
            last,
            600,
            scrollable: scrollable,
            maxScrolls: 200,
          );
          await tester.ensureVisible(last);
          // A long label can be wider than the viewport at large text scales.
          await tester.tapAt(
            tester.getRect(last).intersect(tester.getRect(list)).center,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(copied, ['Voice actor 59', 'Long work tag 59']);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}
