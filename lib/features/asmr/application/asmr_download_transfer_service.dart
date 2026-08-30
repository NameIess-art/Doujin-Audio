part of 'asmr_download_manager.dart';

extension AsmrDownloadTransferService on AsmrDownloadManager {
  Future<void> _resumeTask(int workId) async {
    if (_disposed) return;
    final task = _store[workId];
    if (task == null ||
        (task.status != AsmrDownloadTaskStatus.paused &&
            task.status != AsmrDownloadTaskStatus.failed)) {
      return;
    }
    _enqueueExistingTask(task);
  }

  Future<bool> _retryFailedFile(int workId, String relativePath) async {
    if (_disposed) return false;
    await initialize();
    if (_disposed) return false;
    final task = _store[workId];
    final normalizedPath = relativePath.trim();
    if (task == null ||
        normalizedPath.isEmpty ||
        !task.failedFilePaths.contains(normalizedPath) ||
        task.manuallyRetryingFilePaths.contains(normalizedPath)) {
      return false;
    }
    final plannedFile = _findPlannedFile(task, normalizedPath);
    if (plannedFile == null) return false;

    final activeDispatcher = _activeFileRetryDispatchers[workId];
    final canStartFailedTask =
        task.status == AsmrDownloadTaskStatus.failed &&
        !_activeTasks.contains(workId) &&
        !_queue.contains(workId);
    if (activeDispatcher == null && !canStartFailedTask) return false;

    final retryAttempts = Map<String, int>.from(task.fileRetryAttempts)
      ..remove(normalizedPath);
    final retryingPaths = Set<String>.from(task.manuallyRetryingFilePaths)
      ..add(normalizedPath);
    final retryingTask = task.copyWith(
      fileRetryAttempts: retryAttempts,
      manuallyRetryingFilePaths: retryingPaths,
    );
    _store[workId] = retryingTask;
    _store.notifyTaskChanged(changedWorkIds: <int>{workId});

    if (activeDispatcher != null) {
      activeDispatcher(plannedFile);
    } else {
      _manualRetryOnlyPaths[workId] = <String>{normalizedPath};
      _plannedFilesMap[workId] = <_PlannedDownloadFile>[plannedFile];
      _enqueueExistingTask(retryingTask);
    }
    return true;
  }

  void _enqueueExistingTask(AsmrDownloadTaskSnapshot task) {
    final workId = task.work.id;
    _resumingTasks.add(workId);
    _store[workId] = task.copyWith(
      status: AsmrDownloadTaskStatus.idle,
      message: 'queued',
    );
    if (!_queue.contains(workId)) {
      _queue.add(workId);
    }
    _store.notifyTaskChanged();
    _processQueue();
  }

