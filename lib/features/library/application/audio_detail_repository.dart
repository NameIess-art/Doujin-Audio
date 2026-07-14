import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/audio_detail.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import 'cover_image_cache_policy.dart';

class AudioDetailLoadResult {
  const AudioDetailLoadResult({
    required this.detail,
    this.restoredFromBackup = false,
  });

  final AudioDetail detail;
  final bool restoredFromBackup;
}

class AudioDetailSaveResult {
  const AudioDetailSaveResult({
    required this.detail,
    required this.backupAttempted,
    required this.backupSaved,
    this.coverPortabilitySkipped = false,
    this.backupError,
  });

  final AudioDetail detail;
  final bool backupAttempted;
  final bool backupSaved;
  final bool coverPortabilitySkipped;
  final Object? backupError;

  bool get backupFailed => backupAttempted && !backupSaved;
}

class AudioDetailRepository {
  AudioDetailRepository({
    AudioDatabaseRepository? databaseRepository,
    FileCachePlatformGateway? fileCacheGateway,
    DateTime Function()? now,
    Future<Directory> Function()? portableCoverDirectory,
  }) : _databaseRepository = databaseRepository ?? AudioDatabaseRepository(),
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _now = now ?? DateTime.now,
       _portableCoverDirectory =
           portableCoverDirectory ?? _defaultPortableCoverDirectory;

  static const backupFileName = 'nameless-audio.json';
  static const _cardCoverRelativePathKey = 'cardCoverRelativePath';
  static const _cardCoverEmbeddedKey = 'cardCoverEmbedded';
  final AudioDatabaseRepository _databaseRepository;
  final FileCachePlatformGateway _fileCacheGateway;
  final DateTime Function() _now;
  final Future<Directory> Function() _portableCoverDirectory;

