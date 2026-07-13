import '../models/music_track.dart';
import 'path_matcher.dart';

class LibraryScanRules {
  const LibraryScanRules();

  bool pathsOverlap(String first, String second) {
    return PathMatcher.isWithinOrEqual(first, second) ||
        PathMatcher.isWithinOrEqual(second, first);
  }

  bool isFolderAlreadyInLibrary({
    required String folderPath,
    required Iterable<String> watchedFolders,
    required Iterable<String> watchedLibraries,
    required Iterable<MusicTrack> tracks,
  }) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return watchedFolders.any(
          (value) => pathsOverlap(value, normalizedFolderPath),
        ) ||
        watchedLibraries.any(
          (value) => pathsOverlap(value, normalizedFolderPath),
        ) ||
        tracks.any(
          (track) =>
              pathsOverlap(track.path, normalizedFolderPath) ||
              (track.groupKey != '__single_files__' &&
                  pathsOverlap(track.groupKey, normalizedFolderPath)),
        );
  }

  bool isTrackAlreadyInLibrary({
    required String trackPath,
    required Iterable<String> watchedFolders,
    required Iterable<String> watchedLibraries,
    required Iterable<MusicTrack> tracks,
  }) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    return tracks.any(
          (track) =>
              PathMatcher.equalsNormalized(track.path, normalizedTrackPath),
        ) ||
        watchedFolders.any(
          (value) => PathMatcher.isWithinOrEqual(normalizedTrackPath, value),
        ) ||
        watchedLibraries.any(
          (value) => PathMatcher.isWithinOrEqual(normalizedTrackPath, value),
        ) ||
        tracks.any(
          (track) =>
              track.groupKey != '__single_files__' &&
              PathMatcher.isWithinOrEqual(normalizedTrackPath, track.groupKey),
        );
  }

  bool hasWatchedLibraryOverlap({
    required String folderPath,
    required Iterable<String> watchedLibraries,
  }) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return watchedLibraries.any(
      (value) => pathsOverlap(value, normalizedFolderPath),
    );
  }

  bool isNestedInsideStandaloneFolder({
    required String folderPath,
    required Iterable<String> watchedFolders,
  }) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return watchedFolders.any(
      (value) =>
          PathMatcher.isWithinOrEqual(normalizedFolderPath, value) &&
          !PathMatcher.equalsNormalized(value, normalizedFolderPath),
    );
  }

  List<String> watchedFoldersToPromote({
    required String folderPath,
    required Iterable<String> watchedFolders,
  }) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return watchedFolders
        .where(
          (value) => PathMatcher.isWithinOrEqual(value, normalizedFolderPath),
        )
        .toList(growable: false);
  }

  bool hasUnmanagedLibraryContentOverlap({
    required String folderPath,
    required Iterable<String> promotedFolders,
    required Iterable<MusicTrack> tracks,
  }) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return tracks.any((track) {
      final belongsToPromotedFolder = promotedFolders.any(
        (folderPath) =>
            PathMatcher.isWithinOrEqual(track.path, folderPath) ||
            (track.groupKey != '__single_files__' &&
                PathMatcher.isWithinOrEqual(track.groupKey, folderPath)),
      );
      if (belongsToPromotedFolder) return false;
      return pathsOverlap(track.path, normalizedFolderPath) ||
          (track.groupKey != '__single_files__' &&
              pathsOverlap(track.groupKey, normalizedFolderPath));
    });
  }
}
