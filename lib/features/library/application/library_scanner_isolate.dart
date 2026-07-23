import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import 'library_scan_models.dart';
import 'library_state_models.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';

class ScanMergeIsolatePayload {
  ScanMergeIsolatePayload({
    required List<ScannedTrack> scannedTracks,
    required List<MusicTrack> library,
    required this.libraryRoot,
    required this.promoteRootTracksToSingles,
    required this.i18nImportedFiles,
    required this.i18nManuallySelectedFiles,
    required this.exclusionMatcher,
    this.sourceFolderPath,
    this.allowRemoval = false,
    Set<String> retainedTrackPaths = const <String>{},
    Set<String> retainedEntryPaths = const <String>{},
    this.entrySnapshot,
  }) : scannedTracks = immutableList(scannedTracks),
       library = immutableList(library),
       retainedTrackPaths = immutableSet(retainedTrackPaths),
       retainedEntryPaths = immutableSet(retainedEntryPaths);

  final List<ScannedTrack> scannedTracks;
  final List<MusicTrack> library;
  final String? libraryRoot;
  final bool promoteRootTracksToSingles;
  final String i18nImportedFiles;
  final String i18nManuallySelectedFiles;
  final LibraryExclusionMatcher? exclusionMatcher;
  final String? sourceFolderPath;
  final bool allowRemoval;
  final Set<String> retainedTrackPaths;
  final Set<String> retainedEntryPaths;
  final LibraryEntrySnapshot? entrySnapshot;
}

class ScanMergeIsolateResult {
  ScanMergeIsolateResult({
    required List<MusicTrack> trackBatch,
    required List<MusicTrack> entryBatch,
    required this.duplicatesCount,
    List<String> removedTrackPaths = const <String>[],
    List<String> removedEntryPaths = const <String>[],
  }) : trackBatch = immutableList(trackBatch),
       entryBatch = immutableList(entryBatch),
       removedTrackPaths = immutableList(removedTrackPaths),
       removedEntryPaths = immutableList(removedEntryPaths);
  final List<MusicTrack> trackBatch;
  final List<MusicTrack> entryBatch;
  final int duplicatesCount;
  final List<String> removedTrackPaths;
  final List<String> removedEntryPaths;
}

