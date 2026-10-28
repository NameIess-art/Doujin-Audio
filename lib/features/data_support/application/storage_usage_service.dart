import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/cache/app_cache_service.dart';

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
    Future<int> Function()? cacheBytes,
  }) : _fileCacheGateway = fileCacheGateway,
       _libraryTracks = libraryTracks,
       _cacheBytes = cacheBytes;

  final FileCachePlatformGateway _fileCacheGateway;
  final List<MusicTrack> Function() _libraryTracks;
  final Future<int> Function()? _cacheBytes;

  Future<StorageUsageSnapshot> load() async {
    final platformUsage = await _fileCacheGateway.readStorageUsage();
    if (platformUsage == null ||
        platformUsage.totalBytes <= 0 ||
        platformUsage.availableBytes < 0) {
      return const StorageUsageSnapshot.unavailable();
    }

    final totalBytes = platformUsage.totalBytes;
    final availableBytes = platformUsage.availableBytes.clamp(0, totalBytes);
    final usedBytes = totalBytes - availableBytes;
    final audioLibraryBytes = _sumLocalAudioBytes(
      platformUsage.storageRoots,
    ).clamp(0, usedBytes);
    final remainingAfterAudio = usedBytes - audioLibraryBytes;
    final cacheBytes =
        await (_cacheBytes?.call() ??
            AppCacheService.estimateCacheBytes(
              storageRoots: platformUsage.storageRoots,
            ));
    final applicationCacheBytes = cacheBytes.clamp(0, remainingAfterAudio);
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

  int _sumLocalAudioBytes(List<String> storageRoots) {
    final seen = <String>{};
    var total = 0;
    for (final track in _libraryTracks()) {
      if (PathMatcher.isRemoteUri(track.path)) continue;
      // Capacity and categories must describe the same volume. Unknown document
      // providers may be remote or backed by removable storage.
      final trackKey = PathMatcher.equivalenceKey(track.path);
      if (!storageRoots.any((root) {
        if (PathMatcher.isWithinOrEqual(track.path, root)) return true;
        if (!PathMatcher.isContentUri(root)) return false;
        // SAF volume IDs use "primary:Music/...", without a slash after ':'.
        final rootKey = PathMatcher.equivalenceKey(root);
        return rootKey.endsWith(':') && trackKey.startsWith(rootKey);
      })) {
        continue;
      }
      final size = track.fileSizeBytes;
      if (size == null || size <= 0) continue;
      if (!seen.add(trackKey)) continue;
      total += size;
    }
    return total;
  }
}
