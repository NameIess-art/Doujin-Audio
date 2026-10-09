import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

Widget _page(
  String name,
  ValueNotifier<int> active, {
  int tabIndex = 0,
  ValueNotifier<int>? section,
  int sectionIndex = 0,
}) => switch (name) {
  'LibraryTab' => LibraryTab(
    tabIndex: tabIndex,
    activeTabIndexListenable: active,
    activeSectionListenable: section,
    sectionIndex: sectionIndex,
  ),
  'AsmrTab' => AsmrTab(
    tabIndex: tabIndex,
    activeTabIndexListenable: active,
    activeSectionListenable: section,
    sectionIndex: sectionIndex,
  ),
  'PlaylistTab' => PlaylistTab(
    tabIndex: tabIndex,
    activeTabIndexListenable: active,
  ),
  _ => throw ArgumentError.value(name),
};

Widget _pageHost(
  Widget page,
  ValueNotifier<int> active, {
  int tabIndex = 0,
  ValueNotifier<int>? section,
  int sectionIndex = 0,
}) => ListenableBuilder(
  key: const ValueKey('activity_host'),
  listenable: Listenable.merge([active, ?section]),
  child: page,
  builder: (context, child) {
    final selected =
        active.value == tabIndex &&
        (section == null || section.value == sectionIndex);
    return Offstage(
      offstage: !selected,
      child: TickerMode(enabled: selected, child: child!),
    );
  },
);

