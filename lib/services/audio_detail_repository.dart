import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/audio_detail.dart';
import 'audio_database_repository.dart';
import 'app_log_service.dart';
import 'file_cache_platform_gateway.dart';
import 'path_matcher.dart';
import 'path_display.dart';

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
  }) : _databaseRepository = databaseRepository ?? AudioDatabaseRepository(),
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _now = now ?? DateTime.now;

  static const backupFileName = 'nameless-audio.json';
  final AudioDatabaseRepository _databaseRepository;
  final FileCachePlatformGateway _fileCacheGateway;
  final DateTime Function() _now;

  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    final normalizedTarget = _normalizeTarget(target);
    final databaseDetail = await _databaseRepository.loadAudioDetail(
      normalizedTarget,
    );
    if (databaseDetail != null) {
      return AudioDetailLoadResult(detail: databaseDetail);
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

    final databaseDetails = await _databaseRepository.loadAudioDetails(
      normalizedTargets,
    );
    final detailsByKey = <String, AudioDetail>{
      for (final detail in databaseDetails)
        _detailKeyForTarget(detail.target): detail,
    };
    final results = <AudioDetailLoadResult>[];
    for (final target in normalizedTargets) {
      final key = _detailKeyForTarget(target);
      final databaseDetail = detailsByKey[key];
      if (databaseDetail != null) {
        results.add(AudioDetailLoadResult(detail: databaseDetail));
        continue;
      }
      results.add(await load(target));
    }
    return results;
  }

  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    final normalized = detail
        .copyWith(target: _normalizeTarget(detail.target))
        .normalizedForSave(_now());
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
      ).convert(normalized.toBackupJson());
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
  AudioDetail? _parseSingleFileEntry(AudioDetailTarget target, String raw) {
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
          final detail = AudioDetail.fromBackupJson(target, matchedEntry);
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
    final newEntry = detail.toBackupJson();
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

    final newEntry = detail.toBackupJson();
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
      final detail = AudioDetail.fromBackupJson(target, decoded);
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
