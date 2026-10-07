import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as path;

import '../domain/asmr_download.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../../core/persistence/json_document_store.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/logging/app_log_service.dart';
import 'asmr_download_models.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_download_cleanup.dart';
import 'asmr_download_planner.dart';
import 'asmr_download_task_store.dart';
import 'asmr_download_io.dart';

class AsmrDownloadTransferService {
  AsmrDownloadTransferService({
    required AsmrDownloadTaskStore store,
    required AsmrDownloadOutputStore outputs,
    required Duration automaticFileRetryDelay,
    required this.isDisposed,
    required this.isPaused,
    required this.throwIfCancelled,
  }) : _store = store,
       _outputs = outputs,
       _automaticFileRetryDelay = automaticFileRetryDelay;
  final AsmrDownloadTaskStore _store;
  final AsmrDownloadOutputStore _outputs;
  final Duration _automaticFileRetryDelay;
  final bool Function() isDisposed;
  final bool Function(int) isPaused;
  final void Function(int) throwIfCancelled;
  static const _planner = AsmrDownloadPlanner();
  Future<DownloadWriteResult> downloadItem(
    PlannedDownloadFile item, {
    required int workId,
    required AsmrDownloadTaskSnapshot task,
    required String workRootPath,
    required AsmrDownloadConflictPolicy conflictPolicy,
    required HttpClient client,
  }) async {
    throwIfCancelled(workId);
    if (item.isCover) {
      return _downloadCoverItem(
        item,
        workId: workId,
        task: task,
        conflictPolicy: conflictPolicy,
        client: client,
      );
    }
    final normalizedRelativePath = _planner.validatedDownloadRelativePath(
      item.relativePath,
    );
    // The task commits its own work metadata after all transfers finish.
    if (task.saveMetadata &&
        normalizedRelativePath.toLowerCase() == 'doujin-audio.json') {
      return DownloadWriteResult.skipped(bytesDownloaded: item.size);
    }
    final preserveExistingJson =
        path.extension(normalizedRelativePath).toLowerCase() == '.json';
    final jsonLocation = preserveExistingJson
        ? _outputs.jsonDownloadLocation(workRootPath, normalizedRelativePath)
        : null;
    if (jsonLocation != null) {
      final existingJson = await _outputs.jsonDocuments.read(jsonLocation);
      if (existingJson.status == JsonDocumentReadStatus.found) {
        return DownloadWriteResult.skipped(bytesDownloaded: item.size);
      }
    }

    File? localTargetFile;
    if (!PathMatcher.isContentUri(workRootPath)) {
      localTargetFile = File(
        _planner.resolveLocalPathWithin(workRootPath, normalizedRelativePath),
      );
      if ((preserveExistingJson ||
              conflictPolicy == AsmrDownloadConflictPolicy.skip) &&
          await localTargetFile.exists()) {
        return DownloadWriteResult.skipped(bytesDownloaded: item.size);
      }
      await localTargetFile.parent.create(recursive: true);
    } else {
      final docPath = _planner.joinFolderPath(
        workRootPath,
        normalizedRelativePath,
      );
      if (await _outputs.gateway.documentPathExists(docPath)) {
        if (preserveExistingJson ||
            conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return DownloadWriteResult.skipped(bytesDownloaded: item.size);
        }
      }
    }

    final stagingFile = localTargetFile == null || jsonLocation != null
        ? await _outputs.persistentStagingFile(
            workRootPath,
            normalizedRelativePath,
          )
        : File('${localTargetFile.path}.doujin.part');
    final stagingExisted = await stagingFile.exists();
    if (!stagingExisted) {
      _outputs.createdOutputPaths[workId]?.add(stagingFile.path);
    }
    final tempResult = await _downloadToTemporaryFile(
      item,
      workId: workId,
      client: client,
      stagingFile: stagingFile,
    );
    if (tempResult == null) {
      return const DownloadWriteResult.failure(bytesDownloaded: 0);
    }

    try {
      throwIfCancelled(workId);
      if (jsonLocation != null) {
        final parentRelative = path.posix.dirname(normalizedRelativePath);
        if (parentRelative != '.' &&
            !await _outputs.ensureFolderPath(
              basePath: workRootPath,
              relativePath: parentRelative,
              overwrite: false,
            )) {
          return DownloadWriteResult.failure(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        final write = await _outputs.jsonDocuments.write(
          location: jsonLocation,
          bytes: await tempResult.file.readAsBytes(),
          mode: JsonDocumentWriteMode.createIfAbsent,
        );
        if (write.status == JsonDocumentWriteStatus.preserved) {
          return DownloadWriteResult.skipped(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        if (write.status != JsonDocumentWriteStatus.created) {
          return DownloadWriteResult.failure(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        _outputs.createdOutputPaths[workId]?.add(
          _planner.joinFolderPath(workRootPath, normalizedRelativePath),
        );
        _outputs.recordCreatedJson(
          workId,
          _planner.joinFolderPath(workRootPath, normalizedRelativePath),
          jsonLocation,
          write,
        );
        return DownloadWriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }
      if (PathMatcher.isContentUri(workRootPath)) {
        final targetPath = _planner.joinFolderPath(
          workRootPath,
          normalizedRelativePath,
        );
        final targetExisted = await _outputs.gateway.documentPathExists(
          targetPath,
        );
        final saved = await _outputs.gateway.copyFileToFolder(
          sourcePath: tempResult.file.path,
          folder: workRootPath,
          relativePath: normalizedRelativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
        if (!saved) {
          return conflictPolicy == AsmrDownloadConflictPolicy.skip
              ? DownloadWriteResult.skipped(
                  bytesDownloaded: tempResult.bytesDownloaded,
                )
              : DownloadWriteResult.failure(
                  bytesDownloaded: tempResult.bytesDownloaded,
                );
        }
        if (!targetExisted) {
          _outputs.createdOutputPaths[workId]?.add(targetPath);
        }
        return DownloadWriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }

      final targetFile = localTargetFile!;
      final targetExisted = await targetFile.exists();
      if (targetExisted) {
        if (conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return DownloadWriteResult.skipped(bytesDownloaded: item.size);
        }
      }
      final committed = await commitLocalDownloadedFile(
        staging: tempResult.file,
        target: targetFile,
      );
      if (!committed) {
        return DownloadWriteResult.skipped(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }
      if (!targetExisted) {
        _outputs.createdOutputPaths[workId]?.add(targetFile.path);
      }
      return DownloadWriteResult.success(
        bytesDownloaded: tempResult.bytesDownloaded,
      );
    } finally {
      try {
        if (!isPaused(workId) &&
            !isDisposed() &&
            await tempResult.file.exists()) {
          await tempResult.file.delete();
        }
      } catch (_) {
        // Temporary download cleanup is best effort after the primary result.
      }
      tempResult.cacheLease.release();
    }
  }

  Future<DownloadWriteResult> _downloadCoverItem(
    PlannedDownloadFile item, {
    required int workId,
    required AsmrDownloadTaskSnapshot task,
    required AsmrDownloadConflictPolicy conflictPolicy,
    required HttpClient client,
  }) async {
    final knownExtension = _planner.coverUrlExtension(item.url);
    final knownTargetPath = knownExtension == null
        ? task.coverOutputPath
        : _planner.joinFolderPath(
            task.workRootPath,
            'cover/${item.coverFileStem!}$knownExtension',
          );
    if (knownTargetPath != null &&
        conflictPolicy == AsmrDownloadConflictPolicy.skip &&
        await _outputs.outputPathExists(knownTargetPath)) {
      return const DownloadWriteResult.skipped(bytesDownloaded: 0);
    }
    if (!await _outputs.ensureFolderPath(
      basePath: task.workRootPath,
      relativePath: 'cover',
      overwrite: false,
    )) {
      return const DownloadWriteResult.failure(bytesDownloaded: 0);
    }

    // Local commits rename the staging file, which must stay on the target volume.
    final stagingFile = PathMatcher.isContentUri(task.workRootPath)
        ? await _outputs.persistentStagingFile(
            task.workRootPath,
            item.relativePath,
          )
        : File(
            '${_planner.resolveLocalPathWithin(task.workRootPath, item.relativePath)}.doujin.part',
          );
    final stagingExisted = await stagingFile.exists();
    if (!stagingExisted) {
      _outputs.createdOutputPaths[workId]?.add(stagingFile.path);
    }
    final tempResult = await _downloadToTemporaryFile(
      item,
      workId: workId,
      client: client,
      stagingFile: stagingFile,
    );
    if (tempResult == null) {
      return const DownloadWriteResult.failure(bytesDownloaded: 0);
    }

    try {
      throwIfCancelled(workId);
      if (tempResult.bytesDownloaded <= 0 ||
          (tempResult.mimeType != null &&
              !tempResult.mimeType!.toLowerCase().startsWith('image/'))) {
        return const DownloadWriteResult.failure(bytesDownloaded: 0);
      }
      final extension = _planner.coverExtension(item.url, tempResult.mimeType);
      final relativePath = 'cover/${item.coverFileStem!}$extension';
      final targetPath = _planner.joinFolderPath(
        task.workRootPath,
        relativePath,
      );
      final targetExisted = PathMatcher.isContentUri(task.workRootPath)
          ? await _outputs.gateway.documentPathExists(targetPath)
          : await File(targetPath).exists();
      if (targetExisted && conflictPolicy == AsmrDownloadConflictPolicy.skip) {
        return const DownloadWriteResult.skipped(bytesDownloaded: 0);
      }

      if (PathMatcher.isContentUri(task.workRootPath)) {
        final saved = await _outputs.gateway.copyFileToFolder(
          sourcePath: tempResult.file.path,
          folder: task.workRootPath,
          relativePath: relativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
        if (!saved) {
          return const DownloadWriteResult.failure(bytesDownloaded: 0);
        }
      } else {
        final targetFile = File(targetPath);
        await targetFile.parent.create(recursive: true);
        final committed = await commitLocalDownloadedFile(
          staging: tempResult.file,
          target: targetFile,
        );
        if (!committed) {
          return const DownloadWriteResult.failure(bytesDownloaded: 0);
        }
      }

      if (!targetExisted) _outputs.createdOutputPaths[workId]?.add(targetPath);
      final currentTask = _store[workId];
      if (currentTask != null) {
        _store[workId] = currentTask.copyWith(coverOutputPath: targetPath);
      }
      return const DownloadWriteResult.success(bytesDownloaded: 0);
    } finally {
      try {
        if (!isPaused(workId) &&
            !isDisposed() &&
            await tempResult.file.exists()) {
          await tempResult.file.delete();
        }
      } catch (_) {
        // Temporary cover cleanup is best effort after the primary result.
      }
      tempResult.cacheLease.release();
    }
  }

  Future<_TemporaryDownloadResult?> _downloadToTemporaryFile(
    PlannedDownloadFile item, {
    required int workId,
    required HttpClient client,
    required File stagingFile,
  }) async {
    final tempFile = stagingFile;
    await tempFile.parent.create(recursive: true);
    final cacheLease = AppCacheService.protectPaths(<String>[tempFile.path]);
    var leaseTransferred = false;
    try {
      for (var attempt = 0; ; attempt++) {
        throwIfCancelled(workId);
        if (attempt > 0) {
          _setFileRetryAttempt(workId, item.relativePath, null);
        }
        final result = await _downloadToTemporaryFileAttempt(
          item,
          workId: workId,
          client: client,
          stagingFile: stagingFile,
          allowResume: true,
        );
        if (result.bytesDownloaded case final bytesDownloaded?) {
          await tempFile.setLastModified(DateTime.now());
          leaseTransferred = true;
          return _TemporaryDownloadResult(
            file: tempFile,
            bytesDownloaded: bytesDownloaded,
            mimeType: result.mimeType,
            cacheLease: cacheLease,
          );
        }

        final maxRetries =
            _store[workId]?.automaticFileRetryCount ??
            kMaxAsmrDownloadRetryCount;
        if (!result.retryable || attempt >= maxRetries) {
          if (result.error case final error?) {
            AppLogService.error(
              'asmr_download_transfer_failed path=${item.relativePath}',
              error: error,
              stackTrace: result.stackTrace,
            );
          }
          return null;
        }

        final retryAttempt = attempt + 1;
        _setFileRetryAttempt(workId, item.relativePath, retryAttempt);
        AppLogService.warning(
          'asmr_download_transfer_retry path=${item.relativePath} '
          'attempt=$retryAttempt/$maxRetries',
          error: result.error,
          stackTrace: result.stackTrace,
        );
        await Future<void>.delayed(_automaticFileRetryDelay);
      }
    } on DownloadCancelled {
      rethrow;
    } finally {
      _setFileRetryAttempt(workId, item.relativePath, null);
      if (!leaseTransferred) {
        try {
          if (!isPaused(workId) && !isDisposed() && await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {
          // Incomplete staging file cleanup is best effort.
        } finally {
          cacheLease.release();
        }
      }
    }
  }

  Future<_TemporaryDownloadAttempt> _downloadToTemporaryFileAttempt(
    PlannedDownloadFile item, {
    required int workId,
    required HttpClient client,
    required File stagingFile,
    required bool allowResume,
  }) async {
    var received = 0;
    try {
      try {
        received = await stagingFile.length();
      } on FileSystemException {
        if (await stagingFile.exists()) rethrow;
      }
      if (!allowResume && received > 0) {
        if (item.countsTowardByteProgress) {
          _store.discardLivePartialProgress(
            workId,
            item.relativePath,
            received,
          );
        }
        await _outputs.deleteFileIfPresent(stagingFile);
        received = 0;
      }
      if (item.size > 0 && received > item.size) {
        if (item.countsTowardByteProgress) {
          _store.discardLivePartialProgress(
            workId,
            item.relativePath,
            received,
          );
        }
        await _outputs.deleteFileIfPresent(stagingFile);
        received = 0;
      }
      if (item.size > 0 && received == item.size) {
        return _TemporaryDownloadAttempt.success(received);
      }
      const requestTimeout = Duration(seconds: 15);
      const downloadIdleTimeout = Duration(seconds: 30);
      throwIfCancelled(workId);
      final uri = Uri.parse(item.url);
      final request = await client.getUrl(uri).timeout(requestTimeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Doujin Audio downloader',
      );
      for (final header in asmrMediaRequestHeadersForUrl(item.url).entries) {
        request.headers.set(header.key, header.value);
      }
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await request.close().timeout(requestTimeout);

      Future<_TemporaryDownloadAttempt> retryWithoutRange() async {
        try {
          await response.listen((_) {}).cancel();
        } catch (_) {
          // The retry uses a new response even if cancellation already won.
        }
        if (item.countsTowardByteProgress) {
          _store.discardLivePartialProgress(
            workId,
            item.relativePath,
            received,
          );
        }
        await _outputs.deleteFileIfPresent(stagingFile);
        return _downloadToTemporaryFileAttempt(
          item,
          workId: workId,
          client: client,
          stagingFile: stagingFile,
          allowResume: false,
        );
      }

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          received > 0 &&
          allowResume) {
        return retryWithoutRange();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        try {
          await response.listen((_) {}).cancel();
        } catch (_) {
          // The status code is sufficient to classify this attempt.
        }
        final error = HttpException(
          'Download failed with HTTP ${response.statusCode}.',
          uri: uri,
        );
        return _TemporaryDownloadAttempt.failure(
          retryable: _isRetryableDownloadStatus(response.statusCode),
          error: error,
          stackTrace: StackTrace.current,
        );
      }

      final maxBytes = item.maxBytes;
      if (maxBytes != null &&
          (received > maxBytes ||
              (response.contentLength > 0 &&
                  received + response.contentLength > maxBytes))) {
        try {
          await response.listen((_) {}).cancel();
        } catch (_) {
          // The configured size limit is sufficient to reject the response.
        }
        return _TemporaryDownloadAttempt.failure(
          retryable: false,
          error: FileSystemException(
            'Download exceeds the maximum allowed size.',
            item.relativePath,
          ),
          stackTrace: StackTrace.current,
        );
      }

      var responseStart = 0;
      if (response.statusCode == HttpStatus.partialContent) {
        if (!isValidDownloadContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
          expectedStart: received,
          responseLength: response.contentLength,
          expectedTotal: item.size,
        )) {
          if (received > 0 && allowResume) return retryWithoutRange();
          return _TemporaryDownloadAttempt.failure(
            retryable: true,
            error: HttpException(
              'Download response contained an invalid byte range.',
              uri: uri,
            ),
            stackTrace: StackTrace.current,
          );
        }
        responseStart = received;
      }
      if (responseStart == 0 && received > 0) {
        final discardedBytes = received;
        received = 0;
        if (item.countsTowardByteProgress) {
          _store.discardLivePartialProgress(
            workId,
            item.relativePath,
            discardedBytes,
          );
        }
      }
      final sink = stagingFile.openWrite(
        mode: responseStart > 0 ? FileMode.append : FileMode.write,
      );
      try {
        await sink.addStream(
          response.timeout(downloadIdleTimeout).map((chunk) {
            throwIfCancelled(workId);
            received += chunk.length;
            if (maxBytes != null && received > maxBytes) {
              throw FileSystemException(
                'Download exceeds the maximum allowed size.',
                item.relativePath,
              );
            }
            if (item.countsTowardByteProgress) {
              _store.recordDownloadChunk(
                workId,
                item.relativePath,
                chunk.length,
                received,
              );
            }
            return chunk;
          }),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      if ((response.contentLength > 0 &&
              received - responseStart != response.contentLength) ||
          (item.size > 0 && received != item.size)) {
        return _TemporaryDownloadAttempt.failure(
          retryable: true,
          error: HttpException(
            'Download response ended before the file was complete.',
            uri: uri,
          ),
          stackTrace: StackTrace.current,
        );
      }
      return _TemporaryDownloadAttempt.success(
        received,
        mimeType: response.headers.contentType?.mimeType,
      );
    } on DownloadCancelled {
      rethrow;
    } catch (error, stackTrace) {
      throwIfCancelled(workId);
      return _TemporaryDownloadAttempt.failure(
        retryable: _isRetryableDownloadError(error),
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isRetryableDownloadStatus(int statusCode) {
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode >= HttpStatus.internalServerError;
  }

  bool _isRetryableDownloadError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is HttpException;
  }

  void _setFileRetryAttempt(int workId, String relativePath, int? attempt) {
    if (isDisposed()) return;
    final task = _store[workId];
    if (task == null) return;
    final attempts = Map<String, int>.from(task.fileRetryAttempts);
    if (attempt == null) {
      if (attempts.remove(relativePath) == null) return;
    } else {
      if (attempts[relativePath] == attempt) return;
      attempts[relativePath] = attempt;
    }
    _store[workId] = task.copyWith(fileRetryAttempts: attempts);
    _store.notifyProgressChanged(workId);
  }
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