  static Future<Directory> _defaultPortableCoverDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(path.join(supportDirectory.path, 'portable_card_covers'));
  }

  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    final normalizedTarget = _normalizeTarget(target);
    final databaseDetail = await _databaseRepository.loadAudioDetail(
      normalizedTarget,
    );
    if (databaseDetail != null) {
      return AudioDetailLoadResult(
        detail: await _restoreMissingDatabaseCover(databaseDetail),
      );
    }

    final backupDetail = await _readBackup(normalizedTarget);
    if (backupDetail == null) {
      return AudioDetailLoadResult(detail: AudioDetail.empty(normalizedTarget));
    }

    final normalized = backupDetail.normalizedForSave(_now());
    await _databaseRepository.upsertAudioDetail(normalized);
    return AudioDetailLoadResult(detail: normalized, restoredFromBackup: true);
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final normalizedTargets = targets
        .map(_normalizeTarget)
        .toList(growable: false);
    if (normalizedTargets.isEmpty) return const <AudioDetailLoadResult>[];

    final targetsByKey = <String, AudioDetailTarget>{
      for (final target in normalizedTargets)
        _detailKeyForTarget(target): target,
    };
    final loadedDatabaseDetails = await _databaseRepository.loadAudioDetails(
      targetsByKey.values,
    );
    final databaseDetailsByKey = <String, AudioDetail>{
      for (final detail in loadedDatabaseDetails)
        _detailKeyForTarget(detail.target): detail,
    };
    final resultsByKey = <String, AudioDetailLoadResult>{
      for (final detail in loadedDatabaseDetails)
        _detailKeyForTarget(detail.target): AudioDetailLoadResult(
          detail: detail,
        ),
    };

    final backupTargetsByKey = <String, AudioDetailTarget>{};
    for (final entry in targetsByKey.entries) {
      final databaseDetail = databaseDetailsByKey[entry.key];
      if (databaseDetail == null ||
          await _needsBackupCoverRestore(databaseDetail)) {
        backupTargetsByKey[entry.key] = entry.value;
      }
    }
    final backupDetailsByKey = await _readBackupsForTargets(
      backupTargetsByKey.values,
    );
    final detailsToUpsert = <AudioDetail>[];
    for (final entry in backupTargetsByKey.entries) {
      final databaseDetail = databaseDetailsByKey[entry.key];
      final backupDetail = backupDetailsByKey[entry.key];
      if (databaseDetail == null) {
        if (backupDetail == null) {
          resultsByKey[entry.key] = AudioDetailLoadResult(
            detail: AudioDetail.empty(entry.value),
          );
          continue;
        }
        final normalized = backupDetail.normalizedForSave(_now());
        detailsToUpsert.add(normalized);
        resultsByKey[entry.key] = AudioDetailLoadResult(
          detail: normalized,
          restoredFromBackup: true,
        );
        continue;
      }
      final restored = await _restoreMissingDatabaseCoverFromBackup(
        databaseDetail,
        backupDetail,
      );
      if (restored.cardCoverPath != databaseDetail.cardCoverPath) {
        detailsToUpsert.add(restored);
      }
      resultsByKey[entry.key] = AudioDetailLoadResult(detail: restored);
    }
    await _databaseRepository.upsertAudioDetails(detailsToUpsert);
    return <AudioDetailLoadResult>[
      for (final target in normalizedTargets)
        resultsByKey[_detailKeyForTarget(target)]!,
    ];
  }

  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    var normalized = detail
        .copyWith(target: _normalizeTarget(detail.target))
        .normalizedForSave(_now());
    final persistedCover = await _persistDerivedCover(normalized);
    normalized = persistedCover.detail;
    final coverPortabilitySkipped = persistedCover.portabilitySkipped;
    await _databaseRepository.upsertAudioDetail(normalized);

    if (!normalized.target.isLibraryRootFolder) {
      // Single audio file: save into nameless-audio.json in the same directory,
      // using an array so multiple standalone files in the same folder each
      // have their own entry keyed by targetPath.
      try {
        await _writeSingleFileBackup(normalized);
        return AudioDetailSaveResult(
          detail: normalized,
          backupAttempted: true,
          backupSaved: true,
          coverPortabilitySkipped: coverPortabilitySkipped,
        );
      } catch (error) {
        return AudioDetailSaveResult(
          detail: normalized,
          backupAttempted: true,
          backupSaved: false,
          coverPortabilitySkipped: coverPortabilitySkipped,
          backupError: error,
        );
      }
    }

    try {
      final payload = const JsonEncoder.withIndent(
        '  ',
      ).convert(await _backupJson(normalized));
      if (PathMatcher.isContentUri(normalized.target.targetPath)) {
        final saved = await _fileCacheGateway.writeAudioDetailBackup(
          folder: normalized.target.targetPath,
          json: payload,
        );
        if (!saved) {
          throw const FileSystemException('Content backup was not saved.');
        }
      } else {
        final backupFile = _folderBackupFile(normalized.target.targetPath);
        await backupFile.writeAsString(payload, flush: true);
      }
      return AudioDetailSaveResult(
        detail: normalized,
        backupAttempted: true,
        backupSaved: true,
        coverPortabilitySkipped: coverPortabilitySkipped,
      );
    } catch (error) {
      return AudioDetailSaveResult(
        detail: normalized,
        backupAttempted: true,
        backupSaved: false,
        coverPortabilitySkipped: coverPortabilitySkipped,
        backupError: error,
      );
    }
  }

  Future<void> delete(AudioDetailTarget target) {
    return _databaseRepository.deleteAudioDetail(_normalizeTarget(target));
  }

  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final rjCode = AudioDetail.findRjCodeInText(text);
    if (rjCode == null) return null;

    final result = await load(target);
    if (result.detail.rjCode.trim().isNotEmpty) return null;

    return save(result.detail.copyWith(rjCode: rjCode));
  }

  // ---------------------------------------------------------------------------
  // Single-file backup helpers
  // ---------------------------------------------------------------------------

  /// Returns the directory that contains [audioFilePath].
  String _dirOf(String audioFilePath) => path.dirname(audioFilePath);

  /// The shared backup file for all standalone audio files in the same
  /// directory as [audioFilePath].
  File _singleDirBackupFile(String audioFilePath) {
    return File(path.join(_dirOf(audioFilePath), backupFileName));
  }

  /// Reads the array-format backup file for the directory containing
  /// [audioFilePath] and returns the entry whose targetPath matches, or null.
  Future<AudioDetail?> _readSingleFileBackupEntry(
    AudioDetailTarget target,
  ) async {
    try {
      final raw = await _readSingleFileBackupJson(target);
      if (raw == null || raw.isEmpty) return null;
      return _parseSingleFileEntry(target, raw);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readSingleFileBackupJson(AudioDetailTarget target) async {
    if (PathMatcher.isContentUri(target.targetPath)) {
      return _fileCacheGateway.readSingleFileDetailBackup(target.targetPath);
    }
    final backupFile = _singleDirBackupFile(target.targetPath);
    if (!await backupFile.exists()) return null;
    return backupFile.readAsString();
  }

  /// Parses [raw] JSON and returns the entry whose
  /// targetPath matches [target.targetPath], or null.
  Future<AudioDetail?> _parseSingleFileEntry(
    AudioDetailTarget target,
    String raw,
  ) async {
    if (raw.isEmpty) return null;
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        final index = _SingleFileBackupIndex(_stringKeyedMapList(decoded));
        final matchedEntry = index.match(target);
        if (matchedEntry != null) {
          final detail = await _detailFromBackup(target, matchedEntry);
          if (detail.target.targetType == target.targetType) {
            return detail.copyWith(target: target);
          }
        }
        return null;
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  /// Writes [detail] into the shared `nameless-audio.json` in the same
  /// directory as the audio file, updating the matching entry or appending.
  Future<void> _writeSingleFileBackup(AudioDetail detail) async {
    if (PathMatcher.isContentUri(detail.target.targetPath)) {
      await _writeSingleFileBackupViaChannel(detail);
      return;
    }
    final backupFile = _singleDirBackupFile(detail.target.targetPath);

    // Read existing entries from the file (if any).
    List<Map<String, dynamic>> entries = [];
    if (await backupFile.exists()) {
      try {
        final raw = await backupFile.readAsString();
        if (raw.isNotEmpty) {
          final decoded = json.decode(raw);
          if (decoded is List) {
            entries = _stringKeyedMapList(decoded);
          }
        }
      } catch (_) {
        // Corrupt file — start fresh.
        entries = [];
      }
    }

    // Update the matching entry or append a new one.
    final newEntry = await _backupJson(detail);
    final idx = _singleFileBackupEntryIndex(detail.target, entries);
    if (idx >= 0) {
      entries[idx] = newEntry;
    } else {
      entries.add(newEntry);
    }

    final payload = const JsonEncoder.withIndent('  ').convert(entries);
    await backupFile.writeAsString(payload, flush: true);
  }

  /// Writes the backup via the native channel for content URI paths.
  Future<void> _writeSingleFileBackupViaChannel(AudioDetail detail) async {
    // Read the existing backup from the native side first so we can merge.
    String? existingRaw;
    try {
      existingRaw = await _fileCacheGateway.readSingleFileDetailBackup(
        detail.target.targetPath,
      );
    } catch (_) {
      existingRaw = null;
    }

    List<Map<String, dynamic>> entries = [];
    if (existingRaw != null && existingRaw.isNotEmpty) {
      try {
        final decoded = json.decode(existingRaw);
        if (decoded is List) {
          entries = _stringKeyedMapList(decoded);
        }
      } catch (_) {
        entries = [];
      }
    }

    final newEntry = await _backupJson(detail);
    final idx = _singleFileBackupEntryIndex(detail.target, entries);
    if (idx >= 0) {
      entries[idx] = newEntry;
    } else {
      entries.add(newEntry);
    }

    final payload = const JsonEncoder.withIndent('  ').convert(entries);
    final saved = await _fileCacheGateway.writeSingleFileDetailBackup(
      filePath: detail.target.targetPath,
      json: payload,
    );
    if (!saved) {
      throw const FileSystemException(
        'Single-file content backup was not saved.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Shared backup helpers
  // ---------------------------------------------------------------------------

  Future<AudioDetail?> _readBackup(AudioDetailTarget target) async {
    if (!target.isLibraryRootFolder) {
      return _readSingleFileBackupEntry(target);
    }
    final rawJson = await _readBackupJsonSafely(target);
    if (rawJson == null || rawJson.isEmpty) return null;
    return _parseFolderBackup(target, rawJson);
  }

  Future<Map<String, AudioDetail?>> _readBackupsForTargets(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final groups = <String, List<AudioDetailTarget>>{};
    for (final target in targets) {
      groups.putIfAbsent(_backupSourceKey(target), () => []).add(target);
    }
    final results = <String, AudioDetail?>{};
    final groupEntries = groups.entries.toList(growable: false);
    const concurrency = 8;
    for (var start = 0; start < groupEntries.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, groupEntries.length);
      final chunk = groupEntries.sublist(start, end);
      final raws = await Future.wait(
        chunk.map((entry) => _readBackupJsonSafely(entry.value.first)),
      );
      for (var index = 0; index < chunk.length; index++) {
        final groupedTargets = chunk[index].value;
        final raw = raws[index];
        if (raw == null || raw.isEmpty) {
          for (final target in groupedTargets) {
            results[_detailKeyForTarget(target)] = null;
          }
          continue;
        }
        if (groupedTargets.first.isLibraryRootFolder) {
          final decoded = _decodeFolderBackup(raw);
          final details = await Future.wait(
            groupedTargets.map(
              (target) => _detailFromFolderBackup(target, decoded),
            ),
          );
          for (
            var targetIndex = 0;
            targetIndex < groupedTargets.length;
            targetIndex++
          ) {
            results[_detailKeyForTarget(groupedTargets[targetIndex])] =
                details[targetIndex];
          }
          continue;
        }
        final singleFileIndex = _decodeSingleFileBackupIndex(raw);
        for (
          var targetStart = 0;
          targetStart < groupedTargets.length;
          targetStart += concurrency
        ) {
          final targetEnd = (targetStart + concurrency).clamp(
            0,
            groupedTargets.length,
          );
          final targetChunk = groupedTargets.sublist(targetStart, targetEnd);
          final details = await Future.wait(
            targetChunk.map(
              (target) => _detailFromSingleFileIndex(target, singleFileIndex),
            ),
          );
          for (
            var targetIndex = 0;
            targetIndex < targetChunk.length;
            targetIndex++
          ) {
            results[_detailKeyForTarget(targetChunk[targetIndex])] =
                details[targetIndex];
          }
        }
      }
    }
    return results;
  }

  String _backupSourceKey(AudioDetailTarget target) {
    return target.isLibraryRootFolder
        ? 'root|${PathMatcher.equivalenceKey(target.targetPath)}'
        : 'single|${PathMatcher.parentEquivalenceKey(target.targetPath)}';
  }

  Future<String?> _readBackupJsonSafely(AudioDetailTarget target) async {
    try {
      return target.isLibraryRootFolder
          ? _readFolderBackupJson(target)
          : _readSingleFileBackupJson(target);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_read_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<AudioDetail?> _parseFolderBackup(
    AudioDetailTarget target,
    String raw,
  ) async {
    return _detailFromFolderBackup(target, _decodeFolderBackup(raw));
  }

  Map<String, dynamic>? _decodeFolderBackup(String raw) {
    try {
      final decoded = json.decode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<AudioDetail?> _detailFromFolderBackup(
    AudioDetailTarget target,
    Map<String, dynamic>? decoded,
  ) async {
    if (decoded == null) return null;
    try {
      final detail = await _detailFromBackup(target, decoded);
      return detail.target.targetType == target.targetType
          ? detail.copyWith(target: target)
          : null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  _SingleFileBackupIndex? _decodeSingleFileBackupIndex(String raw) {
    try {
      final decoded = json.decode(raw);
      return decoded is List
          ? _SingleFileBackupIndex(_stringKeyedMapList(decoded))
          : null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<AudioDetail?> _detailFromSingleFileIndex(
    AudioDetailTarget target,
    _SingleFileBackupIndex? index,
  ) async {
    final entry = index?.match(target);
    if (entry == null) return null;
    try {
      final detail = await _detailFromBackup(target, entry);
      return detail.target.targetType == target.targetType
          ? detail.copyWith(target: target)
          : null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<String?> _readFolderBackupJson(AudioDetailTarget target) async {
    if (PathMatcher.isContentUri(target.targetPath)) {
      return _fileCacheGateway.readAudioDetailBackup(target.targetPath);
    }
    final backupFile = _folderBackupFile(target.targetPath);
    if (!await backupFile.exists()) return null;
    return backupFile.readAsString();
  }

  Future<Map<String, dynamic>> _backupJson(AudioDetail detail) async {
    final backup = detail.toBackupJson();
    final coverPath = detail.cardCoverPath;
    if (coverPath == null) return backup;
    final portableBasePath = _portableBasePath(
      detail.target.targetType,
      detail.target.targetPath,
    );
    final relativePath = portableBasePath == null
        ? null
        : PathMatcher.relativeWithin(coverPath, portableBasePath);
    final portablePath = _normalizeRelativeCoverPath(relativePath);
    if (portablePath != null) {
      backup[_cardCoverRelativePathKey] = portablePath;
      return backup;
    }

    if (PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return backup;
    }
    final coverFile = File(coverPath);
    if (!await coverFile.exists()) return backup;
    final byteLength = await coverFile.length();
    if (byteLength <= 0 || byteLength > maxCoverFileBytes) return backup;
    final embedded = await _encodeCoverBackupInIsolate(coverPath);
    if (embedded != null) backup[_cardCoverEmbeddedKey] = embedded;
    return backup;
  }

  Future<AudioDetail> _detailFromBackup(
    AudioDetailTarget target,
    Map<String, dynamic> backup,
  ) async {
    final detail = AudioDetail.fromBackupJson(target, backup);
    final relativePath = _normalizeRelativeCoverPath(
      backup[_cardCoverRelativePathKey],
    );
    if (relativePath != null) {
      final restoredRelativeCover = _restoreRelativeCoverPath(
        target,
        backup,
        relativePath,
      );
      if (restoredRelativeCover != null) {
        return detail.copyWith(cardCoverPath: restoredRelativeCover);
      }
    }

    final embeddedCoverPath = await _restoreEmbeddedCoverPath(
      backup[_cardCoverEmbeddedKey],
    );
    return embeddedCoverPath == null
        ? detail
        : detail.copyWith(cardCoverPath: embeddedCoverPath);
  }

  String? _restoreRelativeCoverPath(
    AudioDetailTarget target,
    Map<String, dynamic> backup,
    String relativePath,
  ) {
    final previousTargetPath = backup['targetPath'] as String?;
    final previousCoverPath = backup['cardCoverPath'] as String?;
    final currentBasePath = _portableBasePath(
      target.targetType,
      target.targetPath,
    );
    if (currentBasePath == null) return null;

    if (previousTargetPath != null && previousCoverPath != null) {
      final previousBasePath = _portableBasePath(
        target.targetType,
        previousTargetPath,
      );
      if (previousBasePath != null) {
        final previousRelativePath = _normalizeRelativeCoverPath(
          PathMatcher.relativeWithin(previousCoverPath, previousBasePath),
        );
        if (previousRelativePath == relativePath) {
          final migratedPath = PathMatcher.replaceWithinOrEqual(
            previousCoverPath,
            previousBasePath,
            currentBasePath,
          );
          final migratedRelativePath = _normalizeRelativeCoverPath(
            PathMatcher.relativeWithin(migratedPath, currentBasePath),
          );
          if (migratedRelativePath == relativePath) return migratedPath;
        }
      }
    }

    if (!PathMatcher.isContentUri(currentBasePath)) {
      final restoredPath = PathMatcher.join(currentBasePath, relativePath);
      final restoredRelativePath = _normalizeRelativeCoverPath(
        PathMatcher.relativeWithin(restoredPath, currentBasePath),
      );
      if (restoredRelativePath == relativePath) return restoredPath;
    }
    return null;
  }

  Future<String?> _restoreEmbeddedCoverPath(Object? value) async {
    if (value is! Map) return null;
    final embedded = value.cast<Object?, Object?>();
    if (embedded['encoding'] != 'base64') return null;
    final mimeType = embedded['mimeType'] as String?;
    final expectedDigest = embedded['sha256'] as String?;
    final encoded = embedded['data'] as String?;
    final expectedLength = (embedded['byteLength'] as num?)?.toInt();
    if (mimeType == null ||
        !mimeType.toLowerCase().startsWith('image/') ||
        expectedDigest == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest) ||
        expectedLength == null ||
        expectedLength <= 0 ||
        expectedLength > maxCoverFileBytes ||
        encoded == null ||
        encoded.length > ((maxCoverFileBytes + 2) ~/ 3) * 4) {
      return null;
    }

    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      return null;
    }
    if (bytes.length != expectedLength ||
        sha256.convert(bytes).toString() != expectedDigest ||
        detectCoverMimeType('', bytes) != mimeType.toLowerCase()) {
      return null;
    }

    return _writePortableCover(bytes, mimeType, expectedDigest);
  }

  Future<({AudioDetail detail, bool portabilitySkipped})> _persistDerivedCover(
    AudioDetail detail,
  ) async {
    final coverPath = detail.cardCoverPath;
    if (coverPath == null ||
        PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return (detail: detail, portabilitySkipped: false);
    }
    final portableBasePath = _portableBasePath(
      detail.target.targetType,
      detail.target.targetPath,
    );
    if (portableBasePath != null &&
        _normalizeRelativeCoverPath(
              PathMatcher.relativeWithin(coverPath, portableBasePath),
            ) !=
            null) {
      return (detail: detail, portabilitySkipped: false);
    }

    final source = File(coverPath);
    if (!await source.exists()) {
      return (detail: detail, portabilitySkipped: false);
    }
    final byteLength = await source.length();
    if (byteLength <= 0) {
      return (detail: detail, portabilitySkipped: false);
    }
    if (byteLength > maxCoverFileBytes) {
      return (detail: detail, portabilitySkipped: true);
    }
    final coverData = await _readCoverDataInIsolate(coverPath);
    if (coverData == null) {
      return (detail: detail, portabilitySkipped: false);
    }
    final bytes = coverData['bytes']! as Uint8List;
    final mimeType = coverData['mimeType']! as String;
    final digest = coverData['sha256']! as String;
    final storedPath = await _writePortableCover(bytes, mimeType, digest);
    return (
      detail: detail.copyWith(cardCoverPath: storedPath),
      portabilitySkipped: false,
    );
  }

  Future<String> _writePortableCover(
    Uint8List bytes,
    String mimeType,
    String digest,
  ) async {
    final directory = await _portableCoverDirectory();
    await directory.create(recursive: true);
    final extension = extensionForCoverMimeType(mimeType);
    final output = File(path.join(directory.path, '$digest.$extension'));
    if (await output.exists()) {
      final existingLength = await output.length();
      final existingDigest = existingLength == bytes.length
          ? await _hashFileInIsolate(output.path)
          : null;
      if (existingDigest == digest) {
        return output.path;
      }
    }

    final partial = File('${output.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (await output.exists()) await output.delete();
      await partial.rename(output.path);
      return output.path;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  String? _portableBasePath(
    AudioDetailTargetType targetType,
    String targetPath,
  ) {
    if (targetType == AudioDetailTargetType.libraryRootFolder) {
      return targetPath;
    }
    if (PathMatcher.isContentUri(targetPath)) return null;
    return path.dirname(targetPath);
  }

  String? _normalizeRelativeCoverPath(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.startsWith('/')) return null;
    final segments = normalized.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      return null;
    }
    return segments.join('/');
  }

  Future<AudioDetail> _restoreMissingDatabaseCover(AudioDetail detail) async {
    if (!await _needsBackupCoverRestore(detail)) return detail;
    final backupDetail = await _readBackup(detail.target);
    final restored = await _restoreMissingDatabaseCoverFromBackup(
      detail,
      backupDetail,
    );
    if (restored.cardCoverPath != detail.cardCoverPath) {
      await _databaseRepository.upsertAudioDetail(restored);
    }
    return restored;
  }

  Future<bool> _needsBackupCoverRestore(AudioDetail detail) async {
    final coverPath = detail.cardCoverPath;
    return coverPath != null &&
        !PathMatcher.isContentUri(coverPath) &&
        !PathMatcher.isRemoteUri(coverPath) &&
        !await File(coverPath).exists();
  }

  Future<AudioDetail> _restoreMissingDatabaseCoverFromBackup(
    AudioDetail detail,
    AudioDetail? backupDetail,
  ) async {
    final coverPath = detail.cardCoverPath;
    final restoredCoverPath = backupDetail?.cardCoverPath;
    if (restoredCoverPath == null || restoredCoverPath == coverPath) {
      return detail;
    }
    if (!PathMatcher.isContentUri(restoredCoverPath) &&
        !PathMatcher.isRemoteUri(restoredCoverPath) &&
        !await File(restoredCoverPath).exists()) {
      return detail;
    }

    return detail.copyWith(cardCoverPath: restoredCoverPath);
  }

  AudioDetailTarget _normalizeTarget(AudioDetailTarget target) {
    return AudioDetailTarget(
      targetType: target.targetType,
      targetPath: PathMatcher.normalize(target.targetPath),
    );
  }

  String _detailKeyForTarget(AudioDetailTarget target) {
    return '${target.targetType.dbValue}|${PathMatcher.normalize(target.targetPath)}';
  }

  int _singleFileBackupEntryIndex(
    AudioDetailTarget target,
    List<Map<String, dynamic>> entries,
  ) {
    var bestIndex = -1;
    var bestScore = 0;
    var hasTie = false;
    for (var i = 0; i < entries.length; i++) {
      final entryPath = entries[i]['targetPath'] as String?;
      if (entryPath == null) continue;
      final score = _singleFileEntryMatchScore(target, entryPath);
      if (score <= 0) continue;
      if (score > bestScore) {
        bestIndex = i;
        bestScore = score;
        hasTie = false;
      } else if (score == bestScore) {
        hasTie = true;
      }
    }
    return hasTie ? -1 : bestIndex;
  }

  int _singleFileEntryMatchScore(AudioDetailTarget target, String entryPath) {
    if (PathMatcher.equalsNormalized(entryPath, target.targetPath)) {
      return 3;
    }
    final entryName = PathDisplay.fileName(entryPath).trim();
    final targetName = PathDisplay.fileName(target.targetPath).trim();
    if (entryName.isEmpty || targetName.isEmpty) return 0;
    if (entryName == targetName) return 2;
    return _singleFileCopyKey(entryName) == _singleFileCopyKey(targetName)
        ? 1
        : 0;
  }

  String _singleFileCopyKey(String fileName) {
    return _singleFileCopyKeyValue(fileName);
  }

  List<Map<String, dynamic>> _stringKeyedMapList(List<dynamic> values) {
    final entries = <Map<String, dynamic>>[];
    for (final value in values) {
      final entry = _stringKeyedMap(value);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Map<String, dynamic>? _stringKeyedMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  File _folderBackupFile(String folderPath) {
    return File(path.join(folderPath, backupFileName));
  }
}

final class _SingleFileBackupIndex {
  _SingleFileBackupIndex(Iterable<Map<String, dynamic>> entries) {
    for (final entry in entries) {
      final entryPath = entry['targetPath'] as String?;
      if (entryPath == null) continue;
      _add(_byPath, PathMatcher.equivalenceKey(entryPath), entry);
      final fileName = PathDisplay.fileName(entryPath).trim();
      if (fileName.isEmpty) continue;
      _add(_byFileName, fileName, entry);
      _add(_byCopyKey, _singleFileCopyKeyValue(fileName), entry);
    }
  }

  final Map<String, List<Map<String, dynamic>>> _byPath = {};
  final Map<String, List<Map<String, dynamic>>> _byFileName = {};
  final Map<String, List<Map<String, dynamic>>> _byCopyKey = {};

  Map<String, dynamic>? match(AudioDetailTarget target) {
    final exactMatches = _byPath[PathMatcher.equivalenceKey(target.targetPath)];
    if (exactMatches != null) return _unique(exactMatches);
    final fileName = PathDisplay.fileName(target.targetPath).trim();
    if (fileName.isEmpty) return null;
    final fileNameMatches = _byFileName[fileName];
    if (fileNameMatches != null) return _unique(fileNameMatches);
    final copyMatches = _byCopyKey[_singleFileCopyKeyValue(fileName)];
    return copyMatches == null ? null : _unique(copyMatches);
  }

  static void _add(
    Map<String, List<Map<String, dynamic>>> index,
    String key,
    Map<String, dynamic> entry,
  ) {
    index.putIfAbsent(key, () => []).add(entry);
  }

  static Map<String, dynamic>? _unique(List<Map<String, dynamic>> matches) {
    return matches.length == 1 ? matches.single : null;
  }
}

String _singleFileCopyKeyValue(String fileName) {
  final extension = path.extension(fileName);
  final stem = extension.isEmpty
      ? fileName
      : fileName.substring(0, fileName.length - extension.length);
  final stableStem = stem.replaceFirst(RegExp(r'\s+\(\d+\)$'), '');
  return '${stableStem.toLowerCase()}${extension.toLowerCase()}';
}

Future<Map<String, Object>?> _encodeCoverBackupInIsolate(String filePath) {
  return Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || length > maxCoverFileBytes) return null;
    final bytes = await file.readAsBytes();
    final mimeType = detectCoverMimeType(filePath, bytes);
    if (mimeType == null) return null;
    return <String, Object>{
      'encoding': 'base64',
      'mimeType': mimeType,
      'byteLength': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'data': base64Encode(bytes),
    };
  });
}

Future<Map<String, Object>?> _readCoverDataInIsolate(String filePath) {
  return Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || length > maxCoverFileBytes) return null;
    final bytes = await file.readAsBytes();
    final mimeType = detectCoverMimeType(filePath, bytes);
    if (mimeType == null) return null;
    return <String, Object>{
      'bytes': bytes,
      'mimeType': mimeType,
      'sha256': sha256.convert(bytes).toString(),
    };
  });
}

Future<String?> _hashFileInIsolate(String filePath) {
  return Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    return sha256.convert(await file.readAsBytes()).toString();
  });
}
