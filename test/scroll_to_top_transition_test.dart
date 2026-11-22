import 'dart:async';

import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/scroll_to_top_transition.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playback_position_ui_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ScrollToTopTransition defers interrupt side effects during LayoutBuilder resize and TickerMode disable',
    (tester) async {
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      addTearDown(coordinator.resetForTest);

      final session = PlaybackSession(
        id: 'scroll-top-session',
        currentTrackPath: '/audio/track.mp3',
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(true, ProcessingState.ready),
      );
      final gate = PlaybackPositionUiGate(
        session: PlaybackSessionSnapshot.fromRuntime(session),
        interactionCoordinator: coordinator,
        minUpdateInterval: Duration.zero,
      );
      final scrollController = ScrollController(initialScrollOffset: 600);
      final transitionKey = GlobalKey<ScrollToTopTransitionState>();
      addTearDown(() async {
        scrollController.dispose();
        gate.dispose();
        await session.shutdown();
      });

      var width = 360.0;
      var tickerEnabled = true;
      late StateSetter updateHost;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return Scaffold(
                body: Column(
                  children: [
                    ListenableBuilder(
                      listenable: gate,
                      builder: (_, _) =>
                          Text('pos:${gate.value.position.inSeconds}'),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: width,
                          child: TickerMode(
                            enabled: tickerEnabled,
                            child: ScrollToTopTransition(
                              key: transitionKey,
                              controller: () => scrollController,
                              child: ListView.builder(
                                controller: scrollController,
                                itemExtent: 60,
                                itemCount: 50,
                                itemBuilder: (_, index) => Text('Row $index'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Start scroll-to-top, dirty playback position while interacting, then resize.
      unawaited(transitionKey.currentState!.scrollToTop());
      await tester.pump();
      expect(coordinator.isInteracting, isTrue);

      session.setOptimisticPosition(const Duration(seconds: 9));
      await tester.pump();

      updateHost(() => width = 420.0);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(coordinator.isInteracting, isFalse);
      expect(find.text('pos:9'), findsOneWidget);

      // Start again and disable TickerMode mid-scroll.
      scrollController.jumpTo(500);
      await tester.pump();
      unawaited(transitionKey.currentState!.scrollToTop());
      await tester.pump();
      session.setOptimisticPosition(const Duration(seconds: 15));
      await tester.pump();

      updateHost(() => tickerEnabled = false);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(coordinator.isInteracting, isFalse);
      expect(find.text('pos:15'), findsOneWidget);
    },
  );
}
