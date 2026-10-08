import 'package:flutter_test/flutter_test.dart';
import 'dart:collection';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

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
  for (final isDirectory in [false, true]) {
    test(
      'work ${isDirectory ? 'folder' : 'file'} rename retargets every playback queue',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'work_queue_rename_',
        );
        addTearDown(() => root.delete(recursive: true));
        final folder = await Directory(path.join(root.path, 'disc')).create();
        final media = File(path.join(folder.path, 'original.mp3'));
        await media.writeAsString('media');
        final nested = await Directory(path.join(folder.path, 'nested')).create();
        final child = File(path.join(nested.path, 'child.mp3'));
        await child.writeAsString('child');
        final database = await AppRuntimeTestFixture.installSharedDatabase();
        addTearDown(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(nativePlaybackChannel, (_) async {
          return <String, Object?>{'ok': true, 'value': null};
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(nativePlaybackChannel, null),
        );
        final repository = TestPersistenceRepository();
        final graph = createTestRuntimeGraph(persistenceRepository: repository);
        addTearDown(graph.runtime.dispose);
        final original = MusicTrack(
          path: media.path,
          displayName: 'original',
          groupKey: folder.path,
          groupTitle: 'disc',
          groupSubtitle: '',
          isSingle: false,
        );
        final descendant = MusicTrack(
          path: child.path,
          displayName: 'child',
          groupKey: nested.path,
          groupTitle: 'nested',
          groupSubtitle: '',
          isSingle: false,
        );
        graph.library.addWatchedFolder(root.path, notify: false);
        graph.library.addTracks(
          [original, descendant],
          notify: false,
          persist: false,
        );
        final first = graph.playback.createTrackSession(
          original,
          customQueueTracks: [original, descendant],
        );
        final second = graph.playback.createPlaybackQueue('Work queue');
        await graph.playback.addWorkToPlaybackQueue(
          second.id,
          title: 'disc',
          tracks: [original, descendant],
          workRootPath: folder.path,
        );
        graph.playback.configurePersistence(enabled: true);
        await graph.playback.savePersistedState();
        final renamed = await graph.audioPaths.renameWorkEntryToName(
          libraryRootPath: root.path,
          entryPath: isDirectory ? folder.path : media.path,
          targetName: 'renamed',
          isMedia: !isDirectory,
          isDirectory: isDirectory,
        );
        final nextPath = isDirectory
            ? path.join(renamed, 'original.mp3')
            : renamed;
        final nextChildPath = isDirectory
            ? path.join(renamed, 'nested', 'child.mp3')
            : child.path;
        for (final session in [first, second]) {
          expect(
            graph.playback.sessionById(session.id)!.currentTrackPath,
            nextPath,
          );
          expect(
            graph.playback
                .sessionById(session.id)!
                .customQueueTracks!
                .map((track) => track.path),
            [nextPath, nextChildPath],
          );
        }
        expect(await File(nextPath).readAsString(), 'media');
        expect(await File(nextChildPath).readAsString(), 'child');
        await graph.playback.savePersistedState();
        final saved = await repository.loadAllSessions();
        expect(saved, hasLength(2));
        for (final session in saved) {
          expect(session.trackPath, nextPath);
          expect(
            (session.customQueueTracks ?? session.playbackQueue!.expandedTracks)
                .map((track) => track.path),
            [nextPath, nextChildPath],
          );
        }
        final savedQueue = saved.singleWhere((item) => item.id == second.id);
        expect(savedQueue.customQueueTracks, isNull);
        expect(
          savedQueue.playbackQueue!.expandedTracks.map((track) => track.path),
          [nextPath, nextChildPath],
        );
        expect(
          savedQueue.playbackQueue!.entries.single.workRootPath,
          isDirectory ? renamed : folder.path,
        );
        await graph.runtime.dispose();

        final restarted = PlaybackFacade.create(databaseRepository: repository);
        addTearDown(restarted.dispose);
        await restarted.loadPersistedState();
        expect(restarted.sessions, hasLength(2));
        for (final id in [first.id, second.id]) {
          final session = restarted.sessionById(id)!;
          expect(session.currentTrackPath, nextPath);
          expect(
            (session.customQueueTracks ?? session.playbackQueue!.expandedTracks)
                .map((track) => track.path),
            [nextPath, nextChildPath],
          );
        }
        final restoredQueue = restarted.sessionById(second.id)!;
        expect(restoredQueue.currentQueueIndex, 0);
        expect(restoredQueue.customQueueTracks, isNull);
        expect(
          restoredQueue.playbackQueue!.expandedTracks.map((track) => track.path),
          [nextPath, nextChildPath],
        );
        expect(
          restoredQueue.playbackQueue!.entries.single.workRootPath,
          isDirectory ? renamed : folder.path,
        );
      },
    );
  }
  test('selected local track keeps every work audio in the switcher', () async {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    final tracks = [
      for (final path in [
        '/library/work/first.mp3',
        '/library/work/disc/second.mp3',
        '/library/work/disc/third.mp3',
      ])
        MusicTrack(
          path: path,
          displayName: path,
          groupKey: '/library/work',
          groupTitle: 'Work',
          groupSubtitle: '',
          isSingle: false,
        ),
    ];
    graph.library.addWatchedFolder('/library/work', notify: false);
    graph.library.addTracks(tracks, notify: false, persist: false);

    expect(await graph.playback.addTrackToPlaylist(tracks[1]), isTrue);
    final session = graph.playback.ordinarySessions.single;
    expect(session.currentTrackPath, tracks[1].path);
    expect(session.customQueueTracks, isNull);
    expect(
      graph.audioPaths.tracksForSessionSwitcher(session.id).map((t) => t.path),
      graph.audioPaths.tracksInSameWork(tracks[0].path).map((t) => t.path),
    );
  });

  test('selected ASMR track enables the full work switcher', () async {
    final graph = createTestRuntimeGraph();
    addTearDown(graph.runtime.dispose);
    MusicTrack remote(String name) => MusicTrack(
      path: 'https://example.test/$name.mp3',
      displayName: name,
      groupKey: 'asmr-work-7',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
      remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
      remoteMetadata: {'id': 7, 'trackRelativePath': '$name.mp3'},
    );
    final selected = remote('selected');
    final sibling = remote('sibling');

    expect(
      await graph.playback.addTrackToPlaylist(
        selected,
        workTracks: [selected, sibling],
      ),
      isTrue,
    );
    final session = graph.playback.ordinarySessions.single;
    expect(graph.audioPaths.hasOtherTracksInSameWork(selected.path), isTrue);
    expect(
      graph.audioPaths.tracksForSessionSwitcher(session.id).map((t) => t.path),
      [selected.path, sibling.path],
    );
  });

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

  test('command lookup resolves equivalent indexed library paths', () {
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
      same(local),
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
