import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/presentation/playlist_sorting.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';

import 'support/app_runtime_test_fixture.dart';

PlaybackSessionSnapshot _session(
  String id, {
  String? name,
  DateTime? createdAt,
  bool isTemporary = false,
}) {
  final s = PlaybackSession(
    id: id,
    isTemporary: isTemporary,
    currentTrackPath: '/audio/${name ?? id}.mp3',
    loopMode: SessionLoopMode.folderSequential,
    nonSingleLoopMode: SessionLoopMode.folderSequential,
    volume: 1,
    createdAt: createdAt ?? DateTime(2026),
    state: const PlayerState(false, ProcessingState.ready),
  );
  return PlaybackSessionSnapshot.fromRuntime(s);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryFacade library;

  setUp(() {
    final graph = createTestRuntimeGraph();
    library = graph.library;
  });

  test(
    'temporary session stays above pinned entries in either sort direction',
    () {
      final temporary = _session('temporary', isTemporary: true);
      final saved = _session('saved');
      for (final ascending in [true, false]) {
        final sorted = sortPlaylistSessions(
          sessions: [saved, temporary],
          criterion: PlaylistSortCriterion.name,
          ascending: ascending,
          groupByLibrary: true,
          library: library,
          trackForSession: (session) {
            expect(session.isTemporary, isFalse);
            return null;
          },
          pinnedSessionIds: {saved.id},
        );
        expect(sorted.map((session) => session.id), ['temporary', 'saved']);
      }
    },
  );

  test('sortPlaylistSessions moves single pinned session to top', () {
    final s1 = _session('s1', name: 'Alpha');
    final s2 = _session('s2', name: 'Beta');
    final s3 = _session('s3', name: 'Gamma');

    // Normally Alpha, Beta, Gamma in alphabetical order
    final normal = sortPlaylistSessions(
      sessions: [s3, s1, s2],
      criterion: PlaylistSortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
      trackForSession: (session) => MusicTrack(
        path: session.currentTrackPath,
        displayName: session.id,
        groupKey: 'group',
        groupTitle: 'group',
        groupSubtitle: '',
        isSingle: true,
      ),
      pinnedSessionIds: {},
    );
    expect(normal.map((s) => s.id).toList(), ['s1', 's2', 's3']);

    // When s3 (Gamma) is pinned, it should appear first even though it's last alphabetically
    final pinned = sortPlaylistSessions(
      sessions: [s3, s1, s2],
      criterion: PlaylistSortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
      trackForSession: (session) => MusicTrack(
        path: session.currentTrackPath,
        displayName: session.id,
        groupKey: 'group',
        groupTitle: 'group',
        groupSubtitle: '',
        isSingle: true,
      ),
      pinnedSessionIds: {'s3'},
    );
    expect(pinned.map((s) => s.id).toList(), ['s3', 's1', 's2']);
  });

  test(
    'sortPlaylistSessions sorts multiple pinned sessions by sort criterion',
    () {
      final s1 = _session('s1', name: 'A', createdAt: DateTime(2025, 1, 10));
      final s2 = _session('s2', name: 'B', createdAt: DateTime(2025, 1, 5));
      final s3 = _session('s3', name: 'C', createdAt: DateTime(2025, 1, 20));
      final s4 = _session('s4', name: 'D', createdAt: DateTime(2025));

      // Pin s2 and s3.
      // Pinned group: s2 (Jan 5), s3 (Jan 20)
      // Unpinned group: s1 (Jan 10), s4 (Jan 1)
      // If sorted by addedAt ascending:
      // Pinned: [s2, s3]
      // Unpinned: [s4, s1]
      // Total: [s2, s3, s4, s1]
      final sortedAsc = sortPlaylistSessions(
        sessions: [s1, s2, s3, s4],
        criterion: PlaylistSortCriterion.addedAt,
        ascending: true,
        groupByLibrary: false,
        library: library,
        trackForSession: (session) => null,
        pinnedSessionIds: {'s2', 's3'},
      );
      expect(sortedAsc.map((s) => s.id).toList(), ['s2', 's3', 's4', 's1']);

      // If sorted by addedAt descending:
      // Pinned: [s3, s2]
      // Unpinned: [s1, s4]
      // Total: [s3, s2, s1, s4]
      final sortedDesc = sortPlaylistSessions(
        sessions: [s1, s2, s3, s4],
        criterion: PlaylistSortCriterion.addedAt,
        ascending: false,
        groupByLibrary: false,
        library: library,
        trackForSession: (session) => null,
        pinnedSessionIds: {'s2', 's3'},
      );
      expect(sortedDesc.map((s) => s.id).toList(), ['s3', 's2', 's1', 's4']);
    },
  );

  test('named queues need no track lookup for name or added time sorting', () {
    final first = PlaybackSession(
      id: 'first',
      currentTrackPath: '/audio/first.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    )..playbackQueue = PlaybackQueueDefinition(name: 'Beta', entries: []);
    final second = PlaybackSession(
      id: 'second',
      currentTrackPath: '/audio/second.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026, 1, 2),
      state: const PlayerState(false, ProcessingState.ready),
    )..playbackQueue = PlaybackQueueDefinition(name: 'Alpha', entries: []);
    final sessions = [
      PlaybackSessionSnapshot.fromRuntime(first),
      PlaybackSessionSnapshot.fromRuntime(second),
    ];

    for (final criterion in [
      PlaylistSortCriterion.name,
      PlaylistSortCriterion.addedAt,
    ]) {
      final sorted = sortPlaylistSessions(
        sessions: sessions,
        criterion: criterion,
        ascending: true,
        groupByLibrary: false,
        library: library,
        trackForSession: (_) => fail('Unused track lookup for $criterion'),
      );
      expect(sorted, hasLength(2));
    }
  });

  test('voice actor detail changes reorder playlist sessions', () {
    final firstTrack = testMusicTrack(
      name: 'First',
      path: '/audio/first.mp3',
      groupKey: '/audio/first',
      groupTitle: 'First',
      isSingle: true,
    );
    final secondTrack = testMusicTrack(
      name: 'Second',
      path: '/audio/second.mp3',
      groupKey: '/audio/second',
      groupTitle: 'Second',
      isSingle: true,
    );
    final sessions = [_session('first'), _session('second')];

    void updateDetail(MusicTrack track, String voiceActor) {
      library.detailCacheService.markChanged(
        AudioDetail(
          target: library.audioDetailTargetForTrack(track),
          rjCode: '',
          workTitle: '',
          circleName: '',
          voiceActors: [voiceActor],
          tags: const [],
        ),
      );
    }

    List<String> sortedIds() => sortPlaylistSessions(
      sessions: sessions,
      criterion: PlaylistSortCriterion.voiceActor,
      ascending: true,
      groupByLibrary: false,
      library: library,
      trackForSession: (session) =>
          session.id == 'first' ? firstTrack : secondTrack,
    ).map((session) => session.id).toList();

    updateDetail(firstTrack, 'Zeta');
    updateDetail(secondTrack, 'Alpha');
    expect(sortedIds(), ['second', 'first']);

    updateDetail(firstTrack, 'Alpha');
    updateDetail(secondTrack, 'Zeta');
    expect(sortedIds(), ['first', 'second']);
  });
}
