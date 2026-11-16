import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_ui_helpers.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  group('Playlist batch selection rules', () {
    bool isPlayEnabled(int count) => count > 0;

    bool isPauseEnabled(int count) => count > 0;
    bool isPinEnabled(int count) => count > 0;
    bool isRemoveEnabled(int count) => count > 0;

    test('Play button is disabled when selected count is 0', () {
      expect(isPlayEnabled(0), isFalse);
      expect(isPauseEnabled(0), isFalse);
      expect(isPinEnabled(0), isFalse);
      expect(isRemoveEnabled(0), isFalse);
    });

    test('Play button is enabled for a single selection', () {
      expect(isPlayEnabled(1), isTrue);
      expect(isPauseEnabled(1), isTrue);
      expect(isPinEnabled(1), isTrue);
      expect(isRemoveEnabled(1), isTrue);
    });

    test('Play button is enabled for multiple selections', () {
      expect(isPlayEnabled(2), isTrue);
      expect(isPlayEnabled(5), isTrue);
      expect(isPauseEnabled(2), isTrue);
      expect(isPinEnabled(2), isTrue);
      expect(isRemoveEnabled(2), isTrue);
    });
  });

  group('Playlist batch selection header rendering and transitions', () {
    testWidgets(
      'playlist multi-select top capsule stays expanded when scrolling',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(500, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        final tracks = [
          for (var i = 1; i <= 16; i++)
            testMusicTrack(
              name: 'Track $i',
              path: PathMatcher.normalize('/library/work$i/01.mp3'),
              groupKey: PathMatcher.normalize('/library/work$i'),
              groupTitle: 'Work $i',
            ),
        ];
        fixture.runtimeGraph.library.addTracks(tracks, persist: false);
        final sessions = [
          for (final track in tracks)
            fixture.runtimeGraph.playback.createTrackSession(track),
        ];
        fixture.playbackService.syncSlice(
          activeSessions: sessions,
          playingSessionCount: 0,
          focusedSessionId: sessions.first.id,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const PlaylistTab()));
        await tester.pumpAndSettle();

        await tester.longPress(find.text('Track 1'));
        await tester.pumpAndSettle();

        final headerFinder = find.byKey(
          const ValueKey('playlist_batch_selection_header'),
        );
        expect(headerFinder, findsOneWidget);
        expect(
          tester.widget<TopPageHeader>(headerFinder).collapseController,
          isNull,
        );
        final initialCapsuleRect = tester.getRect(find.byType(HeaderTopCapsule));

        final scrollable = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable && widget.axisDirection == AxisDirection.down,
        );
        await tester.drag(scrollable.first, const Offset(0, -320));
        await tester.pumpAndSettle();

        expect(
          tester.getRect(find.byType(HeaderTopCapsule)),
          initialCapsuleRect,
        );
        expect(
          find.text(fixture.languageProvider.tr('multi_select')),
          findsOneWidget,
        );
        expect(
          find.text(
            fixture.languageProvider.tr('selected_count', {'count': '1'}),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'LibraryBatchSelectionHeader keeps top capsule non-collapsible',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        await tester.pumpWidget(
          fixture.build(
            LibraryBatchSelectionHeader(
              keyPrefix: 'library',
              i18n: fixture.languageProvider,
              selectedCount: 2,
              onAddToPlaylist: null,
              onCompleteMetadata: null,
              onRemove: null,
              onExit: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final header = tester.widget<TopPageHeader>(
          find.byKey(const ValueKey('library_batch_selection_header')),
        );
        expect(header.collapseController, isNull);
        expect(find.byType(HeaderTopCapsule), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('multi_select')),
          findsOneWidget,
        );
      },
    );
    testWidgets('selection header renders AppRollingNumber and leading close button', (
      tester,
    ) async {
      final selectedCount = ValueNotifier<int>(1);
      addTearDown(selectedCount.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: selectedCount,
                builder: (context, count, _) {
                  return TopPageHeader(
                    key: const ValueKey('playlist_batch_selection_header'),
                    leading: IconButton(
                      key: const ValueKey('exit_selection_button'),
                      onPressed: () {},
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Cancel',
                    ),
                    title: count.toString(),
                    titleWidget: AppRollingNumber(number: count),
                    trailing: const SizedBox(
                      height: 44,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('batch_play_button'),
                            onPressed: null,
                            icon: Icon(Icons.play_arrow_rounded),
                          ),
                          IconButton(
                            key: ValueKey('batch_pin_button'),
                            onPressed: null,
                            icon: Icon(Icons.push_pin_rounded),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('playlist_batch_selection_header')), findsOneWidget);
      expect(find.byKey(const ValueKey('exit_selection_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('batch_play_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('batch_pin_button')), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.byType(AppRollingNumber), findsOneWidget);

      selectedCount.value = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });

    testWidgets(
      'selection and pin updates keep card contents and header transition isolated',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(500, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        final tracks = [
          for (var i = 1; i <= 120; i++)
            testMusicTrack(
              name: 'Session ${i.toString().padLeft(3, '0')}',
              path: PathMatcher.normalize('/library/work$i/01.mp3'),
              groupKey: PathMatcher.normalize('/library/work$i'),
              groupTitle: 'Work $i',
            ),
        ];
        fixture.runtimeGraph.library.addTracks(tracks, persist: false);
        final queueSession = fixture.runtimeGraph.playback.createPlaybackQueue(
          'Large Queue',
        );
        await fixture.runtimeGraph.playback.addPlaybackQueueEntries(
          queueSession.id,
          [
            for (var i = 0; i < tracks.length; i++)
              PlaybackQueueEntry(
                id: 'entry_$i',
                kind: PlaybackQueueEntryKind.track,
                title: tracks[i].displayName,
                tracks: [tracks[i]],
              ),
          ],
        );
        final sessions = [
          queueSession,
          for (final track in tracks)
            fixture.runtimeGraph.playback.createTrackSession(track),
        ];
        fixture.playbackService.syncSlice(
          activeSessions: sessions,
          playingSessionCount: 0,
          focusedSessionId: sessions.first.id,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const PlaylistTab()));
        await tester.pumpAndSettle();

        final mountedLabels = find.byType(PlaylistAudioLabels).evaluate().toSet();
        final mountedQueueNames = find
            .byKey(ValueKey<String>('playback_queue_name_${queueSession.id}'))
            .evaluate()
            .toSet();
        final mountedCards = find.byType(SessionListCard).evaluate().toSet();
        final headerTransition = find.byType(AppHeaderTransition).evaluate().single;
        expect(mountedLabels, isNotEmpty);
        expect(mountedQueueNames, hasLength(1));

        var cardLabelRebuilds = 0;
        var cardRebuilds = 0;
        var headerTransitionRebuilds = 0;
        final previousHook = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousHook?.call(element, builtOnce);
          if (!builtOnce) return;
          if (mountedLabels.contains(element) ||
              mountedQueueNames.contains(element)) {
            cardLabelRebuilds++;
          }
          if (mountedCards.contains(element)) {
            cardRebuilds++;
          }
          if (identical(element, headerTransition)) {
            headerTransitionRebuilds++;
          }
        };

        try {
          // Enter selection mode by long-pressing the large queue card.
          await tester.longPress(find.text('Large Queue'));
          await tester.pumpAndSettle();
          expect(cardLabelRebuilds, 0);
          expect(cardRebuilds, 0);
          expect(headerTransitionRebuilds, 0);
          expect(
            find.byKey(
              ValueKey<String>('playlist_selection_indicator_${queueSession.id}'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.ancestor(
                of: find.byKey(
                  ValueKey<String>(
                    'playlist_selection_indicator_${queueSession.id}',
                  ),
                ),
                matching: find.byType(PlaylistSelectionIndicator),
              ),
              matching: find.byType(RepaintBoundary),
            ),
            findsOneWidget,
          );

          // Selecting another item must not rebuild card labels or AppHeaderTransition.
          await tester.tap(find.text('Session 002'));
          await tester.pumpAndSettle();
          expect(cardLabelRebuilds, 0);
          expect(cardRebuilds, 0);
          expect(headerTransitionRebuilds, 0);

          // Batch pin exits selection mode and triggers pin indicator without
          // rebuilding unrelated cards' labels.
          await tester.tap(find.byKey(const ValueKey('batch_pin_button')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(
              ValueKey<String>('playlist_session_pinned_${queueSession.id}'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(
              ValueKey<String>('playlist_session_pinned_${sessions[2].id}'),
            ),
            findsOneWidget,
          );
        } finally {
          debugOnRebuildDirtyWidget = previousHook;
        }
      },
    );
  });
}
