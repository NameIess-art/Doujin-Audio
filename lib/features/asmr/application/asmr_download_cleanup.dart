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

    final filesToDelete = <String>{};

    // 1. Files explicitly recorded as completed for this task
    for (final relativePath in task.completedFilePaths) {
      if (relativePath.startsWith('cover/')) {
        continue;
      }
      filesToDelete.add(_joinFolderPath(workRootPath, relativePath));
    }

    // 2. Cover file
    if (task.coverOutputPath != null) {
      filesToDelete.add(task.coverOutputPath!);
    }
    if (task.saveCover ||
        task.completedFilePaths.any((p) => p.startsWith('cover/'))) {
      for (final ext in const ['.jpg', '.png', '.webp', '.jpeg']) {
        filesToDelete.add(_joinFolderPath(workRootPath, 'cover/cover$ext'));
      }
    }

    // 3. Metadata document (doujin-audio.json)
    if (task.saveMetadata) {
      filesToDelete.add(_joinFolderPath(workRootPath, 'doujin-audio.json'));
    }

    // 4. Any actively created paths from memory (staging files, in-progress files)
    filesToDelete.addAll(extraCreatedPaths);
    filesToDelete.addAll(_createdOutputPaths[task.work.id] ?? const <String>{});

    // 5. Staging files on local disk
    if (!isSaf) {
      for (final relativePath in task.completedFilePaths) {
        try {
          final staging = await _persistentStagingFile(
            workRootPath,
            relativePath,
          );
          if (await staging.exists()) {
            filesToDelete.add(staging.path);
          }
        } catch (_) {
          // Staging file lookup is best-effort during cleanup.
        }
      }
      if (task.saveCover) {
        try {
          final staging = await _persistentStagingFile(
            workRootPath,
            'cover/cover.cover',
          );
          if (await staging.exists()) {
            filesToDelete.add(staging.path);
          }
        } catch (_) {
          // Cover staging file lookup is best-effort during cleanup.
        }
      }
    }

    // 6. If completedFilePaths was empty, fallback to planned files from selectedRoots
    if (task.completedFilePaths.isEmpty) {
      final planned = _collectPlannedFiles(task.selectedRoots);
      for (final item in planned) {
        if (!item.isCover) {
          filesToDelete.add(_joinFolderPath(workRootPath, item.relativePath));
        }
      }
    }

    // 7. Created JSON documents
    for (final entry in createdJsonDocs.entries) {
      try {
        await _jsonDocumentStore.delete(
          location: entry.value.location,
          expectedRevision: entry.value.revision,
        );
      } catch (_) {
        // Document deletion is best-effort during rollback.
      }
    }

    // 8. Delete each target file
    for (final targetPath in filesToDelete) {
      await _deleteOutputPath(targetPath);
    }

    // 9. Prune newly-empty directories on local filesystem
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
