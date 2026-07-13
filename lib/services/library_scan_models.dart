import 'package:path/path.dart' as path;

import 'media_file_support.dart';
import 'path_display.dart';
import 'path_matcher.dart';

class PickedAudioFile {
  const PickedAudioFile({required this.uri, required this.name});
  final String uri;
  final String name;
}

class LibraryScanLabels {
  const LibraryScanLabels({
    required this.chooseMusicFolder,
    required this.chooseLibraryFolder,
    required this.chooseAudioFiles,
    required this.importedFiles,
    required this.manuallySelectedFiles,
  });

  final String chooseMusicFolder;
  final String chooseLibraryFolder;
  final String chooseAudioFiles;
  final String importedFiles;
  final String manuallySelectedFiles;
}

enum LibraryScanOutcomeCode {
  noSources,
  permissionDenied,
  alreadyRunning,
  folderExists,
  libraryExists,
  fileExists,
  cancelled,
  failed,
  noAudio,
  refreshAdded,
  refreshNoChanges,
  importAdded,
  libraryImported,
}

class LibraryScanOutcome {
  const LibraryScanOutcome({
    required this.code,
    required this.source,
    this.details = const <String, Object?>{},
  });

  final LibraryScanOutcomeCode code;
  final String source;
  final Map<String, Object?> details;

  int get addedCount => (details['count'] as int?) ?? 0;
  int get folderCount => (details['folderCount'] as int?) ?? 0;
}

class ScannedTrack {
  const ScannedTrack({
    required this.path,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    required this.isVideo,
    this.displayName,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
  });

  final String path;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final bool isVideo;
  final String? displayName;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;

  factory ScannedTrack.fromPayload(Map<Object?, Object?> payload) {
    final scannedAtMs = payload['scannedAtMs'] as num?;
    final modifiedAtMs = payload['modifiedAtMs'] as num?;
    return ScannedTrack(
      path: payload['path']?.toString() ?? '',
      displayName: payload['displayName']?.toString(),
      groupKey: payload['groupKey']?.toString() ?? '',
      groupTitle: payload['groupTitle']?.toString() ?? '',
      groupSubtitle: payload['groupSubtitle']?.toString() ?? '',
      isSingle: payload['isSingle'] as bool? ?? false,
      isVideo: payload['isVideo'] as bool? ?? false,
      scannedAt: scannedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
      fileSizeBytes: (payload['fileSizeBytes'] as num?)?.toInt(),
      modifiedAt: modifiedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
    );
  }
}

class NativeScanResult {
  const NativeScanResult._({
    required this.ok,
    this.tracks = const <ScannedTrack>[],
    this.paths = const <String>{},
    this.errorCode,
    this.errorMessage,
    this.notSupported = false,
    this.failureCount = 0,
    this.completenessKnown = false,
    this.wasCancelled = false,
  });

  const NativeScanResult.success(
    List<ScannedTrack> tracks,
    Set<String> paths, {
    int failureCount = 0,
    bool completenessKnown = false,
    bool wasCancelled = false,
  }) : this._(
         ok: true,
         tracks: tracks,
         paths: paths,
         failureCount: failureCount,
         completenessKnown: completenessKnown,
         wasCancelled: wasCancelled,
       );

  const NativeScanResult.failed({String? code, String? message})
    : this._(ok: false, errorCode: code, errorMessage: message);

  const NativeScanResult.notSupported() : this._(ok: false, notSupported: true);

  final bool ok;
  final List<ScannedTrack> tracks;
  final Set<String> paths;
  final String? errorCode;
  final String? errorMessage;
  final bool notSupported;
  final int failureCount;
  final bool completenessKnown;
  final bool wasCancelled;

  bool get isComplete =>
      ok && completenessKnown && failureCount == 0 && !wasCancelled;
}

class NativeScanPayload {
  const NativeScanPayload({required this.tracks, required this.paths});
  final List<ScannedTrack> tracks;
  final Set<String> paths;
}

class FolderScanChunk {
  const FolderScanChunk({
    this.tracks = const <ScannedTrack>[],
    this.paths = const <String>{},
    this.folders = const <String>[],
    this.failureCount = 0,
  });

  final List<ScannedTrack> tracks;
  final Set<String> paths;
  final List<String> folders;
  final int failureCount;
}

enum FolderScanStage {
  idle,
  preparing,
  enumerating,
  merging,
  saving,
  loadingCovers;

  static FolderScanStage fromPayload(Object? value) {
    return switch (value?.toString()) {
      'preparing' => FolderScanStage.preparing,
      'enumerating' => FolderScanStage.enumerating,
      'merging' => FolderScanStage.merging,
      'saving' => FolderScanStage.saving,
      'loadingCovers' => FolderScanStage.loadingCovers,
      _ => FolderScanStage.idle,
    };
  }
}

