import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/player/application/playback_queue_resolver.dart';

void main() {
  const resolver = PlaybackQueueResolver();

  MusicTrack track(String path, String group, String title) {
    return MusicTrack(
      path: path,
      displayName: path,
      groupKey: group,
      groupTitle: title,
      groupSubtitle: title,
      isSingle: false,
    );
  }

  final a1 = track('a1', 'a', 'Alpha');
  final a2 = track('a2', 'a', 'Alpha');
  final b1 = track('b1', 'b', 'Beta');
  final tracksByGroup = <String, List<MusicTrack>>{
    'a': <MusicTrack>[a1, a2],
    'b': <MusicTrack>[b1],
  };

  String? resolve(
    MusicTrack? current, {
    required SessionLoopMode mode,
    bool forward = true,
    List<int> randomValues = const <int>[0],
  }) {
    var index = 0;
    return resolver.resolveNextPath(
      currentTrack: current,
      forward: forward,
      loopMode: mode,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
      nextInt: (_) => randomValues[index++ % randomValues.length],
    );
  }

  test('single loop returns current path', () {
    expect(resolve(a1, mode: SessionLoopMode.single), 'a1');
  });

  test('folder sequential wraps forward and backward within group', () {
    expect(resolve(a1, mode: SessionLoopMode.folderSequential), 'a2');
    expect(
      resolve(a1, mode: SessionLoopMode.folderSequential, forward: false),
      'a2',
    );
  });

  test('sequential play keeps current-folder scope for manual navigation', () {
    expect(resolve(a1, mode: SessionLoopMode.folderOnce), 'a2');
    expect(resolve(a1, mode: SessionLoopMode.folderOnce, forward: false), 'a2');
    expect(SessionLoopMode.folderOnce.isOneShot, isTrue);
    expect(SessionLoopMode.folderOnce.isCrossFolder, isFalse);
    expect(
      SessionLoopMode.folderSequential.nextOrderMode,
      SessionLoopMode.folderOnce,
    );
    expect(
      SessionLoopMode.folderOnce.nextOrderMode,
      SessionLoopMode.folderRandom,
    );
  });

  test('cross sequential walks groups and wraps across boundaries', () {
    expect(resolve(a2, mode: SessionLoopMode.crossSequential), 'b1');
    expect(
      resolve(a1, mode: SessionLoopMode.crossSequential, forward: false),
      'b1',
    );
  });

  test('cross sequential follows provided library order', () {
    expect(
      resolver.resolveNextPath(
        currentTrack: b1,
        forward: true,
        loopMode: SessionLoopMode.crossSequential,
        sortedLibraryTrackPaths: const <String>['b1', 'a2', 'a1'],
        tracksByGroup: tracksByGroup,
        nextInt: (_) => 0,
      ),
      'a2',
    );
  });

  test('cross-folder sequential play keeps the full library scope', () {
    expect(resolve(a2, mode: SessionLoopMode.crossOnce), 'b1');
    expect(SessionLoopMode.crossOnce.isOneShot, isTrue);
    expect(SessionLoopMode.crossOnce.isCrossFolder, isTrue);
    expect(
      SessionLoopMode.crossOnce.toggledScopeMode,
      SessionLoopMode.folderOnce,
    );
  });

  test('cross random retries current track', () {
    expect(
      resolve(
        a1,
        mode: SessionLoopMode.crossRandom,
        randomValues: const <int>[0, 2],
      ),
      'b1',
    );
  });

  test('folder random stays in current group', () {
    expect(
      resolve(
        a1,
        mode: SessionLoopMode.folderRandom,
        randomValues: const <int>[0, 1],
      ),
      'a2',
    );
  });

  test('missing current track returns null', () {
    expect(resolve(null, mode: SessionLoopMode.folderSequential), isNull);
  });

  test('hasAdjacentPath does not consume random values', () {
    var randomCalls = 0;

    final hasAdjacent = resolver.hasAdjacentPath(
      currentTrack: a1,
      forward: true,
      loopMode: SessionLoopMode.crossRandom,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
    );

    expect(hasAdjacent, isTrue);
    expect(randomCalls, 0);

    resolver.resolveNextPath(
      currentTrack: a1,
      forward: true,
      loopMode: SessionLoopMode.crossRandom,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
      nextInt: (_) {
        randomCalls++;
        return 1;
      },
    );

    expect(randomCalls, 1);
  });

  test('custom playback queue advances from queue index with duplicates', () {
    final scope = resolver.resolveScope(
      currentPath: 'a1',
      currentTrack: a1,
      loopMode: SessionLoopMode.folderSequential,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
      customQueueTracks: <MusicTrack>[a1, a2, a1],
      isPlaybackQueue: true,
      currentQueueIndex: 2,
    );

    final next = resolver.resolveAdvance(
      scope: scope,
      forward: true,
      loopMode: SessionLoopMode.folderSequential,
      nextInt: (_) => 0,
    );

    expect(scope.paths, const <String>['a1', 'a2', 'a1']);
    expect(scope.currentIndex, 2);
    expect(next?.path, 'a1');
    expect(next?.queueIndex, 0);
  });

  test('playback queue follows its listed order for single media files', () {
    const audio = MusicTrack(
      path: 'audio',
      displayName: 'audio',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
    );
    const video = MusicTrack(
      path: 'video',
      displayName: 'video',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
      isVideo: true,
    );
    const outro = MusicTrack(
      path: 'outro',
      displayName: 'outro',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
    );
    final scope = resolver.resolveScope(
      currentPath: video.path,
      currentTrack: video,
      loopMode: SessionLoopMode.single,
      sortedLibraryTrackPaths: const <String>[],
      tracksByGroup: const <String, List<MusicTrack>>{},
      customQueueTracks: <MusicTrack>[audio, video, outro],
      isPlaybackQueue: true,
      currentQueueIndex: 1,
    );

    expect(
      resolver.hasAdjacentInScope(
        scope: scope,
        loopMode: SessionLoopMode.single,
      ),
      isTrue,
    );
    expect(
      resolver
          .resolveAdvance(
            scope: scope,
            forward: true,
            loopMode: SessionLoopMode.single,
            nextInt: (_) => 0,
          )
          ?.path,
      outro.path,
    );
    expect(
      resolver
          .resolveAdvance(
            scope: scope,
            forward: false,
            loopMode: SessionLoopMode.single,
            nextInt: (_) => 0,
          )
          ?.path,
      audio.path,
    );
  });

  test('playback queue recovers from a stale native queue index', () {
    const first = MusicTrack(
      path: 'first',
      displayName: 'first',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
    );
    const current = MusicTrack(
      path: 'current',
      displayName: 'current',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
      isVideo: true,
    );
    const next = MusicTrack(
      path: 'next',
      displayName: 'next',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
    );
    final scope = resolver.resolveScope(
      currentPath: current.path,
      currentTrack: current,
      loopMode: SessionLoopMode.folderSequential,
      sortedLibraryTrackPaths: const <String>[],
      tracksByGroup: const <String, List<MusicTrack>>{},
      customQueueTracks: <MusicTrack>[first, current, next],
      isPlaybackQueue: true,
    );

    expect(scope.currentIndex, 1);
    expect(
      resolver
          .resolveAdvance(
            scope: scope,
            forward: true,
            loopMode: SessionLoopMode.folderSequential,
            nextInt: (_) => 0,
          )
          ?.path,
      next.path,
    );
  });

  test('custom non-playback queue filters to current folder scope', () {
    final scope = resolver.resolveScope(
      currentPath: 'a1',
      currentTrack: a1,
      loopMode: SessionLoopMode.folderSequential,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
      customQueueTracks: <MusicTrack>[a1, b1, a2],
      folderKeyForTrack: (track) => track.groupKey,
    );

    final next = resolver.resolveAdvance(
      scope: scope,
      forward: true,
      loopMode: SessionLoopMode.folderSequential,
      nextInt: (_) => 0,
    );

    expect(scope.paths, const <String>['a1', 'a2']);
    expect(next?.path, 'a2');
    expect(next?.queueIndex, 1);
  });

  test('custom cross-folder scope keeps every custom track', () {
    final scope = resolver.resolveScope(
      currentPath: 'a1',
      currentTrack: a1,
      loopMode: SessionLoopMode.crossSequential,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
      customQueueTracks: <MusicTrack>[a1, b1, a2],
      folderKeyForTrack: (track) => track.groupKey,
    );

    expect(scope.paths, const <String>['a1', 'b1', 'a2']);
    expect(
      resolver
          .resolveAdvance(
            scope: scope,
            forward: true,
            loopMode: SessionLoopMode.crossSequential,
            nextInt: (_) => 0,
          )
          ?.path,
      'b1',
    );
  });

  test('scope hasAdjacent does not consume random values', () {
    var randomCalls = 0;
    final scope = resolver.resolveScope(
      currentPath: 'a1',
      currentTrack: a1,
      loopMode: SessionLoopMode.crossRandom,
      sortedLibraryTrackPaths: const <String>['a1', 'a2', 'b1'],
      tracksByGroup: tracksByGroup,
    );

    expect(
      resolver.hasAdjacentInScope(
        scope: scope,
        loopMode: SessionLoopMode.crossRandom,
      ),
      isTrue,
    );
    expect(randomCalls, 0);

    final next = resolver.resolveAdvance(
      scope: scope,
      forward: true,
      loopMode: SessionLoopMode.crossRandom,
      nextInt: (_) {
        randomCalls++;
        return 1;
      },
    );

    expect(next?.path, 'a2');
    expect(randomCalls, 1);
  });
}