  Future<_WriteResult> _downloadItem(
    _PlannedDownloadFile item, {
    required int workId,
    required AsmrDownloadTaskSnapshot task,
    required String workRootPath,
    required AsmrDownloadConflictPolicy conflictPolicy,
    required HttpClient client,
  }) async {
    _throwIfCancelled(workId);
    if (item.isCover) {
      return _downloadCoverItem(
        item,
        workId: workId,
        task: task,
        conflictPolicy: conflictPolicy,
        client: client,
      );
    }
    final normalizedRelativePath = _validatedDownloadRelativePath(
      item.relativePath,
    );
    final preserveExistingJson =
        path.extension(normalizedRelativePath).toLowerCase() == '.json';
    final jsonLocation = preserveExistingJson
        ? _jsonDownloadLocation(workRootPath, normalizedRelativePath)
        : null;
    if (jsonLocation != null) {
      final existingJson = await _jsonDocumentStore.read(jsonLocation);
      if (existingJson.status == JsonDocumentReadStatus.found) {
        return _WriteResult.skipped(bytesDownloaded: item.size);
      }
    }

    File? localTargetFile;
    if (!PathMatcher.isContentUri(workRootPath)) {
      localTargetFile = File(
        _resolveLocalPathWithin(workRootPath, normalizedRelativePath),
      );
      if ((preserveExistingJson ||
              conflictPolicy == AsmrDownloadConflictPolicy.skip) &&
          await localTargetFile.exists()) {
        return _WriteResult.skipped(bytesDownloaded: item.size);
      }
      await localTargetFile.parent.create(recursive: true);
    } else {
      final docPath = _joinFolderPath(workRootPath, normalizedRelativePath);
      if (await _fileCacheGateway.documentPathExists(docPath)) {
        if (preserveExistingJson ||
            conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return _WriteResult.skipped(bytesDownloaded: item.size);
        }
      }
    }

    final stagingFile = localTargetFile == null || jsonLocation != null
        ? await _persistentStagingFile(workRootPath, normalizedRelativePath)
        : File('${localTargetFile.path}.doujin.part');
    final stagingExisted = await stagingFile.exists();
    if (!stagingExisted) _createdOutputPaths[workId]?.add(stagingFile.path);
    final tempResult = await _downloadToTemporaryFile(
      item,
      workId: workId,
      client: client,
      stagingFile: stagingFile,
    );
    if (tempResult == null) {
      return const _WriteResult.failure(bytesDownloaded: 0);
    }

    try {
      _throwIfCancelled(workId);
      if (jsonLocation != null) {
        final parentRelative = path.posix.dirname(normalizedRelativePath);
        if (parentRelative != '.' &&
            !await _ensureFolderPath(
              basePath: workRootPath,
              relativePath: parentRelative,
              overwrite: false,
            )) {
          return _WriteResult.failure(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        final write = await _jsonDocumentStore.write(
          location: jsonLocation,
          bytes: await tempResult.file.readAsBytes(),
          mode: JsonDocumentWriteMode.createIfAbsent,
        );
        if (write.status == JsonDocumentWriteStatus.preserved) {
          return _WriteResult.skipped(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        if (write.status != JsonDocumentWriteStatus.created) {
          return _WriteResult.failure(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        _createdOutputPaths[workId]?.add(
          _joinFolderPath(workRootPath, normalizedRelativePath),
        );
        _recordCreatedJson(
          workId,
          _joinFolderPath(workRootPath, normalizedRelativePath),
          jsonLocation,
          write,
        );
        return _WriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }
      if (PathMatcher.isContentUri(workRootPath)) {
        final targetPath = _joinFolderPath(
          workRootPath,
          normalizedRelativePath,
        );
        final targetExisted = await _fileCacheGateway.documentPathExists(
          targetPath,
        );
        final saved = await _fileCacheGateway.copyFileToFolder(
          sourcePath: tempResult.file.path,
          folder: workRootPath,
          relativePath: normalizedRelativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
        if (!saved) {
          return conflictPolicy == AsmrDownloadConflictPolicy.skip
              ? _WriteResult.skipped(
                  bytesDownloaded: tempResult.bytesDownloaded,
                )
              : _WriteResult.failure(
                  bytesDownloaded: tempResult.bytesDownloaded,
                );
        }
        if (!targetExisted) {
          _createdOutputPaths[workId]?.add(targetPath);
        }
        return _WriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }

      final targetFile = localTargetFile!;
      final targetExisted = await targetFile.exists();
      if (targetExisted) {
        if (conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return _WriteResult.skipped(bytesDownloaded: item.size);
        }
      }
      final committed = await commitLocalDownloadedFile(
        staging: tempResult.file,
        target: targetFile,
      );
      if (!committed) {
        return _WriteResult.skipped(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }
      if (!targetExisted) {
        _createdOutputPaths[workId]?.add(targetFile.path);
      }
      return _WriteResult.success(bytesDownloaded: tempResult.bytesDownloaded);
    } finally {
      try {
        if (_pauseRequested[workId] != true &&
            !_disposed &&
            await tempResult.file.exists()) {
          await tempResult.file.delete();
        }
      } catch (_) {
        // Temporary download cleanup is best effort after the primary result.
      }
      tempResult.cacheLease.release();
    }
  }

  Future<_WriteResult> _downloadCoverItem(
    _PlannedDownloadFile item, {
    required int workId,
    required AsmrDownloadTaskSnapshot task,
    required AsmrDownloadConflictPolicy conflictPolicy,
    required HttpClient client,
  }) async {
    final knownExtension = _coverUrlExtension(item.url);
    final knownTargetPath = knownExtension == null
        ? task.coverOutputPath
        : _joinFolderPath(
            task.workRootPath,
            'cover/${item.coverFileStem!}$knownExtension',
          );
    if (knownTargetPath != null &&
        conflictPolicy == AsmrDownloadConflictPolicy.skip &&
        await _outputPathExists(knownTargetPath)) {
      return const _WriteResult.skipped(bytesDownloaded: 0);
    }
    if (!await _ensureFolderPath(
      basePath: task.workRootPath,
      relativePath: 'cover',
      overwrite: false,
    )) {
      return const _WriteResult.failure(bytesDownloaded: 0);
    }

    final stagingFile = await _persistentStagingFile(
      task.workRootPath,
      item.relativePath,
    );
    final stagingExisted = await stagingFile.exists();
    if (!stagingExisted) _createdOutputPaths[workId]?.add(stagingFile.path);
    final tempResult = await _downloadToTemporaryFile(
      item,
      workId: workId,
      client: client,
      stagingFile: stagingFile,
    );
    if (tempResult == null) {
      return const _WriteResult.failure(bytesDownloaded: 0);
    }

    try {
      _throwIfCancelled(workId);
      if (tempResult.bytesDownloaded <= 0 ||
          (tempResult.mimeType != null &&
              !tempResult.mimeType!.toLowerCase().startsWith('image/'))) {
        return const _WriteResult.failure(bytesDownloaded: 0);
      }
      final extension = _coverExtension(item.url, tempResult.mimeType);
      final relativePath = 'cover/${item.coverFileStem!}$extension';
      final targetPath = _joinFolderPath(task.workRootPath, relativePath);
      final targetExisted = PathMatcher.isContentUri(task.workRootPath)
          ? await _fileCacheGateway.documentPathExists(targetPath)
          : await File(targetPath).exists();
      if (targetExisted && conflictPolicy == AsmrDownloadConflictPolicy.skip) {
        return const _WriteResult.skipped(bytesDownloaded: 0);
      }

      if (PathMatcher.isContentUri(task.workRootPath)) {
        final saved = await _fileCacheGateway.copyFileToFolder(
          sourcePath: tempResult.file.path,
          folder: task.workRootPath,
          relativePath: relativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
        if (!saved) return const _WriteResult.failure(bytesDownloaded: 0);
      } else {
        final targetFile = File(targetPath);
        await targetFile.parent.create(recursive: true);
        final committed = await commitLocalDownloadedFile(
          staging: tempResult.file,
          target: targetFile,
        );
        if (!committed) {
          return const _WriteResult.failure(bytesDownloaded: 0);
        }
      }

      if (!targetExisted) _createdOutputPaths[workId]?.add(targetPath);
      final currentTask = _store[workId];
      if (currentTask != null) {
        _store[workId] = currentTask.copyWith(coverOutputPath: targetPath);
      }
      return const _WriteResult.success(bytesDownloaded: 0);
    } finally {
      try {
        if (_pauseRequested[workId] != true &&
            !_disposed &&
            await tempResult.file.exists()) {
          await tempResult.file.delete();
        }
      } catch (_) {
        // Temporary cover cleanup is best effort after the primary result.
      }
      tempResult.cacheLease.release();
    }
  }

  String _coverExtension(String url, String? mimeType) {
    final urlExtension = _coverUrlExtension(url);
    if (urlExtension != null) return urlExtension;
    return switch (mimeType?.toLowerCase()) {
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      'image/jpeg' || 'image/jpg' => '.jpg',
      _ => '.jpg',
    };
  }

  String? _coverUrlExtension(String url) {
    final extension = path
        .extension(Uri.tryParse(url)?.path ?? '')
        .toLowerCase();
    return const <String>{
          '.jpg',
          '.jpeg',
          '.png',
          '.webp',
          '.gif',
        }.contains(extension)
        ? extension
        : null;
  }

  Future<_TemporaryDownloadResult?> _downloadToTemporaryFile(
    _PlannedDownloadFile item, {
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
        _throwIfCancelled(workId);
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
    } on _DownloadCancelled {
      rethrow;
    } finally {
      _setFileRetryAttempt(workId, item.relativePath, null);
      if (!leaseTransferred) {
        try {
          if (_pauseRequested[workId] != true &&
              !_disposed &&
              await tempFile.exists()) {
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
    _PlannedDownloadFile item, {
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
        await _deleteFileIfPresent(stagingFile);
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
        await _deleteFileIfPresent(stagingFile);
        received = 0;
      }
      if (item.size > 0 && received == item.size) {
        return _TemporaryDownloadAttempt.success(received);
      }
      const requestTimeout = Duration(seconds: 15);
      const downloadIdleTimeout = Duration(seconds: 30);
      _throwIfCancelled(workId);
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
        await _deleteFileIfPresent(stagingFile);
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
        await for (final chunk in response.timeout(downloadIdleTimeout)) {
          _throwIfCancelled(workId);
          received += chunk.length;
          if (maxBytes != null && received > maxBytes) {
            throw FileSystemException(
              'Download exceeds the maximum allowed size.',
              item.relativePath,
            );
          }
          sink.add(chunk);

          if (item.countsTowardByteProgress) {
            _store.recordDownloadChunk(
              workId,
              item.relativePath,
              chunk.length,
              received,
            );
          }
        }
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
    } on _DownloadCancelled {
      rethrow;
    } catch (error, stackTrace) {
      if (_cancelRequested[workId] == true || _pauseRequested[workId] == true) {
        throw const _DownloadCancelled();
      }
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
    if (_disposed) return;
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

  Future<JsonDocumentWriteResult> _writeWorkDetailBackup(
    AudioDetail detail,
    JsonDocumentLocation location,
  ) async {
    final result = await _jsonDocumentStore.write(
      location: location,
      bytes: AsmrDownloadManager._audioDetailJsonCodec.encodeNew(detail),
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

  void _recordCreatedJson(
    int workId,
    String path,
    JsonDocumentLocation location,
    JsonDocumentWriteResult result,
  ) {
    final revision = result.revision;
    if (result.status != JsonDocumentWriteStatus.created || revision == null) {
      return;
    }
    _createdJsonDocuments.putIfAbsent(
      workId,
      () => <String, _CreatedJsonDocument>{},
    )[path] = _CreatedJsonDocument(
      location: location,
      revision: revision,
    );
  }

  Future<bool> _ensureFolderPath({
    required String basePath,
    required String relativePath,
    required bool overwrite,
  }) async {
    final normalized = _validatedDownloadRelativePath(relativePath);

    if (PathMatcher.isContentUri(basePath)) {
      return _fileCacheGateway.ensureFolderPath(
        folder: basePath,
        relativePath: normalized,
        overwrite: overwrite,
      );
    }

    final folder = Directory(_resolveLocalPathWithin(basePath, normalized));
    try {
      await folder.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _joinFolderPath(String basePath, String relativePath) {
    final normalizedRelative = _validatedDownloadRelativePath(relativePath);
    if (PathMatcher.isContentUri(basePath)) {
      return '${_trimRightSlash(basePath)}::$normalizedRelative';
    }
    return _resolveLocalPathWithin(basePath, normalizedRelative);
  }

  JsonDocumentLocation _jsonDownloadLocation(
    String workRootPath,
    String relativePath,
  ) {
    final parentRelative = path.posix.dirname(relativePath);
    final folder = parentRelative == '.'
        ? workRootPath
        : _joinFolderPath(workRootPath, parentRelative);
    return JsonDocumentLocation.folderChild(
      folder: folder,
      name: path.posix.basename(relativePath),
    );
  }

  String _validatedDownloadRelativePath(String relativePath) {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (normalized.isEmpty ||
        path.posix.isAbsolute(normalized) ||
        path.windows.isAbsolute(normalized) ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw FormatException('Invalid download path: $relativePath');
    }
    final segments = normalized.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException('Invalid download path: $relativePath');
    }
    return segments.join('/');
  }

  String _resolveLocalPathWithin(String basePath, String relativePath) {
    final normalizedRelative = _validatedDownloadRelativePath(relativePath);
    final root = path.normalize(path.absolute(basePath));
    final target = path.normalize(
      path.absolute(
        path.join(root, normalizedRelative.replaceAll('/', path.separator)),
      ),
    );
    if (!path.isWithin(root, target)) {
      throw const FormatException('Download path escapes its destination.');
    }
    return target;
  }

  AudioDetail _buildBackupDetail(AsmrWork work, String workRootPath) {
    return AudioDetail(
      target: AudioDetailTarget.libraryRootFolder(workRootPath),
      rjCode: work.rjCode,
      workTitle: work.title,
      circleName: work.circleName,
      voiceActors: work.voiceActors,
      tags: work.tags,
      releaseDate: work.releaseDate,
      duration: work.duration > Duration.zero ? work.duration : null,
      salesCount: work.dlCount > 0 ? work.dlCount : null,
      rating: work.rating > 0 ? work.rating.clamp(0, 5).toDouble() : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ).normalizedForSave(DateTime.now());
  }

  String? _downloadUrlFor(AsmrTrackFile node) {
    final candidates = <String?>[
      if (<String?>[
        node.streamUrl,
        node.downloadUrl,
        node.lowQualityUrl,
      ].any(AsmrApiService.isOfficialMediaUrl))
        ...AsmrApiService.mediaDownloadUrlsForHash(node.hash),
      node.downloadUrl,
      node.streamUrl,
      node.lowQualityUrl,
    ];
    for (final candidate in candidates) {
      final value = candidate?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  Future<File> _persistentStagingFile(
    String workRootPath,
    String relativePath,
  ) async {
    final root = await _stagingDirectoryProvider();
    final key = sha256
        .convert(utf8.encode('$workRootPath|$relativePath'))
        .toString();
    return File(path.join(root.path, 'asmr_downloads', '$key.doujin.part'));
  }

  String _trimRightSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