ScanMergeIsolateResult processScannedTracksInIsolate(
  ScanMergeIsolatePayload payload,
) {
  final libraryRoot = payload.libraryRoot;
  final promoteRootTracksToSingles = payload.promoteRootTracksToSingles;

  final existingTracks = <String, MusicTrack>{};
  for (final track in payload.library) {
    existingTracks[PathMatcher.normalize(track.path)] = track;
  }

  bool trackIsDirectlyInFolder(String folderPath, ScannedTrack track) {
    return PathMatcher.equalsNormalized(track.groupKey, folderPath) ||
        track.groupKey == folderPath;
  }

  MusicTrack canonicalizeTrackPath(MusicTrack track) {
    final existing = existingTracks[PathMatcher.normalize(track.path)];
    if (existing == null || existing.path == track.path) return track;
    return MusicTrack(
      path: existing.path,
      displayName: track.displayName,
      groupKey: track.groupKey,
      groupTitle: track.groupTitle,
      groupSubtitle: track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
      lastPlayedPosition: existing.lastPlayedPosition,
      lastPlayedAt: existing.lastPlayedAt,
      isFavorite: existing.isFavorite,
      tags: existing.tags,
      coverCachePath: existing.coverCachePath ?? track.coverCachePath,
      lyricsPath: existing.lyricsPath ?? track.lyricsPath,
      manualCoverPath: existing.manualCoverPath ?? track.manualCoverPath,
      remoteCoverUrl: existing.remoteCoverUrl,
      remoteMetadataKind: existing.remoteMetadataKind,
      remoteMetadata: existing.remoteMetadata,
      duration: existing.duration == Duration.zero
          ? track.duration
          : existing.duration,
    );
  }

  bool mergedTrackHasChanges(MusicTrack existing, MusicTrack scanned) {
    return existing.displayName != scanned.displayName ||
        existing.groupKey != scanned.groupKey ||
        existing.groupTitle != scanned.groupTitle ||
        existing.groupSubtitle != scanned.groupSubtitle ||
        existing.isSingle != scanned.isSingle ||
        existing.isVideo != scanned.isVideo ||
        existing.fileSizeBytes != scanned.fileSizeBytes ||
        existing.modifiedAt?.millisecondsSinceEpoch !=
            scanned.modifiedAt?.millisecondsSinceEpoch ||
        (existing.coverCachePath == null && scanned.coverCachePath != null) ||
        (existing.lyricsPath == null && scanned.lyricsPath != null) ||
        (existing.manualCoverPath == null && scanned.manualCoverPath != null) ||
        (existing.duration == Duration.zero &&
            scanned.duration != Duration.zero);
  }

  bool trackNeedsRefresh(MusicTrack nextTrack) {
    final existing = existingTracks[PathMatcher.normalize(nextTrack.path)];
    return existing == null || mergedTrackHasChanges(existing, nextTrack);
  }

  final trackBatch = <MusicTrack>[];
  final entryBatch = <MusicTrack>[];
  var duplicates = 0;

  for (final scanned in payload.scannedTracks) {
    MusicTrack converted;
    if (promoteRootTracksToSingles &&
        libraryRoot != null &&
        trackIsDirectlyInFolder(libraryRoot, scanned)) {
      converted = MusicTrack(
        path: scanned.path,
        displayName:
            scanned.displayName ??
            PathDisplay.fileName(scanned.path, withoutExtension: true),
        groupKey: '__single_files__',
        groupTitle: payload.i18nImportedFiles,
        groupSubtitle: payload.i18nManuallySelectedFiles,
        isSingle: true,
        isVideo: scanned.isVideo,
        scannedAt: scanned.scannedAt ?? DateTime.now(),
        fileSizeBytes: scanned.fileSizeBytes,
        modifiedAt: scanned.modifiedAt,
      );
    } else {
      converted = MusicTrack(
        path: scanned.path,
        displayName:
            scanned.displayName ??
            PathDisplay.fileName(scanned.path, withoutExtension: true),
        groupKey: scanned.groupKey,
        groupTitle: scanned.groupTitle,
        groupSubtitle: scanned.groupSubtitle,
        isSingle: scanned.isSingle,
        isVideo: scanned.isVideo,
        scannedAt: scanned.scannedAt ?? DateTime.now(),
        fileSizeBytes: scanned.fileSizeBytes,
        modifiedAt: scanned.modifiedAt,
      );
    }

    converted = canonicalizeTrackPath(converted);

    if (libraryRoot != null) {
      entryBatch.add(converted);
    }

    if (trackNeedsRefresh(converted)) {
      if (libraryRoot == null ||
          payload.exclusionMatcher == null ||
          !payload.exclusionMatcher!.isExcluded(converted.path)) {
        trackBatch.add(converted);
      }
    } else {
      duplicates++;
    }
  }

  final removedTrackPaths = <String>[];
  final removedEntryPaths = <String>[];
  final sourceFolderPath = payload.sourceFolderPath;
  if (payload.allowRemoval && sourceFolderPath != null) {
    final normalizedSourceFolder = PathMatcher.normalize(sourceFolderPath);
    if (payload.retainedTrackPaths.isNotEmpty) {
      final retainedTrackIndex = PathMembershipIndex(
        payload.retainedTrackPaths,
      );
      for (final track in payload.library) {
        if (!PathMatcher.isWithinOrEqualNormalized(
          track.path,
          normalizedSourceFolder,
        )) {
          continue;
        }
        if (!retainedTrackIndex.containsEquivalent(track.path)) {
          removedTrackPaths.add(track.path);
        }
      }
    }

    final snapshot = payload.entrySnapshot;
    if (snapshot != null && payload.retainedEntryPaths.isNotEmpty) {
      final retainedEntryIndex = PathMembershipIndex(
        payload.retainedEntryPaths,
      );
      for (final entry in snapshot.entriesByPath.values) {
        if (!PathMatcher.isWithinOrEqualNormalized(
          entry.path,
          normalizedSourceFolder,
        )) {
          continue;
        }
        final retained = entry.isFolder
            ? retainedEntryIndex.containsDescendantOrEqual(entry.path)
            : retainedEntryIndex.containsEquivalent(entry.path);
        if (!retained) {
          removedEntryPaths.add(entry.path);
        }
      }
    }
  }

  return ScanMergeIsolateResult(
    trackBatch: trackBatch,
    entryBatch: entryBatch,
    duplicatesCount: duplicates,
    removedTrackPaths: List<String>.unmodifiable(removedTrackPaths),
    removedEntryPaths: List<String>.unmodifiable(removedEntryPaths),
  );
}
