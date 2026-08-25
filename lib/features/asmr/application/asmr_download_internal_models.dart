part of 'asmr_download_manager.dart';

class _PersistedDownloadTask {
  const _PersistedDownloadTask({
    required this.task,
    required this.createdOutputPaths,
    required this.createdJsonDocuments,
  });

  final AsmrDownloadTaskSnapshot task;
  final Set<String> createdOutputPaths;
  final Map<String, _CreatedJsonDocument> createdJsonDocuments;
}

final class _CreatedJsonDocument {
  const _CreatedJsonDocument({required this.location, required this.revision});

  final JsonDocumentLocation location;
  final String revision;

  Map<String, Object?> toJson() => <String, Object?>{
    ...location.toPlatformArguments(),
    'revision': revision,
  };

  static _CreatedJsonDocument? fromJson(Map<String, Object?> json) {
    final kind = switch (json['locationKind']) {
      'folderChild' => JsonDocumentLocationKind.folderChild,
      'fileSibling' => JsonDocumentLocationKind.fileSibling,
      _ => null,
    };
    final basePath = json['basePath'];
    final name = json['name'];
    final revision = json['revision'];
    if (kind == null ||
        basePath is! String ||
        name is! String ||
        revision is! String ||
        revision.isEmpty) {
      return null;
    }
    final location = kind == JsonDocumentLocationKind.folderChild
        ? JsonDocumentLocation.folderChild(folder: basePath, name: name)
        : JsonDocumentLocation.fileSibling(filePath: basePath, name: name);
    return _CreatedJsonDocument(location: location, revision: revision);
  }
}

class _PlannedDownloadFile {
  const _PlannedDownloadFile({
    required this.url,
    required this.relativePath,
    required this.size,
  }) : isCover = false,
       coverFileStem = null,
       maxBytes = null,
       countsTowardByteProgress = true;

  const _PlannedDownloadFile.cover({
    required this.url,
    required this.relativePath,
    required String this.coverFileStem,
    required int this.maxBytes,
  }) : size = 0,
       isCover = true,
       countsTowardByteProgress = false;

  final String url;
  final String relativePath;
  final int size;
  final bool isCover;
  final String? coverFileStem;
  final int? maxBytes;
  final bool countsTowardByteProgress;
}

class _WriteResult {
  const _WriteResult._({
    required this.saved,
    required this.skipped,
    required this.bytesDownloaded,
  });

  const _WriteResult.success({required int bytesDownloaded})
    : this._(saved: true, skipped: false, bytesDownloaded: bytesDownloaded);

  const _WriteResult.skipped({required int bytesDownloaded})
    : this._(saved: false, skipped: true, bytesDownloaded: bytesDownloaded);

  const _WriteResult.failure({required int bytesDownloaded})
    : this._(saved: false, skipped: false, bytesDownloaded: bytesDownloaded);

  final bool saved;
  final bool skipped;
  final int bytesDownloaded;
}

class _TemporaryDownloadResult {
  const _TemporaryDownloadResult({
    required this.file,
    required this.bytesDownloaded,
    required this.mimeType,
    required this.cacheLease,
  });

  final File file;
  final int bytesDownloaded;
  final String? mimeType;
  final CachePathLease cacheLease;
}

class _TemporaryDownloadAttempt {
  const _TemporaryDownloadAttempt.success(
    int bytesDownloaded, {
    String? mimeType,
  }) : this._(
         bytesDownloaded: bytesDownloaded,
         retryable: false,
         mimeType: mimeType,
       );

  const _TemporaryDownloadAttempt.failure({
    required bool retryable,
    Object? error,
    StackTrace? stackTrace,
  }) : this._(
         bytesDownloaded: null,
         retryable: retryable,
         error: error,
         stackTrace: stackTrace,
       );

  const _TemporaryDownloadAttempt._({
    required this.bytesDownloaded,
    required this.retryable,
    this.mimeType,
    this.error,
    this.stackTrace,
  });

  final int? bytesDownloaded;
  final bool retryable;
  final String? mimeType;
  final Object? error;
  final StackTrace? stackTrace;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
