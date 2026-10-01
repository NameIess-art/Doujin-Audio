import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  for (final (platform, presentation) in [
    (TargetPlatform.android, ActiveSessionCarouselPresentation.embedded),
    (TargetPlatform.windows, ActiveSessionCarouselPresentation.embedded),
    (TargetPlatform.android, ActiveSessionCarouselPresentation.circularCover),
    (TargetPlatform.windows, ActiveSessionCarouselPresentation.circularCover),
  ]) {
    testWidgets(
      'round dock focuses new playback without horizontal paging ($platform, $presentation)',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final sessions = [
          for (final id in ['first', 'second'])
            PlaybackSession(
              id: id,
              currentTrackPath: '/$id.mp3',
              loopMode: SessionLoopMode.single,
              nonSingleLoopMode: SessionLoopMode.single,
              volume: 1,
              createdAt: DateTime(2026),
              state: const PlayerState(true, ProcessingState.ready),
            ),
        ];
        for (final session in sessions) {
          addTearDown(session.shutdown);
        }
        var dockWidth = kActiveSessionCarouselDockHeight;
        Widget dock(List<PlaybackSession> shown) => fixture.build(
          Center(
            child: SizedBox(
              width: dockWidth,
              height: kActiveSessionCarouselDockHeight,
              child: ActiveSessionCarousel(
                presentation: presentation,
                viewportFraction: 1,
                sessions: shown
                    .map(PlaybackSessionSnapshot.fromRuntime)
                    .toList(),
                onOpenSession: (_) {},
              ),
            ),
          ),
        );

        await tester.pumpWidget(dock([sessions.first]));
        await tester.pumpAndSettle();
        final controller = ProviderScope.containerOf(
          tester.element(find.byType(ActiveSessionCarousel)),
        ).read(playlistUiControllerProvider);
        controller.requestCarouselSnap('second');
        await tester.pumpWidget(dock(sessions));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(PageView), findsNothing);
        final card = find.byKey(
          const ValueKey<String>('active_session_card_second'),
        );
        expect(card, findsOneWidget);
        expect(
          tester.getCenter(card),
          tester.getCenter(find.byType(ActiveSessionCarousel)),
        );
        await tester.pumpAndSettle();

        // Playback activation can also arrive after the session list is rebuilt.
        controller.requestCarouselSnap('first');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final first = find.byKey(
          const ValueKey<String>('active_session_card_first'),
        );
        expect(first, findsOneWidget);
        expect(
          tester.getCenter(first),
          tester.getCenter(find.byType(ActiveSessionCarousel)),
        );

        if (presentation == ActiveSessionCarouselPresentation.embedded) {
          // Expanding restores the same selection and enables animated paging.
          dockWidth = 320;
          await tester.pumpWidget(dock(sessions));
          await tester.pump();
          expect(find.byType(PageView), findsOneWidget);
          expect(
            tester.getCenter(first),
            tester.getCenter(find.byType(ActiveSessionCarousel)),
          );
          controller.requestCarouselSnap('second');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final page = tester
              .widget<PageView>(find.byType(PageView))
              .controller!
              .page!;
          expect((page - page.roundToDouble()).abs(), greaterThan(0.0001));

          // Collapsing during paging removes the moving viewport immediately.
          dockWidth = kActiveSessionCarouselDockHeight;
          await tester.pumpWidget(dock(sessions));
          await tester.pump();
          expect(find.byType(PageView), findsNothing);
          expect(card, findsOneWidget);
          expect(
            tester.getCenter(card),
            tester.getCenter(find.byType(ActiveSessionCarousel)),
          );

          dockWidth = 320;
          await tester.pumpWidget(dock(sessions));
          await tester.pump();
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller!.page,
            page.roundToDouble(),
          );
          controller.requestCarouselSnap('first');
          await tester.pumpAndSettle();
          dockWidth = kActiveSessionCarouselDockHeight;
          await tester.pumpWidget(dock(sessions));
        }

        // Removing the focused round card selects its neighbor in place.
        await tester.pumpWidget(dock([sessions.last]));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(card, findsOneWidget);
        expect(
          tester.getCenter(card),
          tester.getCenter(find.byType(ActiveSessionCarousel)),
        );
        debugDefaultTargetPlatformOverride = null;
        expect(tester.takeException(), isNull);
      },
    );
  }
}
