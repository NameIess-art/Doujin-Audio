import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/audio_detail.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';

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
    this.backupError,
  });

  final AudioDetail detail;
  final bool backupAttempted;
  final bool backupSaved;
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
  static const _maxEmbeddedCoverBytes = 64 * 1024 * 1024;
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
    final databaseDetails = await Future.wait(
      loadedDatabaseDetails.map(_restoreMissingDatabaseCover),
    );
    final resultsByKey = <String, AudioDetailLoadResult>{
      for (final detail in databaseDetails)
        _detailKeyForTarget(detail.target): AudioDetailLoadResult(
          detail: detail,
        ),
    };
    final missingTargets = targetsByKey.entries
        .where((entry) => !resultsByKey.containsKey(entry.key))
        .toList(growable: false);
    final restoredDetails = <AudioDetail>[];
    const concurrency = 8;
    for (var start = 0; start < missingTargets.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, missingTargets.length);
      final chunk = missingTargets.sublist(start, end);
      final backups = await Future.wait(
        chunk.map((entry) => _readBackup(entry.value)),
      );
      for (var index = 0; index < chunk.length; index++) {
        final entry = chunk[index];
        final backup = backups[index];
        if (backup == null) {
          resultsByKey[entry.key] = AudioDetailLoadResult(
            detail: AudioDetail.empty(entry.value),
          );
          continue;
        }
        final normalized = backup.normalizedForSave(_now());
        restoredDetails.add(normalized);
        resultsByKey[entry.key] = AudioDetailLoadResult(
          detail: normalized,
          restoredFromBackup: true,
        );
      }
    }
    await _databaseRepository.upsertAudioDetails(restoredDetails);
    return <AudioDetailLoadResult>[
      for (final target in normalizedTargets)
        resultsByKey[_detailKeyForTarget(target)]!,
    ];
  }

  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    var normalized = detail
        .copyWith(target: _normalizeTarget(detail.target))
        .normalizedForSave(_now());
    normalized = await _persistDerivedCover(normalized);
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
        );
      } catch (error) {
        return AudioDetailSaveResult(
          detail: normalized,
          backupAttempted: true,
          backupSaved: false,
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
      );
    } catch (error) {
      return AudioDetailSaveResult(
        detail: normalized,
        backupAttempted: true,
        backupSaved: false,
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
    if (PathMatcher.isContentUri(target.targetPath)) {
      return _readSingleFileBackupEntryViaChannel(target);
    }
    final backupFile = _singleDirBackupFile(target.targetPath);
    if (!await backupFile.exists()) return null;
    try {
      final raw = await backupFile.readAsString();
      return _parseSingleFileEntry(target, raw);
    } catch (_) {
      return null;
    }
  }

  /// Reads the backup via the native channel for content URI paths.
  Future<AudioDetail?> _readSingleFileBackupEntryViaChannel(
    AudioDetailTarget target,
  ) async {
    try {
      final raw = await _fileCacheGateway.readSingleFileDetailBackup(
        target.targetPath,
      );
      if (raw == null || raw.isEmpty) return null;
      return _parseSingleFileEntry(target, raw);
    } catch (_) {
      return null;
    }
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
        Map<String, dynamic>? matchedEntry;
        var matchedScore = 0;
        var hasTie = false;
        for (final item in decoded) {
          final entry = _stringKeyedMap(item);
          if (entry == null) continue;
          final entryPath = entry['targetPath'] as String?;
          if (entryPath == null) continue;
          final score = _singleFileEntryMatchScore(target, entryPath);
          if (score <= 0) continue;
          if (score > matchedScore) {
            matchedEntry = entry;
            matchedScore = score;
            hasTie = false;
          } else if (score == matchedScore) {
            hasTie = true;
          }
        }
        if (matchedEntry != null && !hasTie) {
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
    try {
      final rawJson = await _readFolderBackupJson(target);
      if (rawJson == null || rawJson.isEmpty) return null;
      final decoded = json.decode(rawJson);
      if (decoded is! Map<String, dynamic>) return null;
      final detail = await _detailFromBackup(target, decoded);
      if (detail.target.targetType != target.targetType) return null;
      return detail.copyWith(target: target);
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
    if (byteLength <= 0 || byteLength > _maxEmbeddedCoverBytes) return backup;
    final bytes = await coverFile.readAsBytes();
    final mimeType = _imageMimeType(coverPath, bytes);
    if (mimeType == null) return backup;
    final digest = sha256.convert(bytes).toString();
    backup[_cardCoverEmbeddedKey] = <String, Object>{
      'encoding': 'base64',
      'mimeType': mimeType,
      'byteLength': bytes.length,
      'sha256': digest,
      'data': base64Encode(bytes),
    };
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
        expectedLength > _maxEmbeddedCoverBytes ||
        encoded == null ||
        encoded.length > ((_maxEmbeddedCoverBytes + 2) ~/ 3) * 4) {
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
        _imageMimeType('', bytes) != mimeType.toLowerCase()) {
      return null;
    }

    return _writePortableCover(bytes, mimeType, expectedDigest);
  }

  Future<AudioDetail> _persistDerivedCover(AudioDetail detail) async {
    final coverPath = detail.cardCoverPath;
    if (coverPath == null ||
        PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return detail;
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
      return detail;
    }

    final source = File(coverPath);
    if (!await source.exists()) return detail;
    final byteLength = await source.length();
    if (byteLength <= 0 || byteLength > _maxEmbeddedCoverBytes) return detail;
    final bytes = await source.readAsBytes();
    final mimeType = _imageMimeType(coverPath, bytes);
    if (mimeType == null) return detail;
    final digest = sha256.convert(bytes).toString();
    final storedPath = await _writePortableCover(bytes, mimeType, digest);
    return detail.copyWith(cardCoverPath: storedPath);
  }

  Future<String> _writePortableCover(
    Uint8List bytes,
    String mimeType,
    String digest,
  ) async {
    final directory = await _portableCoverDirectory();
    await directory.create(recursive: true);
    final extension = _extensionForImageMimeType(mimeType);
    final output = File(path.join(directory.path, '$digest.$extension'));
    if (await output.exists()) {
      final existingBytes = await output.readAsBytes();
      if (existingBytes.length == bytes.length &&
          sha256.convert(existingBytes).toString() == digest) {
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

  String? _imageMimeType(String filePath, Uint8List bytes) {
    final detected = lookupMimeType(filePath, headerBytes: bytes);
    return detected?.toLowerCase().startsWith('image/') == true
        ? detected!.toLowerCase()
        : null;
  }

  String _extensionForImageMimeType(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/bmp' => 'bmp',
      'image/avif' => 'avif',
      'image/heic' || 'image/heif' => 'heic',
      _ => 'image',
    };
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
    final coverPath = detail.cardCoverPath;
    if (coverPath == null ||
        PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath) ||
        await File(coverPath).exists()) {
      return detail;
    }

    final backupDetail = await _readBackup(detail.target);
    final restoredCoverPath = backupDetail?.cardCoverPath;
    if (restoredCoverPath == null || restoredCoverPath == coverPath) {
      return detail;
    }
    if (!PathMatcher.isContentUri(restoredCoverPath) &&
        !PathMatcher.isRemoteUri(restoredCoverPath) &&
        !await File(restoredCoverPath).exists()) {
      return detail;
    }

    final restored = detail.copyWith(cardCoverPath: restoredCoverPath);
    await _databaseRepository.upsertAudioDetail(restored);
    return restored;
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
    final extension = path.extension(fileName);
    final stem = extension.isEmpty
        ? fileName
        : fileName.substring(0, fileName.length - extension.length);
    final stableStem = stem.replaceFirst(RegExp(r'\s+\(\d+\)$'), '');
    return '${stableStem.toLowerCase()}${extension.toLowerCase()}';
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
