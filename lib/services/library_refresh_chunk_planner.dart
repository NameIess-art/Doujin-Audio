import '../models/music_track.dart';

class LibraryRefreshChunk {
  const LibraryRefreshChunk({
    required this.sourceFolderPath,
    required this.libraryRoot,
    this.tracks = const <MusicTrack>[],
    this.folderPaths = const <String>[],
    this.removeWatchedFolders = const <String>[],
    this.addWatchedFolders = const <String>[],
    this.removeTrackPaths = const <String>[],
    this.removeEntryPaths = const <String>[],
    this.progressLabel = '',
    this.duplicateCount = 0,
    this.failureCount = 0,
  });

  final String sourceFolderPath;
  final String libraryRoot;
  final List<MusicTrack> tracks;
  final List<String> folderPaths;
  final List<String> removeWatchedFolders;
  final List<String> addWatchedFolders;
  final List<String> removeTrackPaths;
  final List<String> removeEntryPaths;
  final String progressLabel;
  final int duplicateCount;
  final int failureCount;
}

class LibraryRefreshFolderResult {
  const LibraryRefreshFolderResult({
    required this.sourceFolderPath,
    required this.libraryRoot,
    this.chunks = const <LibraryRefreshChunk>[],
    this.addedCount = 0,
    this.duplicateCount = 0,
    this.failureCount = 0,
  });

  final String sourceFolderPath;
  final String libraryRoot;
  final List<LibraryRefreshChunk> chunks;
  final int addedCount;
  final int duplicateCount;
  final int failureCount;
}

List<LibraryRefreshChunk> buildLibraryRefreshChunks({
  required String sourceFolderPath,
  required String libraryRoot,
  required String sourceLabel,
  required List<MusicTrack> tracks,
  required List<String> folderPaths,
  required List<String> removeWatchedFolders,
  required List<String> addWatchedFolders,
  required List<String> removeTrackPaths,
  required List<String> removeEntryPaths,
  required int duplicateCount,
  required int failureCount,
  required String progressPrefix,
  int chunkSize = 120,
}) {
  assert(chunkSize > 0);
  if (tracks.isEmpty) {
    return <LibraryRefreshChunk>[
      LibraryRefreshChunk(
        sourceFolderPath: sourceFolderPath,
        libraryRoot: libraryRoot,
        folderPaths: folderPaths,
        removeWatchedFolders: removeWatchedFolders,
        addWatchedFolders: addWatchedFolders,
        removeTrackPaths: removeTrackPaths,
        removeEntryPaths: removeEntryPaths,
        progressLabel: [
          if (progressPrefix.isNotEmpty) progressPrefix,
          sourceLabel,
        ].join(' '),
        duplicateCount: duplicateCount,
        failureCount: failureCount,
      ),
    ];
  }

  final chunks = <LibraryRefreshChunk>[];
  for (var index = 0; index < tracks.length; index += chunkSize) {
    final end = (index + chunkSize).clamp(0, tracks.length);
    final isLast = end == tracks.length;
    chunks.add(
      LibraryRefreshChunk(
        sourceFolderPath: sourceFolderPath,
        libraryRoot: libraryRoot,
        tracks: tracks.sublist(index, end),
        folderPaths: isLast ? folderPaths : const <String>[],
        removeWatchedFolders: isLast ? removeWatchedFolders : const <String>[],
        addWatchedFolders: isLast ? addWatchedFolders : const <String>[],
        removeTrackPaths: isLast ? removeTrackPaths : const <String>[],
        removeEntryPaths: isLast ? removeEntryPaths : const <String>[],
        progressLabel: [
          if (progressPrefix.isNotEmpty) progressPrefix,
          '[$end/${tracks.length}]',
          sourceLabel,
        ].join(' '),
        duplicateCount: isLast ? duplicateCount : 0,
        failureCount: isLast ? failureCount : 0,
      ),
    );
  }
  return chunks;
}
