import '../domain/asmr_download.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/json_document_store.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../library/data/audio_detail_json_codec.dart';
import 'asmr_download_models.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_download_planner.dart';

class AsmrDownloadOutputStore {
  AsmrDownloadOutputStore({
    required FileCachePlatformGateway fileCacheGateway,
    required JsonDocumentStore jsonDocumentStore,
    required Future<Directory> Function() stagingDirectoryProvider,
  }) : _fileCacheGateway = fileCacheGateway,
       _jsonDocumentStore = jsonDocumentStore,
       _stagingDirectoryProvider = stagingDirectoryProvider;
  final FileCachePlatformGateway _fileCacheGateway;
  final JsonDocumentStore _jsonDocumentStore;
  final Future<Directory> Function() _stagingDirectoryProvider;
  final Map<int, Set<String>> createdOutputPaths = {};
  final Map<int, Map<String, CreatedDownloadJsonDocument>>
  createdJsonDocuments = {};
  static const _planner = AsmrDownloadPlanner();
  static const _audioDetailJsonCodec = AudioDetailJsonCodec();
  JsonDocumentStore get jsonDocuments => _jsonDocumentStore;
  FileCachePlatformGateway get gateway => _fileCacheGateway;
  Future<void> prepareTask(AsmrDownloadTaskSnapshot task) async {
    final workId = task.work.id;
    final normalizedDestination = task.destinationRoot;
    final workFolderName = task.workFolderName;
    final conflictPolicy = task.conflictPolicy;
    createdOutputPaths.putIfAbsent(workId, () => <String>{});
    createdJsonDocuments.putIfAbsent(
      workId,
      () => <String, CreatedDownloadJsonDocument>{},
    );
    final rootReady = await ensureFolderPath(
      basePath: normalizedDestination,
      relativePath: workFolderName,
      overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
    );
    if (!rootReady) {
      throw const FileSystemException('Unable to create download folder.');
    }
  }

  Future<bool> saveTaskMetadata(
    AsmrDownloadTaskSnapshot task,
    AudioDetail backup,
  ) async {
    final backupPath = _planner.joinFolderPath(
      task.workRootPath,
      'doujin-audio.json',
    );
    final location = JsonDocumentLocation.folderChild(
      folder: task.workRootPath,
      name: 'doujin-audio.json',
    );
    final write = await writeWorkDetailBackup(backup, location);
    final metadataCreated = write.status == JsonDocumentWriteStatus.created;
    if (metadataCreated) {
      createdOutputPaths[task.work.id]?.add(backupPath);
      recordCreatedJson(task.work.id, backupPath, location, write);
    }
    return metadataCreated;
  }

  Future<void> deleteTaskDownloadedFiles(
    AsmrDownloadTaskSnapshot task, {
    Set<String> extraCreatedPaths = const <String>{},
    Map<String, CreatedDownloadJsonDocument> createdJsonDocs = const {},
  }) async {
    final workRootPath = task.workRootPath;
    final isSaf = PathMatcher.isContentUri(workRootPath);

    final filesToDelete = <String>{
      ...extraCreatedPaths,
      ...?createdOutputPaths[task.work.id],
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
      await deleteOutputPath(targetPath);
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

  Future<void> deleteFileIfPresent(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      if (await file.exists()) rethrow;
    }
  }

  Future<void> deleteOutputPath(String outputPath) async {
    try {
      if (PathMatcher.isContentUri(outputPath)) {
        await _fileCacheGateway.deleteDocumentPath(outputPath);
      } else {
        await deleteFileIfPresent(File(outputPath));
      }
    } catch (_) {
      // Removing downloaded output is best effort.
    }
  }

  Future<bool> outputPathExists(String outputPath) async {
    if (PathMatcher.isContentUri(outputPath)) {
      return _fileCacheGateway.documentPathExists(outputPath);
    }
    return File(outputPath).exists();
  }

  Future<void> cleanupCancelledTask(int workId) async {
    for (final createdPath in createdOutputPaths[workId] ?? const <String>{}) {
      try {
        final createdJson = createdJsonDocuments[workId]?[createdPath];
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

  Future<JsonDocumentWriteResult> writeWorkDetailBackup(
    AudioDetail detail,
    JsonDocumentLocation location,
  ) async {
    final result = await _jsonDocumentStore.write(
      location: location,
      bytes: _audioDetailJsonCodec.encodeNew(detail),
      mode: JsonDocumentWriteMode.createIfAbsent,
    );
    if (result.status == JsonDocumentWriteStatus.created ||
        result.status == JsonDocumentWriteStatus.preserved) {
      return result;
    }
    throw FileSystemException(
      'Unable to write work detail backup.',
      result.error,
    );
  }

  void recordCreatedJson(
    int workId,
    String path,
    JsonDocumentLocation location,
    JsonDocumentWriteResult result,
  ) {
    final revision = result.revision;
    if (result.status != JsonDocumentWriteStatus.created || revision == null) {
      return;
    }
    createdJsonDocuments.putIfAbsent(
      workId,
      () => <String, CreatedDownloadJsonDocument>{},
    )[path] = CreatedDownloadJsonDocument(
      location: location,
      revision: revision,
    );
  }

  Future<bool> ensureFolderPath({
    required String basePath,
    required String relativePath,
    required bool overwrite,
  }) async {
    final normalized = _planner.validatedDownloadRelativePath(relativePath);

    if (PathMatcher.isContentUri(basePath)) {
      return _fileCacheGateway.ensureFolderPath(
        folder: basePath,
        relativePath: normalized,
        overwrite: overwrite,
      );
    }

    final folder = Directory(
      _planner.resolveLocalPathWithin(basePath, normalized),
    );
    try {
      await folder.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> targetFileExists(
    String workRootPath,
    PlannedDownloadFile item, {
    String? coverOutputPath,
  }) async {
    if (item.isCover) {
      if (coverOutputPath != null && await outputPathExists(coverOutputPath)) {
        return true;
      }
      final knownExtension = _planner.coverUrlExtension(item.url);
      if (knownExtension != null) {
        final targetPath = _planner.joinFolderPath(
          workRootPath,
          'cover/${item.coverFileStem!}$knownExtension',
        );
        if (await outputPathExists(targetPath)) return true;
      }
      for (final ext in const ['.jpg', '.png', '.webp', '.jpeg']) {
        final targetPath = _planner.joinFolderPath(
          workRootPath,
          'cover/${item.coverFileStem!}$ext',
        );
        if (await outputPathExists(targetPath)) return true;
      }
      return false;
    }
    final normalized = _planner.validatedDownloadRelativePath(
      item.relativePath,
    );
    final targetPath = _planner.joinFolderPath(workRootPath, normalized);
    return outputPathExists(targetPath);
  }

  JsonDocumentLocation jsonDownloadLocation(
    String workRootPath,
    String relativePath,
  ) {
    final parentRelative = path.posix.dirname(relativePath);
    final folder = parentRelative == '.'
        ? workRootPath
        : _planner.joinFolderPath(workRootPath, parentRelative);
    return JsonDocumentLocation.folderChild(
      folder: folder,
      name: path.posix.basename(relativePath),
    );
  }

  Future<File> persistentStagingFile(
    String workRootPath,
    String relativePath,
  ) async {
    final root = await _stagingDirectoryProvider();
    final key = sha256
        .convert(utf8.encode('$workRootPath|$relativePath'))
        .toString();
    return File(path.join(root.path, 'asmr_downloads', '$key.doujin.part'));
  }
}
