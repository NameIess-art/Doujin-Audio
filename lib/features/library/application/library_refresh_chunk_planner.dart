import '../../../core/media/music_track.dart';

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
