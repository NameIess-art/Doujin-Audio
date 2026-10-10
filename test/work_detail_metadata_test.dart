import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_metadata.dart';
import 'package:doujin_audio/core/widgets/horizontal_edge_fade_scroll.dart';

void main() {
  testWidgets(
    'metadata stays still until manually scrolled on both platforms',
    (tester) async {
      Future<void> pumpMetadata({required bool overflowing}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: WorkDetailMetadata(
                  key: ValueKey(overflowing),
                  voiceActors: overflowing
                      ? List.generate(12, (index) => 'Voice actor $index')
                      : const ['Voice'],
                  tags: overflowing
                      ? List.generate(12, (index) => 'Work tag $index')
                      : const ['ASMR'],
                  onCopy: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      ScrollPosition position(String prefix) => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(ValueKey('work_detail_${prefix}_scroller')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      await pumpMetadata(overflowing: true);
      for (final prefix in ['voice_actor', 'tag']) {
        expect(position(prefix).maxScrollExtent, greaterThan(0));
        expect(position(prefix).pixels, 0);
      }
      await pumpMetadata(overflowing: false);
      for (final prefix in ['voice_actor', 'tag']) {
        expect(position(prefix).maxScrollExtent, 0);
        expect(position(prefix).pixels, 0);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'metadata builds visible capsules and keeps all items reachable at scale $scale',
      (tester) async {
        final copied = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
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
          final fade = find.byKey(ValueKey('work_detail_${prefix}_edge_fade'));
          expect(tester.widget(fade), isA<HorizontalEdgeFadeScroll>());
          expect(
            find.descendant(
              of: fade,
              matching: find.byWidgetPredicate(
                (widget) => widget is ShaderMask,
              ),
            ),
            findsOneWidget,
          );
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
