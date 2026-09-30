import '../../../core/persistence/json_document_store.dart';
import 'asmr_download_models.dart';

class PersistedDownloadTask {
  const PersistedDownloadTask({
    required this.task,
    required this.createdOutputPaths,
    required this.createdJsonDocuments,
  });

  final AsmrDownloadTaskSnapshot task;
  final Set<String> createdOutputPaths;
  final Map<String, CreatedDownloadJsonDocument> createdJsonDocuments;
}

final class CreatedDownloadJsonDocument {
  const CreatedDownloadJsonDocument({
    required this.location,
    required this.revision,
  });

  final JsonDocumentLocation location;
  final String revision;

  Map<String, Object?> toJson() => <String, Object?>{
    ...location.toPlatformArguments(),
    'revision': revision,
  };

  static CreatedDownloadJsonDocument? fromJson(Map<String, Object?> json) {
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
    return CreatedDownloadJsonDocument(location: location, revision: revision);
  }
}

class PlannedDownloadFile {
  const PlannedDownloadFile({
    required this.url,
    required this.relativePath,
    required this.size,
  }) : isCover = false,
       coverFileStem = null,
       maxBytes = null,
       countsTowardByteProgress = true;

  const PlannedDownloadFile.cover({
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

class DownloadWriteResult {
  const DownloadWriteResult._({
    required this.saved,
    required this.skipped,
    required this.bytesDownloaded,
  });

  const DownloadWriteResult.success({required int bytesDownloaded})
    : this._(saved: true, skipped: false, bytesDownloaded: bytesDownloaded);

  const DownloadWriteResult.skipped({required int bytesDownloaded})
    : this._(saved: false, skipped: true, bytesDownloaded: bytesDownloaded);

  const DownloadWriteResult.failure({required int bytesDownloaded})
    : this._(saved: false, skipped: false, bytesDownloaded: bytesDownloaded);

  final bool saved;
  final bool skipped;
  final int bytesDownloaded;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}
