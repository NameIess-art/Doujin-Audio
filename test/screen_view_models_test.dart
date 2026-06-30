import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/models/audio_effects.dart';
import 'package:nameless_audio/models/library_node.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/playback_mode.dart';
import 'package:nameless_audio/models/playback_session.dart';
import 'package:nameless_audio/screens/screen_view_models.dart';
import 'package:nameless_audio/services/audio_state_services.dart';

void main() {
  MusicTrack track(String name, String path) {
    return MusicTrack(
      path: path,
      displayName: name,
      groupKey: '/library/rain',
      groupTitle: 'Rain',
      groupSubtitle: '/library/rain',
      isSingle: false,
    );
  }

  List<LibraryNode> buildTree() {
    final folder = FolderNode('Rain Pack', '/library/rain');
    folder.children.addAll([
      TrackNode(track('Soft Rain', '/library/rain/soft_rain.mp3')),
      TrackNode(track('Ocean Waves', '/library/rain/ocean_waves.mp3')),
    ]);
    return <LibraryNode>[folder];
  }

  PlaybackSession session({
    required String id,
    required String path,
    bool playing = false,
    SessionLoopMode loopMode = SessionLoopMode.single,
  }) {
    return PlaybackSession(
      id: id,
      currentTrackPath: path,
      loopMode: loopMode,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(playing, ProcessingState.ready),
    );
  }

  test(
    'library search index caches by revision and reuses matching folder nodes',
    () {
      final index = LibrarySearchIndex();
      final tree = buildTree();
      final folder = tree.single as FolderNode;

      final first = index.resolve(
        tree: tree,
        query: 'rain',
        structureRevision: 1,
      );
      final second = index.resolve(
        tree: tree,
        query: 'rain',
        structureRevision: 1,
      );

      expect(identical(first, second), isTrue);
      expect(identical(first.tree.single, folder), isTrue);
      expect(first.matchCount, 2);
    },
  );

  test(
    'library search index invalidates stale results when revision changes',
    () {
      final index = LibrarySearchIndex();
      final originalTree = buildTree();
      final nextFolder = FolderNode('Rain Pack', '/library/rain')
        ..children.addAll([
          TrackNode(track('Soft Rain', '/library/rain/soft_rain.mp3')),
          TrackNode(track('Ocean Waves', '/library/rain/ocean_waves.mp3')),
          TrackNode(track('Forest Night', '/library/rain/forest_night.mp3')),
        ]);
      final nextTree = <LibraryNode>[nextFolder];

      final original = index.resolve(
        tree: originalTree,
        query: 'forest',
        structureRevision: 1,
      );
      final refreshed = index.resolve(
        tree: nextTree,
        query: 'forest',
        structureRevision: 2,
      );

      expect(original.matchCount, 0);
      expect(refreshed.matchCount, 1);
      expect(identical(original, refreshed), isFalse);
    },
  );

  test('library search index supports multi-term delimiter queries', () {
    final index = LibrarySearchIndex();
    final tree = buildTree();

    final result = index.resolve(
      tree: tree,
      query: 'rain/soft',
      structureRevision: 1,
    );

    expect(result.matchCount, 1);
    final folder = result.tree.single as FolderNode;
    expect(folder.children, hasLength(1));
    expect(
      (folder.children.single as TrackNode).track.displayName,
      'Soft Rain',
    );
  });

  test(
    'playlist header state only reflects relevant playback and timer fields',
    () {
      const playbackState = PlaybackStateSliceData(
        playingSessionCount: 2,
        isInitialized: true,
      );
      const timerState = TimerStateSliceData(
        duration: Duration(minutes: 30),
        remaining: Duration(minutes: 12),
        active: true,
      );

      final headerState = playlistHeaderStateFromSlices(
        playbackState,
        timerState,
      );

      expect(headerState.sessionCount, 0);
      expect(headerState.playingCount, 2);
      expect(headerState.timerRemaining, const Duration(minutes: 12));
      expect(headerState.hasTimer, isTrue);
    },
  );

  test('session cover precache key changes only when render inputs change', () {
    final first = buildSessionCoverPrecacheKey(
      sessionId: 's1',
      trackPath: '/tracks/a.mp3',
      cacheWidth: 1080,
      cacheHeight: 640,
      coverGeneration: 4,
    );
    final same = buildSessionCoverPrecacheKey(
      sessionId: 's1',
      trackPath: '/tracks/a.mp3',
      cacheWidth: 1080,
      cacheHeight: 640,
      coverGeneration: 4,
    );
    final nextTrack = buildSessionCoverPrecacheKey(
      sessionId: 's1',
      trackPath: '/tracks/b.mp3',
      cacheWidth: 1080,
      cacheHeight: 640,
      coverGeneration: 4,
    );
    final nativeSize = buildSessionCoverPrecacheKey(
      sessionId: 's1',
      trackPath: '/tracks/a.mp3',
      cacheWidth: null,
      cacheHeight: null,
      coverGeneration: 4,
    );

    expect(first, same);
    expect(nextTrack, isNot(first));
    expect(nativeSize, contains('|native|native|'));
    expect(nativeSize, isNot(first));
  });

  test('overlay state keeps one visible session in single-thread playback', () {
    final paused = session(id: 'paused', path: '/tracks/a.mp3');
    final playing = session(
      id: 'playing',
      path: '/tracks/b.mp3',
      playing: true,
    );
    addTearDown(paused.dispose);
    addTearDown(playing.dispose);

    final overlay = overlaySessionsFromPlaybackState(
      PlaybackStateSliceData(
        activeSessions: [paused, playing],
        playingSessionCount: 1,
      ),
    );

    expect(overlay.map((session) => session.id), ['playing']);
  });

  test('session detail view state tracks only detail page inputs', () {
    final detailSession = session(
      id: 'detail',
      path: '/tracks/detail.mp3',
      playing: true,
      loopMode: SessionLoopMode.folderSequential,
    );
    addTearDown(detailSession.dispose);

    final detailState = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );

    expect(detailState?.trackPath, '/tracks/detail.mp3');
    expect(detailState?.isPlaying, isTrue);
    expect(detailState?.loopMode, SessionLoopMode.folderSequential);
  });

  test('session detail view state ignores progress-only changes', () {
    final detailSession = session(
      id: 'detail',
      path: '/tracks/detail.mp3',
      playing: true,
    )..setOptimisticDuration(const Duration(minutes: 5));
    addTearDown(detailSession.dispose);

    final originalView = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    final originalShell = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
      ),
      detail: sessionDetailShellViewStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
        'detail',
      ),
      coverGeneration: 1,
    );

    detailSession
      ..setOptimisticPosition(const Duration(seconds: 42))
      ..bufferedPosition = const Duration(minutes: 2)
      ..setOptimisticDuration(const Duration(minutes: 6));

    final updatedView = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    final updatedShell = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
      ),
      detail: sessionDetailShellViewStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
        'detail',
      ),
      coverGeneration: 1,
    );

    expect(updatedView, originalView);
    expect(updatedShell, originalShell);
  });

  test(
    'session detail state ignores unrelated session progress-only changes',
    () {
      final detailSession = session(
        id: 'detail',
        path: '/tracks/detail.mp3',
        playing: true,
      );
      final otherSession = session(
        id: 'other',
        path: '/tracks/other.mp3',
        playing: true,
      )..setOptimisticDuration(const Duration(minutes: 3));
      addTearDown(detailSession.dispose);
      addTearDown(otherSession.dispose);

      final originalState = PlaybackStateSliceData(
        activeSessions: [detailSession, otherSession],
        coverGeneration: 1,
      );
      final originalView = sessionDetailViewStateFromPlaybackState(
        originalState,
        'detail',
      );
      final originalShell = SessionDetailShellState(
        sessionOrder: sessionOrderStateFromPlaybackState(originalState),
        detail: sessionDetailShellViewStateFromPlaybackState(
          originalState,
          'detail',
        ),
        coverGeneration: originalState.coverGeneration,
      );

      otherSession
        ..setOptimisticPosition(const Duration(seconds: 50))
        ..bufferedPosition = const Duration(minutes: 2)
        ..setOptimisticDuration(const Duration(minutes: 4));

      final updatedState = PlaybackStateSliceData(
        activeSessions: [detailSession, otherSession],
        coverGeneration: 1,
      );
      final updatedView = sessionDetailViewStateFromPlaybackState(
        updatedState,
        'detail',
      );
      final updatedShell = SessionDetailShellState(
        sessionOrder: sessionOrderStateFromPlaybackState(updatedState),
        detail: sessionDetailShellViewStateFromPlaybackState(
          updatedState,
          'detail',
        ),
        coverGeneration: updatedState.coverGeneration,
      );

      expect(updatedView, originalView);
      expect(updatedShell, originalShell);
    },
  );

  test('session detail shell ignores transport-only changes', () {
    final detailSession = session(
      id: 'detail',
      path: '/tracks/detail.mp3',
      playing: true,
    );
    addTearDown(detailSession.dispose);

    final original = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
      ),
      detail: sessionDetailShellViewStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
        'detail',
      ),
      coverGeneration: 1,
    );

    detailSession
      ..isLoading = true
      ..volume = 0.6
      ..speed = 1.5
      ..audioEffects = const AudioEffectsState(skipSilenceEnabled: true)
      ..setOptimisticState(playing: false);

    final updated = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
      ),
      detail: sessionDetailShellViewStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [detailSession],
          coverGeneration: 1,
        ),
        'detail',
      ),
      coverGeneration: 1,
    );

    expect(updated, original);
  });

  test('session detail shell tracks track order and cover inputs', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3');
    final otherSession = session(id: 'other', path: '/tracks/other.mp3');
    addTearDown(detailSession.dispose);
    addTearDown(otherSession.dispose);

    final originalState = PlaybackStateSliceData(
      activeSessions: [detailSession, otherSession],
      coverGeneration: 1,
    );
    final original = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(originalState),
      detail: sessionDetailShellViewStateFromPlaybackState(
        originalState,
        'detail',
      ),
      coverGeneration: originalState.coverGeneration,
    );

    detailSession.currentTrackPath = '/tracks/detail-2.mp3';
    final trackChangedState = PlaybackStateSliceData(
      activeSessions: [detailSession, otherSession],
      coverGeneration: 1,
    );
    final trackChanged = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(trackChangedState),
      detail: sessionDetailShellViewStateFromPlaybackState(
        trackChangedState,
        'detail',
      ),
      coverGeneration: trackChangedState.coverGeneration,
    );

    final orderChangedState = PlaybackStateSliceData(
      activeSessions: [otherSession, detailSession],
      coverGeneration: 1,
    );
    final orderChanged = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(orderChangedState),
      detail: sessionDetailShellViewStateFromPlaybackState(
        orderChangedState,
        'detail',
      ),
      coverGeneration: orderChangedState.coverGeneration,
    );

    final coverChangedState = PlaybackStateSliceData(
      activeSessions: [detailSession, otherSession],
      coverGeneration: 2,
    );
    final coverChanged = SessionDetailShellState(
      sessionOrder: sessionOrderStateFromPlaybackState(coverChangedState),
      detail: sessionDetailShellViewStateFromPlaybackState(
        coverChangedState,
        'detail',
      ),
      coverGeneration: coverChangedState.coverGeneration,
    );

    expect(trackChanged, isNot(original));
    expect(orderChanged, isNot(trackChanged));
    expect(coverChanged, isNot(trackChanged));
  });

  test('prepared transport intent changes icon without showing loading', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3')
      ..loadedPath = '/tracks/detail.mp3'
      ..beginTransportCommand(commandId: 1, playing: true);
    addTearDown(detailSession.dispose);

    final detailState = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    final cardState = playlistSessionCardStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );

    expect(detailState?.isPlaying, isTrue);
    expect(detailState?.isLoading, isFalse);
    expect(cardState?.isPlaying, isTrue);
    expect(cardState?.isLoading, isFalse);

    detailSession.isLoading = true;
    final loadingState = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    expect(loadingState?.isLoading, isTrue);
  });

  test('session detail view state tracks console control inputs', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3');
    addTearDown(detailSession.dispose);

    final original = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    detailSession.volume = 0.6;
    detailSession.speed = 1.5;
    detailSession.audioEffects = const AudioEffectsState(
      skipSilenceEnabled: true,
    );
    final updated = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );

    expect(updated, isNot(original));
    expect(updated?.volume, 0.6);
    expect(updated?.speed, 1.5);
    expect(updated?.audioEffects.skipSilenceEnabled, isTrue);
  });

  test('playlist session card state ignores unrelated sessions', () {
    final focused = session(
      id: 'focused',
      path: '/tracks/focused.mp3',
      playing: true,
    );
    final other = session(id: 'other', path: '/tracks/other.mp3');
    addTearDown(focused.dispose);
    addTearDown(other.dispose);

    final original = playlistSessionCardStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [focused, other]),
      'focused',
    );
    other.volume = 0.25;
    final unchanged = playlistSessionCardStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [focused, other]),
      'focused',
    );
    focused.loopMode = SessionLoopMode.folderSequential;
    final changed = playlistSessionCardStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [focused, other]),
      'focused',
    );

    expect(unchanged, original);
    expect(changed, isNot(original));
    expect(changed?.loopMode, SessionLoopMode.folderSequential);
  });

  test('active track paths compare by set contents', () {
    const first = ActiveTrackPaths({'/tracks/a.mp3', '/tracks/b.mp3'});
    const sameOrderChanged = ActiveTrackPaths({
      '/tracks/b.mp3',
      '/tracks/a.mp3',
    });
    const different = ActiveTrackPaths({'/tracks/a.mp3'});

    expect(first, sameOrderChanged);
    expect(first, isNot(different));
    expect(first.contains('/tracks/b.mp3'), isTrue);
  });
}
