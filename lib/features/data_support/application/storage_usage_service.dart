import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

class StorageUsageSnapshot {
  const StorageUsageSnapshot({
    required this.totalBytes,
    required this.audioLibraryBytes,
    required this.applicationCacheBytes,
    required this.otherUsedBytes,
    required this.availableBytes,
    this.isAvailable = true,
  });

  const StorageUsageSnapshot.unavailable()
    : totalBytes = 0,
      audioLibraryBytes = 0,
      applicationCacheBytes = 0,
      otherUsedBytes = 0,
      availableBytes = 0,
      isAvailable = false;

  final int totalBytes;
  final int audioLibraryBytes;
  final int applicationCacheBytes;
  final int otherUsedBytes;
  final int availableBytes;
  final bool isAvailable;

  int get usedBytes => totalBytes - availableBytes;
}

class StorageUsageService {
  const StorageUsageService({
    required FileCachePlatformGateway fileCacheGateway,
    required List<MusicTrack> Function() libraryTracks,
  }) : _fileCacheGateway = fileCacheGateway,
       _libraryTracks = libraryTracks;

  final FileCachePlatformGateway _fileCacheGateway;
  final List<MusicTrack> Function() _libraryTracks;

  Future<StorageUsageSnapshot> load() async {
    final platformUsage = await _fileCacheGateway.readStorageUsage();
    if (platformUsage == null ||
        platformUsage.totalBytes <= 0 ||
        platformUsage.availableBytes < 0 ||
        platformUsage.cacheBytes < 0) {
      return const StorageUsageSnapshot.unavailable();
    }

    final totalBytes = platformUsage.totalBytes;
    final availableBytes = platformUsage.availableBytes.clamp(0, totalBytes);
    final usedBytes = totalBytes - availableBytes;
    final audioLibraryBytes = _sumLocalAudioBytes().clamp(0, usedBytes);
    final remainingAfterAudio = usedBytes - audioLibraryBytes;
    final applicationCacheBytes = platformUsage.cacheBytes.clamp(
      0,
      remainingAfterAudio,
    );
    final otherUsedBytes =
        usedBytes - audioLibraryBytes - applicationCacheBytes;

    return StorageUsageSnapshot(
      totalBytes: totalBytes,
      audioLibraryBytes: audioLibraryBytes,
      applicationCacheBytes: applicationCacheBytes,
      otherUsedBytes: otherUsedBytes,
      availableBytes: availableBytes,
    );
  }

  int _sumLocalAudioBytes() {
    final seen = <String>{};
    var total = 0;
    for (final track in _libraryTracks()) {
      if (PathMatcher.isRemoteUri(track.path)) continue;
      final size = track.fileSizeBytes;
      if (size == null || size <= 0) continue;
      if (!seen.add(PathMatcher.equivalenceKey(track.path))) continue;
      total += size;
    }
    return total;
  }
}