class FolderScanSessionEvent {
  const FolderScanSessionEvent({
    required this.sessionId,
    required this.type,
    required this.chunk,
    required this.generationId,
    required this.stage,
    this.processed = 0,
    this.total,
    this.errorCode,
    this.errorMessage,
    this.complete = false,
  });

  final String sessionId;
  final String generationId;
  final String type;
  final FolderScanStage stage;
  final int processed;
  final int? total;
  final FolderScanChunk chunk;
  final String? errorCode;
  final String? errorMessage;
  final bool complete;

  bool get isChunk => type == 'chunk';
  bool get isStarted => type == 'started';
  bool get isStageChanged => type == 'stageChanged';
  bool get isProgress => type == 'progress';
  bool get isDone => type == 'done' || type == 'completed';
  bool get isCancelled => type == 'cancelled';
  bool get isError => type == 'error' || type == 'failed';

  factory FolderScanSessionEvent.fromPayload(Map<Object?, Object?> payload) {
    final rawTracks = payload['tracks'];
    final trackPayload = rawTracks is List ? rawTracks : const <Object?>[];
    final parsedTracks = parseNativeScanPayload(trackPayload);
    final eventPaths = stringSetFromPayload(
      payload['paths'],
    ).map(PathMatcher.normalize).toSet();
    final folders = stringSetFromPayload(
      payload['folders'],
    ).map(PathMatcher.normalize).toList(growable: false);
    return FolderScanSessionEvent(
      sessionId: payload['sessionId']?.toString() ?? '',
      generationId:
          payload['generationId']?.toString() ??
          payload['sessionId']?.toString() ??
          '',
      type: payload['type']?.toString() ?? '',
      stage: FolderScanStage.fromPayload(payload['stage']),
      processed: (payload['processed'] as num?)?.toInt() ?? 0,
      total: (payload['total'] as num?)?.toInt(),
      chunk: FolderScanChunk(
        tracks: parsedTracks.tracks,
        paths: eventPaths.isEmpty ? parsedTracks.paths : eventPaths,
        folders: folders,
        failureCount: (payload['failureCount'] as num?)?.toInt() ?? 0,
      ),
      errorCode: payload['code']?.toString(),
      errorMessage: payload['message']?.toString(),
      complete: payload['complete'] as bool? ?? false,
    );
  }
}

Set<String> stringSetFromPayload(Object? value) {
  if (value is Set<String>) return value;
  if (value is Iterable) {
    return value.whereType<String>().toSet();
  }
  return const <String>{};
}

NativeScanPayload parseNativeScanPayload(List<dynamic> data) {
  final scanned = <ScannedTrack>[];
  final paths = <String>{};
  for (final item in data) {
    if (item is! Map) continue;
    final scannedPath = item['path']?.toString().trim();
    if (scannedPath == null ||
        scannedPath.isEmpty ||
        !isSupportedMediaFile(scannedPath)) {
      continue;
    }
    final resolvedPath = PathMatcher.isContentUri(scannedPath)
        ? scannedPath
        : path.normalize(scannedPath);
    final normalizedPath = PathMatcher.normalize(resolvedPath);
    final nativeGroupKey = item['groupKey']?.toString().trim();
    final nativeGroupTitle = item['groupTitle']?.toString().trim();
    final nativeGroupSubtitle = item['groupSubtitle']?.toString().trim();
    final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
        ? nativeGroupKey!
        : path.dirname(resolvedPath);
    final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
        ? nativeGroupTitle!
        : PathDisplay.folderName(groupKey);
    final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
        ? nativeGroupSubtitle!
        : groupKey;
    final displayName = item['title']?.toString().trim();
    final isVideo =
        item['isVideo'] as bool? ??
        isVideoMediaFile(
          displayName?.isEmpty ?? true ? resolvedPath : displayName!,
        );
    final scannedAtMs = item['scannedAtMs'] as num?;
    final modifiedAtMs = item['modifiedAtMs'] as num?;
    scanned.add(
      ScannedTrack(
        path: resolvedPath,
        groupKey: groupKey,
        groupTitle: groupTitle,
        groupSubtitle: groupSubtitle,
        isSingle: false,
        isVideo: isVideo,
        displayName: displayName?.isEmpty ?? true ? null : displayName,
        scannedAt: scannedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
        fileSizeBytes: (item['fileSizeBytes'] as num?)?.toInt(),
        modifiedAt: modifiedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
      ),
    );
    paths.add(normalizedPath);
  }
  return NativeScanPayload(
    tracks: List<ScannedTrack>.unmodifiable(scanned),
    paths: Set<String>.unmodifiable(paths),
  );
}
