
import '../models/music_track.dart';
import 'audio_state_services.dart';
import 'library_scanner_service.dart';
import 'path_matcher.dart';
import 'path_display.dart';

class ScanMergeIsolatePayload {
  const ScanMergeIsolatePayload({
    required this.scannedTracks,
    required this.library,
    required this.libraryRoot,
    required this.promoteRootTracksToSingles,
    required this.i18nImportedFiles,
    required this.i18nManuallySelectedFiles,
    required this.exclusionMatcher,
  });

  final List<ScannedTrack> scannedTracks;
  final List<MusicTrack> library;
  final String? libraryRoot;
  final bool promoteRootTracksToSingles;
  final String i18nImportedFiles;
  final String i18nManuallySelectedFiles;
  final LibraryExclusionMatcher? exclusionMatcher;
}

class ScanMergeIsolateResult {
  const ScanMergeIsolateResult({
    required this.trackBatch,
    required this.entryBatch,
    required this.duplicatesCount,
  });
  final List<MusicTrack> trackBatch;
  final List<MusicTrack> entryBatch;
  final int duplicatesCount;
}

ScanMergeIsolateResult processScannedTracksInIsolate(ScanMergeIsolatePayload payload) {
  final libraryRoot = payload.libraryRoot;
  final promoteRootTracksToSingles = payload.promoteRootTracksToSingles;
  
  final existingTracks = <String, MusicTrack>{};
  for (final track in payload.library) {
    existingTracks[PathMatcher.normalize(track.path)] = track;
  }

  bool trackIsDirectlyInFolder(String folderPath, ScannedTrack track) {
    return PathMatcher.equalsNormalized(track.groupKey, folderPath) || track.groupKey == folderPath;
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
      duration: existing.duration == Duration.zero ? track.duration : existing.duration,
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
        existing.modifiedAt != scanned.modifiedAt ||
        (existing.coverCachePath == null && scanned.coverCachePath != null) ||
        (existing.lyricsPath == null && scanned.lyricsPath != null) ||
        (existing.manualCoverPath == null && scanned.manualCoverPath != null) ||
        (existing.duration == Duration.zero && scanned.duration != Duration.zero);
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
    if (promoteRootTracksToSingles && libraryRoot != null && trackIsDirectlyInFolder(libraryRoot, scanned)) {
      converted = MusicTrack(
        path: scanned.path,
        displayName: scanned.displayName ?? PathDisplay.fileName(scanned.path, withoutExtension: true),
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
        displayName: scanned.displayName ?? PathDisplay.fileName(scanned.path, withoutExtension: true),
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
      if (libraryRoot == null || payload.exclusionMatcher == null || !payload.exclusionMatcher!.isExcluded(converted.path)) {
        trackBatch.add(converted);
      }
    } else {
      duplicates++;
    }
  }

  return ScanMergeIsolateResult(
    trackBatch: trackBatch,
    entryBatch: entryBatch,
    duplicatesCount: duplicates,
  );
}
