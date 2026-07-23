import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';

class LibraryRefreshChunk {
  LibraryRefreshChunk({
    required this.sourceFolderPath,
    required this.libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    List<String> folderPaths = const <String>[],
    List<String> removeWatchedFolders = const <String>[],
    List<String> addWatchedFolders = const <String>[],
    List<String> removeTrackPaths = const <String>[],
    List<String> removeEntryPaths = const <String>[],
    this.progressLabel = '',
    this.duplicateCount = 0,
    this.failureCount = 0,
  }) : tracks = immutableList(tracks),
       folderPaths = immutableList(folderPaths),
       removeWatchedFolders = immutableList(removeWatchedFolders),
       addWatchedFolders = immutableList(addWatchedFolders),
       removeTrackPaths = immutableList(removeTrackPaths),
       removeEntryPaths = immutableList(removeEntryPaths);

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
