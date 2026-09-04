import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/app/presentation/screen_view_models.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';

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
    folder.addChildren([
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

  PlaybackSessionSnapshot snapshot(PlaybackSession value) =>
      PlaybackSessionSnapshot.fromRuntime(value);

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
        ..addChildren([
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

  test('library search rejects a stale category detail snapshot', () {
    final snapshot = AudioLibraryCategorySnapshot(
      entries: const [],
      tagTerms: const [],
      voiceActorTerms: const [],
      circleTerms: const [],
      structureRevision: 1,
      detailRevision: 2,
    );

    expect(
      currentLibraryCategorySnapshot(snapshot: snapshot, detailRevision: 2),
      same(snapshot),
    );
    expect(
      currentLibraryCategorySnapshot(snapshot: snapshot, detailRevision: 3),
      isNull,
    );
  });

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

  test('library search snapshot returns only ancestors that must expand', () {
    final root = FolderNode('Work', '/library/work');
    final disc = FolderNode('Disc', '/library/work/disc', depth: 1)
      ..addChildren(<LibraryNode>[
        TrackNode(track('Ocean chapter', '/library/work/disc/ocean.mp3')),
        TrackNode(track('Quiet chapter', '/library/work/disc/quiet.mp3')),
      ]);
    root.addChild(disc);

    final result = LibrarySearchIndex().resolve(
      tree: <LibraryNode>[root],
      query: 'ocean',
      structureRevision: 1,
    );

    expect(result.matchCount, 1);
    expect(result.expandedFolderPaths, <String>{
      '/library/work',
      '/library/work/disc',
    });
  });

  test('folder-title matches stay collapsed until the user expands them', () {
    final result = LibrarySearchIndex().resolve(
      tree: buildTree(),
      query: 'rain pack',
      structureRevision: 1,
    );

    expect(result.matchCount, 2);
    expect(result.expandedFolderPaths, isEmpty);
  });

  test(
    'playlist header state only reflects relevant playback and timer fields',
    () {
      final playbackState = PlaybackStateSliceData(
        playingSessionCount: 2,
        isInitialized: true,
      );
      final timerState = TimerStateSliceData(
        duration: const Duration(minutes: 30),
        remaining: const Duration(minutes: 12),
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

  test(
    'playlist structure ignores card-only state but tracks path changes',
    () {
      final playbackSession = session(id: 'structure', path: '/tracks/a.mp3');
      addTearDown(playbackSession.shutdown);

      final pausedStructure = playlistStructureStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [snapshot(playbackSession)],
          isInitialized: true,
        ),
      );
      final pausedCard = playlistSessionCardStateFromSession(
        snapshot(playbackSession),
      );

      playbackSession.state = PlayerState(true, ProcessingState.ready);
      final playingStructure = playlistStructureStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [snapshot(playbackSession)],
          playingSessionCount: 1,
          isInitialized: true,
        ),
      );
      final playingCard = playlistSessionCardStateFromSession(
        snapshot(playbackSession),
      );

      expect(playingStructure, pausedStructure);
      expect(playingCard, isNot(pausedCard));

      playbackSession.lastPlayedAt = DateTime(2026, 1, 2);
      final playedStructure = playlistStructureStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [snapshot(playbackSession)],
          playingSessionCount: 1,
          isInitialized: true,
        ),
      );
      expect(playedStructure, isNot(playingStructure));

      playbackSession.currentTrackPath = '/tracks/b.mp3';
      final nextTrackStructure = playlistStructureStateFromPlaybackState(
        PlaybackStateSliceData(
          activeSessions: [snapshot(playbackSession)],
          isInitialized: true,
        ),
      );
      expect(nextTrackStructure, isNot(playingStructure));
    },
  );

  test('playlist cache extent uses a smaller mobile portrait budget', () {
    expect(
      playlistListCacheExtent(
        headerHeight: 96,
        viewportWidth: 430,
        isLandscape: false,
      ),
      320,
    );
    expect(
      playlistListCacheExtent(
        headerHeight: 96,
        viewportWidth: 900,
        isLandscape: false,
      ),
      896,
    );
    expect(
      playlistListCacheExtent(
        headerHeight: 96,
        viewportWidth: 430,
        isLandscape: true,
      ),
      896,
    );
  });

  test('overlay state shows every session in both playback modes', () {
    final paused = session(id: 'paused', path: '/tracks/a.mp3');
    final playing = session(
      id: 'playing',
      path: '/tracks/b.mp3',
      playing: true,
    );
    addTearDown(paused.shutdown);
    addTearDown(playing.shutdown);

    final singlePlaybackOverlay = overlaySessionsFromPlaybackState(
      PlaybackStateSliceData(
        activeSessions: [snapshot(paused), snapshot(playing)],
        playingSessionCount: 1,
      ),
    );
    final multiPlaybackOverlay = overlaySessionsFromPlaybackState(
      PlaybackStateSliceData(
        activeSessions: [snapshot(paused), snapshot(playing)],
        playingSessionCount: 1,
        multiThreadPlaybackEnabled: true,
      ),
    );

    expect(singlePlaybackOverlay.map((session) => session.id), [
      'paused',
      'playing',
    ]);
    expect(multiPlaybackOverlay.map((session) => session.id), [
      'paused',
      'playing',
    ]);
  });

  test('session detail view state tracks only detail page inputs', () {
    final detailSession = session(
      id: 'detail',
      path: '/tracks/detail.mp3',
      playing: true,
      loopMode: SessionLoopMode.folderSequential,
    );
    addTearDown(detailSession.shutdown);

    final detailState = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
      'detail',
    );

    expect(detailState?.trackPath, '/tracks/detail.mp3');
    expect(detailState?.isPlaying, isTrue);
    expect(detailState?.loopMode, SessionLoopMode.folderSequential);
  });

  test('session detail loading follows the current playback intent', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3');
    addTearDown(detailSession.shutdown);

    SessionDetailViewState? view() => sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
      'detail',
    );

    expect(view()?.showPauseIcon, isFalse);

    detailSession.isLoading = true;
    expect(view()?.isLoading, isFalse);
    expect(view()?.showPauseIcon, isFalse);

    detailSession.isPlaybackStarting = true;
    expect(view()?.isLoading, isTrue);
    expect(view()?.showPauseIcon, isTrue);

    detailSession.beginTransportCommand(commandId: 1, playing: false);
    expect(view()?.isLoading, isFalse);
    expect(view()?.showPauseIcon, isFalse);

    detailSession
      ..isLoading = false
      ..playbackError = 'load failed';
    expect(view()?.showPauseIcon, isFalse);
  });

  test('session detail view state ignores progress-only changes', () {
    final detailSession = session(
      id: 'detail',
      path: '/tracks/detail.mp3',
      playing: true,
    )..setOptimisticDuration(const Duration(minutes: 5));
    addTearDown(detailSession.shutdown);

    final originalView = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
      'detail',
    );
    detailSession
      ..setOptimisticPosition(const Duration(seconds: 42))
      ..bufferedPosition = const Duration(minutes: 2)
      ..setOptimisticDuration(const Duration(minutes: 6));

    final updatedView = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
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
      addTearDown(detailSession.shutdown);
      addTearDown(otherSession.shutdown);

      final originalState = PlaybackStateSliceData(
        activeSessions: [snapshot(detailSession), snapshot(otherSession)],
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
        activeSessions: [snapshot(detailSession), snapshot(otherSession)],
        coverGeneration: 1,
      );
      final updatedView = sessionDetailViewStateFromPlaybackState(
        updatedState,
        'detail',
      );
      expect(updatedView, originalView);
    },
  );

  test(
    'prepared transport intent suppresses transient loading in detail and card state',
    () {
      final detailSession = session(id: 'detail', path: '/tracks/detail.mp3')
        ..loadedPath = '/tracks/detail.mp3'
        ..beginTransportCommand(commandId: 1, playing: true);
      addTearDown(detailSession.shutdown);

      final detailState = sessionDetailViewStateFromPlaybackState(
        PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
        'detail',
      );
      final cardState = playlistSessionCardStatesFromPlaybackState(
        PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
      )['detail'];

      expect(detailState?.isPlaying, isTrue);
      expect(detailState?.isLoading, isFalse);
      expect(cardState?.isPlaying, isTrue);
      expect(cardState?.isLoading, isFalse);

      detailSession.beginLoadingIndicatorThreshold(threshold: Duration.zero);
      final delayedState = sessionDetailViewStateFromPlaybackState(
        PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
        'detail',
      );
      expect(delayedState?.isLoading, isTrue);

      detailSession
        ..beginTransportCommand(commandId: 2, playing: false)
        ..isLoading = false
        ..state = PlayerState(false, ProcessingState.buffering);
      final loadingState = sessionDetailViewStateFromPlaybackState(
        PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
        'detail',
      );
      expect(loadingState?.isLoading, isFalse);
    },
  );

  test('session detail view state tracks console control inputs', () {
    final detailSession = session(id: 'detail', path: '/tracks/detail.mp3');
    addTearDown(detailSession.shutdown);

    final original = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
      'detail',
    );
    detailSession
      ..volume = 0.6
      ..speed = 1.5
      ..channelSwapEnabled = true
      ..audioEffects = AudioEffectsState(
        skipSilenceEnabled: true,
        eqEnabled: true,
        eqPresetId: 'custom',
        eqBandLevels: <int, double>{1000: 3},
        panning: 0.4,
      )
      ..eqCapabilities = EqCapabilities(
        supported: true,
        bands: <EqBandInfo>[const EqBandInfo(frequencyHz: 1000)],
      );
    final updated = sessionDetailViewStateFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(detailSession)]),
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
      ..playbackQueue = PlaybackQueueDefinition(
        name: 'Queue',
        entries: <PlaybackQueueEntry>[],
      );
    addTearDown(queueSession.shutdown);

    final original = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(queueSession)]),
    )['queue'];
    queueSession.playbackQueue = queueSession.playbackQueue?.copyWith(
      colorValue: 0xFF336699,
    );
    final updated = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(activeSessions: [snapshot(queueSession)]),
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
    addTearDown(focused.shutdown);
    addTearDown(other.shutdown);

    final original = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(
        activeSessions: [snapshot(focused), snapshot(other)],
      ),
    )['focused'];
    other.volume = 0.25;
    final unchanged = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(
        activeSessions: [snapshot(focused), snapshot(other)],
      ),
    )['focused'];
    focused.loopMode = SessionLoopMode.folderSequential;
    final changed = playlistSessionCardStatesFromPlaybackState(
      PlaybackStateSliceData(
        activeSessions: [snapshot(focused), snapshot(other)],
      ),
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
