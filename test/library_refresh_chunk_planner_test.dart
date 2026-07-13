import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/library_node.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/library_refresh_chunk_planner.dart';
import 'package:nameless_audio/services/library_snapshot_cache_service.dart';

void main() {
  MusicTrack track(int index) => MusicTrack(
    path: '/music/$index.mp3',
    displayName: '$index',
    groupKey: '/music',
    groupTitle: 'music',
    groupSubtitle: '/music',
    isSingle: false,
  );

  test('refresh chunks defer structural changes and totals to final chunk', () {
    final chunks = buildLibraryRefreshChunks(
      sourceFolderPath: '/music',
      libraryRoot: '/music',
      sourceLabel: 'music',
      tracks: List<MusicTrack>.generate(3, track),
      folderPaths: const <String>['/music/album'],
      removeWatchedFolders: const <String>['/music/old'],
      addWatchedFolders: const <String>['/music/album'],
      removeTrackPaths: const <String>['/music/deleted.mp3'],
      removeEntryPaths: const <String>['/music/deleted'],
      duplicateCount: 2,
      failureCount: 1,
      progressPrefix: '[1/1]',
      chunkSize: 2,
    );

    expect(chunks, hasLength(2));
    expect(chunks.first.tracks, hasLength(2));
    expect(chunks.first.removeTrackPaths, isEmpty);
    expect(chunks.first.duplicateCount, 0);
    expect(chunks.last.tracks, hasLength(1));
    expect(chunks.last.removeTrackPaths, const <String>['/music/deleted.mp3']);
    expect(chunks.last.removeEntryPaths, const <String>['/music/deleted']);
    expect(chunks.last.duplicateCount, 2);
    expect(chunks.last.failureCount, 1);
    expect(chunks.last.progressLabel, '[1/1] [3/3] music');
  });

  test('empty refresh still emits one structural update chunk', () {
    final chunks = buildLibraryRefreshChunks(
      sourceFolderPath: '/music',
      libraryRoot: '/music',
      sourceLabel: 'music',
      tracks: const <MusicTrack>[],
      folderPaths: const <String>[],
      removeWatchedFolders: const <String>[],
      addWatchedFolders: const <String>[],
      removeTrackPaths: const <String>['/music/deleted.mp3'],
      removeEntryPaths: const <String>[],
      duplicateCount: 0,
      failureCount: 0,
      progressPrefix: '',
    );

    expect(chunks, hasLength(1));
    expect(chunks.single.tracks, isEmpty);
    expect(chunks.single.removeTrackPaths, const <String>[
      '/music/deleted.mp3',
    ]);
    expect(chunks.single.progressLabel, 'music');
  });

  test(
    'derived snapshot builds indexes, natural order, and cards together',
    () {
      final snapshot = buildLibraryDerivedSnapshot(
        LibraryDerivedSnapshotPayload(
          tracks: <MusicTrack>[track(10), track(2), track(1)],
          watchedFolders: const <String>['/music'],
          nodeOrder: const <String>['/music'],
        ),
      );

      expect(snapshot.libraryByPath.keys, contains('/music/10.mp3'));
      expect(snapshot.libraryIndexByPath['/music/2.mp3'], 1);
      expect(snapshot.sortedLibraryTrackPaths, const <String>[
        '/music/1.mp3',
        '/music/2.mp3',
        '/music/10.mp3',
      ]);
      expect(snapshot.tracksByGroup['/music'], hasLength(3));
      expect(snapshot.cardSnapshot.tree, hasLength(1));
      expect(snapshot.cardSnapshot.tree.single.path, '/music');
      expect(
        (snapshot.cardSnapshot.tree.single as FolderNode).children,
        isEmpty,
      );
    },
  );
}
