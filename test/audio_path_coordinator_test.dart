import 'package:flutter_test/flutter_test.dart';
import 'dart:collection';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'support/app_runtime_test_fixture.dart';

class _CountingTracks extends ListBase<MusicTrack> {
  _CountingTracks(this.tracks);
  final List<MusicTrack> tracks;
  int reads = 0;
  @override
  int get length => tracks.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  MusicTrack operator [](int index) {
    reads++;
    return tracks[index];
  }

  @override
  void operator []=(int index, MusicTrack value) =>
      throw UnsupportedError('read only');
}

class _CountingLibrary extends LibraryService {
  int comparisons = 0;
  @override
  int compareTracks(MusicTrack first, MusicTrack second) {
    comparisons++;
    return super.compareTracks(first, second);
  }
}

void main() {
  AppRuntimeTestFixture.initialize();
  for (final count in [100, 1000, 5000]) {
    test(
      'sibling presence visits two matches without sorting $count tracks',
      () {
        final service = _CountingLibrary();
        final graph = createTestRuntimeGraph(libraryService: service);
        addTearDown(graph.runtime.dispose);
        final tracks = List.generate(
          count,
          (i) => MusicTrack(
            path: PathMatcher.normalize('/library/work/$i.mp3'),
            displayName: 'Track $i',
            groupKey: '/library/work',
            groupTitle: 'Work',
            groupSubtitle: '',
            isSingle: false,
          ),
        );
        graph.library.addTracks(tracks, notify: false, persist: false);
        final counted = _CountingTracks(service.library);
        service.library = counted;
        final ordered = graph.audioPaths.tracksInSameWork(tracks.first.path);
        expect(ordered.length, count);
        expect(service.comparisons, greaterThan(0));
        counted.reads = 0;
        service.comparisons = 0;
        expect(
          graph.audioPaths.hasOtherTracksInSameWork(tracks.first.path),
          isTrue,
        );
        expect(counted.reads, 0);
        expect(service.comparisons, 0);
        expect(graph.audioPaths.tracksInSameWork(tracks.first.path), ordered);
      },
    );
  }

  test('sibling lookup skips unrelated tracks and reuses the work cache', () {
    final service = _CountingLibrary();
    final graph = createTestRuntimeGraph(libraryService: service);
    addTearDown(graph.runtime.dispose);
    final tracks = <MusicTrack>[
      for (var index = 0; index < 5000; index++)
        MusicTrack(
          path: '/other/$index.mp3',
          displayName: '$index',
          groupKey: '/other',
          groupTitle: 'Other',
          groupSubtitle: '',
          isSingle: true,
        ),
      for (var index = 0; index < 2; index++)
        MusicTrack(
          path: PathMatcher.normalize('/library/work/disc/$index.mp3'),
          displayName: 'Work $index',
          groupKey: '/library/work/disc',
          groupTitle: 'Work',
          groupSubtitle: '',
          isSingle: false,
        ),
    ];
    graph.library.addWatchedFolder('/library/work', notify: false);
    graph.library.addTracks(tracks, notify: false, persist: false);
    final counted = _CountingTracks(service.library);
    service.library = counted;
    final path = tracks[5000].path;
    expect(graph.audioPaths.cachedHasOtherTracksInSameWork(path), isTrue);
    expect(graph.audioPaths.hasOtherTracksInSameWork(path), isTrue);
    expect(counted.reads, 0);
    expect(graph.audioPaths.cachedHasOtherTracksInSameWork(path), isTrue);
    expect(
      graph.audioPaths
          .tracksForSessionSwitcher(
            graph.playback.createTrackSession(tracks[5000]).id,
          )
          .map((track) => track.path),
      [tracks[5000].path, tracks[5001].path],
    );
    counted.reads = 0;
    expect(graph.audioPaths.tracksInSameWork(path).length, 2);
    expect(counted.reads, 0);
  });

  test(
    'cross-folder work cache invalidates when library structure changes',
    () {
      final graph = createTestRuntimeGraph();
      addTearDown(graph.runtime.dispose);
      MusicTrack track(String path) => MusicTrack(
        path: path,
        displayName: path,
        groupKey: PathMatcher.parentPath(path)!,
        groupTitle: 'Work',
        groupSubtitle: '',
        isSingle: false,
      );
      final first = track('/library/work/one/1.mp3');
      final second = track('/library/work/two/2.mp3');
      graph.library.addWatchedFolder('/library/work', notify: false);
      graph.library.addTracks([first], notify: false, persist: false);
      expect(graph.audioPaths.hasOtherTracksInSameWork(first.path), isFalse);
      expect(
        graph.audioPaths.cachedHasOtherTracksInSameWork(first.path),
        isFalse,
      );
      graph.library.addTracks([second], notify: false, persist: false);
      expect(
        graph.audioPaths.cachedHasOtherTracksInSameWork(first.path),
        isNull,
      );
      expect(graph.audioPaths.hasOtherTracksInSameWork(first.path), isTrue);
      expect(graph.audioPaths.tracksInSameWork(first.path), [first, second]);
    },
  );

  test('Windows work paths use normalized case-insensitive cache keys', () {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    final first = MusicTrack(
      path: r'C:\Music\Work\Disc 1\first.mp3',
      displayName: 'First',
      groupKey: r'C:\Music\Work\Disc 1',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
    );
    final second = MusicTrack(
      path: r'c:\music\work\Disc 2\second.mp3',
      displayName: 'Second',
      groupKey: r'c:\music\work\Disc 2',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
    );
    graph.library.addWatchedFolder(r'C:\Music\Work', notify: false);
    graph.library.addTracks([first, second], notify: false, persist: false);
    expect(graph.audioPaths.hasOtherTracksInSameWork(first.path), isTrue);
    expect(graph.audioPaths.tracksInSameWork(first.path), [first, second]);
  });

  test('SAF work paths include tracks across nested folders', () {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic%2FWork';
    MusicTrack track(String folder, String name) => MusicTrack(
      path: '$root::$folder/$name.mp3',
      displayName: name,
      groupKey: '$root::$folder',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
    );
    final first = track('disc1', 'first');
    final second = track('disc2', 'second');
    graph.library.addWatchedFolder(root, notify: false);
    graph.library.addTracks([first, second], notify: false, persist: false);
    expect(graph.audioPaths.hasOtherTracksInSameWork(first.path), isTrue);
    expect(graph.audioPaths.tracksInSameWork(first.path), [first, second]);
  });

  test('sibling presence preserves single, remote, and missing behavior', () {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    for (final paths in [
      ['/single.mp3'],
      ['https://example.com/one.mp3', 'https://example.com/two.mp3'],
    ]) {
      final tracks = paths
          .map(
            (value) => MusicTrack(
              path: value,
              displayName: value,
              groupKey: 'remote',
              groupTitle: '',
              groupSubtitle: '',
              isSingle: paths.length == 1,
            ),
          )
          .toList();
      graph.playback.createTrackSession(
        tracks.first,
        customQueueTracks: tracks,
      );
      expect(
        graph.audioPaths.hasOtherTracksInSameWork(paths.first),
        graph.audioPaths.tracksInSameWork(paths.first).length > 1,
      );
    }
    expect(graph.audioPaths.hasOtherTracksInSameWork('/missing'), isFalse);
  });
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
