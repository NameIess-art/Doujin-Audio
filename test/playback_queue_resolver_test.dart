import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/playback_mode.dart';
import 'package:nameless_audio/services/playback_queue_resolver.dart';

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
}
