import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/features/player/domain/audio_effects.dart';
import 'package:nameless_audio/features/library/domain/library_node.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/player/domain/playback_queue.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/app/presentation/screen_view_models.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';

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

  test('session detail uses pause icon while loading or retryable', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3');
    addTearDown(detailSession.dispose);

    SessionDetailViewState? view() => sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );

    expect(view()?.showPauseIcon, isFalse);

    detailSession.isLoading = true;
    expect(view()?.showPauseIcon, isTrue);

    detailSession
      ..isLoading = false
      ..playbackError = 'load failed';
    expect(view()?.showPauseIcon, isTrue);
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
    detailSession
      ..setOptimisticPosition(const Duration(seconds: 42))
      ..bufferedPosition = const Duration(minutes: 2)
      ..setOptimisticDuration(const Duration(minutes: 6));

    final updatedView = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    expect(updatedView, originalView);
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
      expect(updatedView, originalView);
    },
  );

  test('prepared transport intent changes icon without showing loading', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3')
      ..loadedPath = '/tracks/detail.mp3'
      ..beginTransportCommand(commandId: 1, playing: true);
    addTearDown(detailSession.dispose);

    final detailState = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );
    final cardState = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
    )['detail'];

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
    detailSession
      ..volume = 0.6
      ..speed = 1.5
      ..channelSwapEnabled = true
      ..audioEffects = const AudioEffectsState(
        skipSilenceEnabled: true,
        eqEnabled: true,
        eqPresetId: 'custom',
        eqBandLevels: <int, double>{1000: 3},
        panning: 0.4,
      )
      ..eqCapabilities = const EqCapabilities(
        supported: true,
        bands: <EqBandInfo>[EqBandInfo(frequencyHz: 1000)],
      );
    final updated = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [detailSession]),
      'detail',
    );

    expect(updated, isNot(original));
    expect(updated?.volume, 0.6);
    expect(updated?.speed, 1.5);
    expect(updated?.channelSwapEnabled, isTrue);
    expect(updated?.audioEffects.skipSilenceEnabled, isTrue);
    expect(updated?.audioEffects.eqEnabled, isTrue);
    expect(updated?.audioEffects.panning, 0.4);
    expect(updated?.eqCapabilities.supported, isTrue);
  });

  test('paused playback queue card state tracks queue color changes', () {
    final queueSession = session(id: 'queue', path: '/tracks/queue.mp3')
      ..playbackQueue = const PlaybackQueueDefinition(
        name: 'Queue',
        entries: <PlaybackQueueEntry>[],
      );
    addTearDown(queueSession.dispose);

    final original = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [queueSession]),
    )['queue'];
    queueSession.playbackQueue = queueSession.playbackQueue?.copyWith(
      colorValue: 0xFF336699,
    );
    final updated = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [queueSession]),
    )['queue'];

    expect(queueSession.effectivePlaying, isFalse);
    expect(updated, isNot(original));
    expect(updated?.queueColorValue, 0xFF336699);
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

    final original = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [focused, other]),
    )['focused'];
    other.volume = 0.25;
    final unchanged = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [focused, other]),
    )['focused'];
    focused.loopMode = SessionLoopMode.folderSequential;
    final changed = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [focused, other]),
    )['focused'];

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
