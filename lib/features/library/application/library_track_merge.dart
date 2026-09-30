import '../../../core/media/music_track.dart';

bool mergedLibraryTrackHasChanges(MusicTrack existing, MusicTrack scanned) {
  return existing.displayName != scanned.displayName ||
      existing.groupKey != scanned.groupKey ||
      existing.groupTitle != scanned.groupTitle ||
      existing.groupSubtitle != scanned.groupSubtitle ||
      existing.isSingle != scanned.isSingle ||
      existing.isVideo != scanned.isVideo ||
      existing.fileSizeBytes != scanned.fileSizeBytes ||
      existing.modifiedAt?.millisecondsSinceEpoch !=
          scanned.modifiedAt?.millisecondsSinceEpoch ||
      existing.coverCachePath == null && scanned.coverCachePath != null ||
      existing.lyricsPath == null && scanned.lyricsPath != null ||
      existing.manualCoverPath == null && scanned.manualCoverPath != null ||
      existing.remoteCoverUrl == null && scanned.remoteCoverUrl != null ||
      existing.remoteMetadataKind == null &&
          scanned.remoteMetadataKind != null ||
      existing.remoteMetadata == null && scanned.remoteMetadata != null ||
      existing.duration == Duration.zero && scanned.duration != Duration.zero;
}

MusicTrack mergeLibraryTrackState(MusicTrack existing, MusicTrack scanned) {
  return MusicTrack(
    path: scanned.path,
    displayName: scanned.displayName,
    groupKey: scanned.groupKey,
    groupTitle: scanned.groupTitle,
    groupSubtitle: scanned.groupSubtitle,
    isSingle: scanned.isSingle,
    isVideo: scanned.isVideo,
    scannedAt: scanned.scannedAt,
    fileSizeBytes: scanned.fileSizeBytes,
    modifiedAt: scanned.modifiedAt,
    lastPlayedPosition: existing.lastPlayedPosition,
    lastPlayedAt: existing.lastPlayedAt,
    isFavorite: existing.isFavorite,
    tags: existing.tags,
    coverCachePath: existing.coverCachePath ?? scanned.coverCachePath,
    lyricsPath: existing.lyricsPath ?? scanned.lyricsPath,
    manualCoverPath: existing.manualCoverPath ?? scanned.manualCoverPath,
    remoteCoverUrl: existing.remoteCoverUrl ?? scanned.remoteCoverUrl,
    remoteMetadataKind:
        existing.remoteMetadataKind ?? scanned.remoteMetadataKind,
    remoteMetadata: existing.remoteMetadata ?? scanned.remoteMetadata,
    duration: existing.duration == Duration.zero
        ? scanned.duration
        : existing.duration,
  );
}