void main() {
  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({
      AppPreferences.onboardingCompletedKey: true,
    });
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final cached in [false, true]) {
    testWidgets(
      'on-demand playlist defers first content (cached: $cached)',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final active = ValueNotifier<int>(0);
        addTearDown(fixture.dispose);
        addTearDown(active.dispose);
        final track = MusicTrack(
          path: '/prepared-session.mp3',
          displayName: 'Prepared session',
          groupKey: 'prepared',
          groupTitle: 'Prepared session',
          groupSubtitle: '',
          isSingle: true,
        );
        fixture.library.addTracks([track], notify: false, persist: false);
        final session = PlaybackSession(
          id: 'prepared-session',
          currentTrackPath: track.path,
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        );
        addTearDown(session.shutdown);
        fixture.playbackService.registerSession(session);
        void syncPlayback({required bool initialized}) =>
            fixture.playbackService.syncSlice(
              activeSessions: [session],
              playingSessionCount: 0,
              focusedSessionId: null,
              coverGeneration: 0,
              isInitialized: initialized,
            );
        syncPlayback(initialized: cached);
        var sorts = 0;
        await tester.pumpWidget(
          fixture.build(
            AppFadeThroughIndexedStack.lazy(
              indexListenable: active,
              itemCount: 2,
              duration: kAppMotionSlow,
              itemBuilder: (_, index) => index == 0
                  ? const SizedBox()
                  : PlaylistTab(tabIndex: 1, activeTabIndexListenable: active),
            ),
            overrides: [
              playlistSortedEntriesUiProvider.overrideWith((ref) {
                sorts++;
                return ref.watch(playlistStructureUiProvider).entries;
              }),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 161));
        await tester.pump();
        final content = find.byKey(
          const ValueKey('playlist_loaded_content'),
          skipOffstage: false,
        );
        expect(content, findsNothing);
        expect(
          find.byKey(
            const ValueKey('playlist_initial_placeholder'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        active.value = 1;
        await tester.pump();
        final slide = find
            .ancestor(
              of: find.byType(PlaylistTab),
              matching: find.byType(SlideTransition),
            )
            .first;
        expect(tester.widget<SlideTransition>(slide).position.value.dx, 1);
        expect(content, findsNothing);
        expect(find.byType(SessionListCard), findsNothing);
        expect(
          find.byKey(const ValueKey('playlist_initial_placeholder')),
          findsOneWidget,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.widget<SlideTransition>(slide).position.value.dx,
          lessThan(1),
        );
        expect(content, findsNothing);
        expect(sorts, 0);
        await tester.pump(kAppMotionSlow);
        if (!cached) {
          await tester.pump(kAppMotionFast);
          await tester.pump();
          expect(find.byType(SessionListCard), findsNothing);
          expect(
            find.byKey(const ValueKey('playlist_data_placeholder')),
            findsOneWidget,
          );
          syncPlayback(initialized: true);
        }
        await tester.pumpAndSettle();
        expect(sorts, greaterThan(0));
        expect(content, findsOneWidget);
        final card = find.byType(SessionListCard);
        expect(card, findsOneWidget);
        await tester.longPress(card);
        await tester.pumpAndSettle();
        final selection = find.byKey(
          const ValueKey('playlist_selection_indicator_prepared-session'),
        );
        expect(selection, findsOneWidget);
        final loadedContent = tester.element(content);
        final loadedCard = tester.element(card);
        active.value = 0;
        await tester.pumpAndSettle();
        active.value = 1;
        await tester.pump();
        expect(tester.element(content), same(loadedContent));
        expect(tester.element(card), same(loadedCard));
        expect(selection, findsOneWidget);
        expect(
          find.byKey(const ValueKey('playlist_initial_placeholder')),
          findsNothing,
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'LibraryTab refreshes a stale card snapshot on its first activation',
    (tester) async {
      var snapshotBuilds = 0;
      final fixture = AppRuntimeWidgetTestFixture(
        libraryCardSnapshotBuilder: (payload) async {
          snapshotBuilds++;
          return const LibraryOrganizer().buildCardTree(
            tracks: payload.tracks,
            watchedFolders: payload.watchedFolders,
            watchedLibraries: payload.watchedLibraries,
          );
        },
      );
      final active = ValueNotifier<int>(1);
      addTearDown(fixture.dispose);
      addTearDown(active.dispose);
      await fixture.library.ensureCardSnapshot();
      fixture.libraryService.addWatchedFolder('/stale-library');
      fixture.library.syncPresentationState(isInitialized: true);
      snapshotBuilds = 0;
      await tester.pumpWidget(
        fixture.build(_pageHost(_page('LibraryTab', active), active)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(snapshotBuilds, 0);
      expect(fixture.library.state.isInitialized, isTrue);
      expect(
        fixture.library.state.treeSnapshotRevision,
        lessThan(fixture.library.structureRevision),
      );
      final hiddenState = fixture.library.state;

      // Change visibility only: no provider state or catalog notification.
      active.value = 0;
      await tester.pump();
      expect(snapshotBuilds, 1);
      await tester.pump();
      expect(
        fixture.library.state.treeSnapshotRevision,
        fixture.library.structureRevision,
      );
      expect(hiddenState.isInitialized, fixture.library.state.isInitialized);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final name in ['LibraryTab', 'AsmrTab', 'PlaylistTab']) {
      testWidgets('$name retains its page when switching tabs on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        final active = ValueNotifier<int>(1);
        addTearDown(fixture.dispose);
        addTearDown(active.dispose);
        await tester.pumpWidget(
          fixture.build(_pageHost(_page(name, active), active)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final page = tester.element(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == name,
            skipOffstage: false,
          ),
        );
        var builds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (identical(element, page)) builds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);

        for (final destination in [2, 3, 1]) {
          active.value = destination;
          await tester.pump();
        }
        expect(builds, 0);
        active.value = 0;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        builds = 0;
        for (final destination in [1, 2, 0, 3, 0]) {
          active.value = destination;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(builds, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugOnRebuildDirtyWidget = previous;
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('$name rebinds activity listenables on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        final oldActive = ValueNotifier<int>(1);
        final active = ValueNotifier<int>(2);
        addTearDown(fixture.dispose);
        addTearDown(oldActive.dispose);
        addTearDown(active.dispose);
        await tester.pumpWidget(
          fixture.build(_pageHost(_page(name, oldActive), oldActive)),
        );
        await tester.pump();
        final page = tester.element(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == name,
            skipOffstage: false,
          ),
        );
        await tester.pumpWidget(
          fixture.build(_pageHost(_page(name, active), active)),
        );
        await tester.pump();
        expect(
          tester.element(find.byWidget(page.widget, skipOffstage: false)),
          same(page),
        );
        final host = tester.element(
          find.byKey(const ValueKey('activity_host')),
        );

        oldActive.value = 0;
        expect(page.dirty, isFalse);
        expect(host.dirty, isFalse);
        active.value = 0;
        expect(host.dirty, isTrue);
        expect(page.dirty, isFalse);
        await tester.pump();
        await tester.pumpWidget(
          fixture.build(
            _pageHost(_page(name, active, tabIndex: 1), active, tabIndex: 1),
          ),
        );
        await tester.pump();
        active.value = 2;
        expect(page.dirty, isFalse);
        active.value = 1;
        expect(host.dirty, isTrue);
        expect(page.dirty, isFalse);
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  for (final name in ['LibraryTab', 'AsmrTab']) {
    testWidgets('$name rebinds sections and ignores other hidden sections', (
      tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final active = ValueNotifier<int>(0);
      final oldSection = ValueNotifier<int>(1);
      final section = ValueNotifier<int>(2);
      addTearDown(fixture.dispose);
      addTearDown(active.dispose);
      addTearDown(oldSection.dispose);
      addTearDown(section.dispose);
      await tester.pumpWidget(
        fixture.build(
          _pageHost(
            _page(name, active, section: oldSection),
            active,
            section: oldSection,
          ),
        ),
      );
      await tester.pump();
      final page = tester.element(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == name,
          skipOffstage: false,
        ),
      );
      oldSection.value = 2;
      expect(page.dirty, isFalse);
      await tester.pumpWidget(
        fixture.build(
          _pageHost(
            _page(name, active, section: section),
            active,
            section: section,
          ),
        ),
      );
      await tester.pump();
      oldSection.value = 0;
      expect(page.dirty, isFalse);
      final host = tester.element(find.byKey(const ValueKey('activity_host')));
      expect(host.dirty, isFalse);
      section.value = 0;
      expect(host.dirty, isTrue);
      expect(page.dirty, isFalse);
      await tester.pump();
      await tester.pumpWidget(
        fixture.build(
          _pageHost(
            _page(name, active, section: section, sectionIndex: 1),
            active,
            section: section,
            sectionIndex: 1,
          ),
        ),
      );
      await tester.pump();
      section.value = 2;
      expect(page.dirty, isFalse);
      section.value = 1;
      expect(host.dirty, isTrue);
      expect(page.dirty, isFalse);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final name in ['LibraryTab', 'PlaylistTab']) {
      testWidgets('$name pauses hidden updates and resumes on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        final active = ValueNotifier<int>(0);
        addTearDown(fixture.dispose);
        addTearDown(active.dispose);
        fixture.settingsRepository.syncSlice(isInitialized: true);
        await tester.pumpWidget(
          fixture.build(_pageHost(_page(name, active), active)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        active.value = 1;
        await tester.pump();
        final page = tester.element(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == name,
            skipOffstage: false,
          ),
        );
        final content = name == 'PlaylistTab'
            ? tester.element(
                find
                    .ancestor(
                      of: find.byType(
                        PlaceholderContentTransition,
                        skipOffstage: false,
                      ),
                      matching: find.byType(Consumer, skipOffstage: false),
                    )
                    .first,
              )
            : page;
        var builds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (identical(element, content)) builds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);

        fixture.settingsRepository
          ..pinnedLibraryPaths = ['/latest']
          ..pinnedPlaylistSessionIds = ['latest']
          ..syncSlice(isInitialized: true);
        await tester.pump();
        await tester.pump();
        expect(builds, 0);
        active.value = 0;
        await tester.pump();
        await tester.pump();
        expect(builds, greaterThan(0));
        final settings = ProviderScope.containerOf(
          page,
        ).read(settingsStateProvider).value!;
        expect(settings.pinnedLibraryPaths, ['/latest']);
        expect(settings.pinnedPlaylistSessionIds, ['latest']);
        debugOnRebuildDirtyWidget = previous;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
