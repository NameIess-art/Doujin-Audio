import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  MusicTrack track(String path, String name) => MusicTrack(
    path: path,
    displayName: name,
    groupKey: 'group',
    groupTitle: 'Group',
    groupSubtitle: '',
    isSingle: true,
  );

  test('lookup preserves library and session priority and missing results', () {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    final local = track(PathMatcher.normalize('/library/track.mp3'), 'local');
    final queued = track(local.path, 'queued');
    final remote = track('https://example.com/audio.mp3', 'first');
    final second = track(remote.path, 'second');
    graph.playback.createTrackSession(
      queued,
      customQueueTracks: [queued, remote],
    );
    final secondSession = graph.playback.createTrackSession(
      second,
      customQueueTracks: [second],
    );
    graph.library.addTracks([local], notify: false, persist: false);
    for (final lookup in [
      graph.audioPaths.trackByPath,
      (String value) =>
          graph.audioPaths.trackByPath(value, includeLibraryFallback: false),
    ]) {
      expect(lookup(local.path)?.displayName, 'local');
      expect(lookup(remote.path)?.displayName, 'first');
      expect(lookup('/missing.mp3'), isNull);
    }
    expect(
      graph.audioPaths.sessionTrackForPath(secondSession.id, remote.path),
      same(second),
    );
  });

  test('command lookup does not traverse the normalized library fallback', () {
    final service = LibraryService();
    final graph = createTestRuntimeGraph(libraryService: service);
    addTearDown(graph.runtime.dispose);
    final local = track(r'C:\Audio\Track.mp3', 'local');
    graph.library.addTracks([local], notify: false, persist: false);
    expect(graph.audioPaths.trackByPath(r'c:\audio\track.mp3'), same(local));
    expect(
      graph.audioPaths.trackByPath(
        r'c:\audio\track.mp3',
        includeLibraryFallback: false,
      ),
      isNull,
    );
  });

  test('retargeted queue tracks resolve through both lookup paths', () async {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    final original = track('/old/track.mp3', 'queued');
    graph.playback.createTrackSession(original, customQueueTracks: [original]);
    await graph.playback.retargetPath('/old', '/new');
    for (final lookup in [
      graph.audioPaths.trackByPath,
      (String value) =>
          graph.audioPaths.trackByPath(value, includeLibraryFallback: false),
    ]) {
      expect(lookup('/old/track.mp3')?.displayName, 'queued');
      expect(lookup('/new/track.mp3')?.displayName, 'queued');
    }
  });
}
