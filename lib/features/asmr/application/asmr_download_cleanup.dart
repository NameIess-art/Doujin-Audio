part of 'asmr_download_manager.dart';

extension AsmrDownloadCleanup on AsmrDownloadManager {
  void _throwIfCancelled(int workId) {
    if (_disposed ||
        _cancelRequested[workId] == true ||
        _pauseRequested[workId] == true) {
      throw const _DownloadCancelled();
    }
  }

  Future<void> _deleteTaskDownloadedFiles(
    AsmrDownloadTaskSnapshot task, {
    Set<String> extraCreatedPaths = const <String>{},
    Map<String, _CreatedJsonDocument> createdJsonDocs = const {},
  }) async {
    final workRootPath = task.workRootPath;
    final isSaf = PathMatcher.isContentUri(workRootPath);

    final filesToDelete = <String>{
      ...extraCreatedPaths,
      ...?_createdOutputPaths[task.work.id],
    };

    // JSON documents must be deleted with their recorded revision. A skipped
    // file, or a document changed after download, belongs to the user.
    for (final entry in createdJsonDocs.entries) {
      filesToDelete.remove(entry.key);
      try {
        await _jsonDocumentStore.delete(
          location: entry.value.location,
          expectedRevision: entry.value.revision,
        );
      } catch (_) {
        // Document deletion is best-effort during rollback.
      }
    }

    // Legacy tasks may lack a revision token for their JSON documents.
    for (final targetPath in filesToDelete) {
      if (targetPath.toLowerCase().endsWith('.json')) continue;
      await _deleteOutputPath(targetPath);
    }

    // Prune newly-empty directories on local filesystem.
    if (!isSaf) {
      final normalizedWorkRoot = path.normalize(path.absolute(workRootPath));
      final normalizedDestRoot = path.normalize(
        path.absolute(task.destinationRoot),
      );
      if (normalizedWorkRoot != normalizedDestRoot) {
        await _pruneEmptyDirectory(Directory(workRootPath));
      } else {
        final directory = Directory(workRootPath);
        if (await directory.exists()) {
          try {
            await for (final entity in directory.list(followLinks: false)) {
              if (entity is Directory) {
                await _pruneEmptyDirectory(entity);
              }
            }
          } catch (_) {
            // Directory pruning is best-effort during cleanup.
          }
        }
      }
    }
  }

  Future<bool> _pruneEmptyDirectory(Directory directory) async {
    try {
      if (!await directory.exists()) return true;
      final normalized = path.normalize(path.absolute(directory.path));
      if (normalized == path.rootPrefix(normalized)) {
        return false;
      }
      var hasEntries = false;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is Directory) {
          final childIsEmpty = await _pruneEmptyDirectory(entity);
          if (!childIsEmpty) {
            hasEntries = true;
          }
        } else {
          hasEntries = true;
        }
      }
      if (!hasEntries) {
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await directory.delete();
            return true;
          } catch (_) {
            if (attempt < 2) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
          }
        }
        return false;
      }
      return false;
    } catch (_) {
      return false;
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

  void _retainOnlyLatestCompletedTask(int workId) {
    for (final obsoleteWorkId in _store.retainOnlyLatestCompletedTask(workId)) {
      _createdOutputPaths.remove(obsoleteWorkId);
      _createdJsonDocuments.remove(obsoleteWorkId);
    }
  }
}
