import 'dart:isolate';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/cache/app_cache_service.dart';

const int _audioBytesIsolateThreshold = 500;

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
    final audioLibraryBytes = (await _sumLocalAudioBytes(
      platformUsage.storageRoots,
    )).clamp(0, usedBytes);
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

  Future<int> _sumLocalAudioBytes(List<String> storageRoots) async {
    if (storageRoots.isEmpty) return 0;
    final tracks = _libraryTracks();
    if (tracks.isEmpty) return 0;
    if (tracks.length > _audioBytesIsolateThreshold) {
      final entries = <(String, int)>[
        for (final track in tracks)
          if (track.fileSizeBytes case final size? when size > 0)
            (track.path, size),
      ];
      if (entries.isEmpty) return 0;
      return _sumLocalAudioEntriesInBackground(entries, storageRoots);
    }
    final preparedRoots = _prepareStorageRoots(storageRoots);
    final seen = <String>{};
    var total = 0;
    for (final track in tracks) {
      final size = track.fileSizeBytes;
      if (size == null || size <= 0) continue;
      if (_matchesLocalStorageTrack(track.path, preparedRoots, seen)) {
        total += size;
      }
    }
    return total;
  }
}

typedef _PreparedStorageRoot = ({
  String normalized,
  String? safVolumePrefix,
});

List<_PreparedStorageRoot> _prepareStorageRoots(List<String> storageRoots) => [
  for (final root in storageRoots)
    (
      normalized: PathMatcher.normalize(root),
      safVolumePrefix: PathMatcher.isContentUri(root)
          ? _safVolumePrefix(root)
          : null,
    ),
];

String? _safVolumePrefix(String root) {
  // SAF volume IDs use "primary:Music/...", without a slash after ':'.
  final key = PathMatcher.equivalenceKey(root);
  return key.endsWith(':') ? key : null;
}

bool _matchesLocalStorageTrack(
  String trackPath,
  List<_PreparedStorageRoot> preparedRoots,
  Set<String> seen,
) {
  if (PathMatcher.isRemoteUri(trackPath)) return false;
  // Capacity and categories must describe the same volume. Unknown document
  // providers may be remote or backed by removable storage.
  final trackKey = PathMatcher.equivalenceKey(trackPath);
  if (seen.contains(trackKey)) return false;
  final normalizedTrack = PathMatcher.normalize(trackPath);
  var matched = false;
  for (final root in preparedRoots) {
    if (PathMatcher.isWithinOrEqualNormalized(
          normalizedTrack,
          root.normalized,
        ) ||
        (root.safVolumePrefix != null &&
            trackKey.startsWith(root.safVolumePrefix!))) {
      matched = true;
      break;
    }
  }
  if (!matched) return false;
  return seen.add(trackKey);
}

Future<int> _sumLocalAudioEntriesInBackground(
  List<(String, int)> entries,
  List<String> storageRoots,
) => Isolate.run(
  () => _sumLocalAudioEntries(entries, storageRoots),
  debugName: 'storage_usage_audio_bytes',
);

int _sumLocalAudioEntries(
  List<(String, int)> entries,
  List<String> storageRoots,
) {
  final preparedRoots = _prepareStorageRoots(storageRoots);
  final seen = <String>{};
  var total = 0;
  for (final (trackPath, size) in entries) {
    if (_matchesLocalStorageTrack(trackPath, preparedRoots, seen)) {
      total += size;
    }
  }
  return total;
}
