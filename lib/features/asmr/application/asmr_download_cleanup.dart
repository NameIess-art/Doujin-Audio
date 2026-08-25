part of 'asmr_download_manager.dart';

extension AsmrDownloadCleanup on AsmrDownloadManager {
  void _throwIfCancelled(int workId) {
    if (_disposed ||
        _cancelRequested[workId] == true ||
        _pauseRequested[workId] == true) {
      throw const _DownloadCancelled();
    }
  }

  Future<void> _deleteDownloadRoot(String workRootPath) async {
    if (PathMatcher.isContentUri(workRootPath)) {
      try {
        await _fileCacheGateway.deleteDocumentPath(workRootPath);
      } catch (_) {
        // Explicit task deletion is best effort.
      }
      return;
    }
    final directory = Directory(workRootPath);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (!await directory.exists()) return;
        await directory.delete(recursive: true);
        return;
      } catch (_) {
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    }
  }

  Future<void> _deleteFileIfPresent(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      if (await file.exists()) rethrow;
    }
  }

  Future<void> _deleteOutputPath(String outputPath) async {
    try {
      if (PathMatcher.isContentUri(outputPath)) {
        await _fileCacheGateway.deleteDocumentPath(outputPath);
      } else {
        await _deleteFileIfPresent(File(outputPath));
      }
    } catch (_) {
      // Removing downloaded output is best effort.
    }
  }

  Future<bool> _outputPathExists(String outputPath) async {
    if (PathMatcher.isContentUri(outputPath)) {
      return _fileCacheGateway.documentPathExists(outputPath);
    }
    return File(outputPath).exists();
  }

  Future<void> _cleanupCancelledTask(int workId) async {
    for (final createdPath in _createdOutputPaths[workId] ?? const <String>{}) {
      try {
        final createdJson = _createdJsonDocuments[workId]?[createdPath];
        if (createdJson != null) {
          await _jsonDocumentStore.delete(
            location: createdJson.location,
            expectedRevision: createdJson.revision,
          );
          continue;
        }
        if (createdPath.toLowerCase().endsWith('.json')) {
          // A restored legacy task has no revision token. Preserve the JSON
          // instead of risking deletion of a document modified after download.
          continue;
        }
        if (PathMatcher.isContentUri(createdPath)) {
          await _fileCacheGateway.deleteDocumentPath(createdPath);
        } else {
          final file = File(createdPath);
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (_) {
        // Cancellation cleanup is best effort and never removes pre-existing files.
      }
    }
  }
}
