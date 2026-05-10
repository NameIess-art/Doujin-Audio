import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/library_node.dart';
import 'package:nameless_audio/models/music_track.dart';
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

  test('library search index caches by revision and reuses matching folder nodes', () {
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
  });

  test('library search index invalidates stale results when revision changes', () {
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
  });

  test('playlist header state only reflects relevant playback and timer fields', () {
    const playbackState = PlaybackStateSliceData(
      playingSessionCount: 2,
      isInitialized: true,
    );
    const timerState = TimerStateSliceData(
      duration: Duration(minutes: 30),
      remaining: Duration(minutes: 12),
      active: true,
    );

    final headerState = playlistHeaderStateFromSlices(playbackState, timerState);

    expect(headerState.sessionCount, 0);
    expect(headerState.playingCount, 2);
    expect(headerState.timerRemaining, const Duration(minutes: 12));
    expect(headerState.hasTimer, isTrue);
  });

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

    expect(first, same);
    expect(nextTrack, isNot(first));
  });
}
