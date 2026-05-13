import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/audio_detail.dart';
import 'audio_database_repository.dart';
import 'path_matcher.dart';
import 'platform_channels.dart';

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
    DateTime Function()? now,
  }) : _databaseRepository = databaseRepository ?? AudioDatabaseRepository(),
       _now = now ?? DateTime.now;

  static const backupFileName = 'nameless-audio.json';
  static const legacyBackupFileName = '.nameless-audio.json';
  static const singleBackupSuffix = '.nameless-audio.json';
  static const MethodChannel _fileCacheChannel = MethodChannel(
    FileCacheChannel.name,
  );

  final AudioDatabaseRepository _databaseRepository;
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

  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    final normalized = detail
        .copyWith(target: _normalizeTarget(detail.target))
        .normalizedForSave(_now());
    await _databaseRepository.upsertAudioDetail(normalized);

    if (!normalized.target.isLibraryRootFolder) {
      try {
        final backupFile = _backupFile(normalized.target);
        final payload = const JsonEncoder.withIndent(
          '  ',
        ).convert(normalized.toBackupJson());
        await backupFile.writeAsString(payload, flush: true);
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
        final saved =
            await _fileCacheChannel.invokeMethod<bool>(
              FileCacheMethod.writeAudioDetailBackup,
              {'folder': normalized.target.targetPath, 'json': payload},
            ) ??
            false;
        if (!saved) {
          throw const FileSystemException('Content backup was not saved.');
        }
      } else {
        final backupFile = _backupFile(normalized.target);
        await backupFile.writeAsString(payload, flush: true);
        await _deleteLegacyBackupIfNeeded(normalized.target);
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

  Future<AudioDetail?> _readBackup(AudioDetailTarget target) async {
    try {
      final rawJson = await _readBackupJson(target);
      if (rawJson == null || rawJson.isEmpty) return null;
      final decoded = json.decode(rawJson);
      if (decoded is! Map<String, dynamic>) return null;
      final detail = AudioDetail.fromBackupJson(target, decoded);
      if (detail.target.targetType != target.targetType) return null;
      return detail.copyWith(target: target);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readBackupJson(AudioDetailTarget target) async {
    if (PathMatcher.isContentUri(target.targetPath)) {
      return _fileCacheChannel.invokeMethod<String>(
        FileCacheMethod.readAudioDetailBackup,
        {'folder': target.targetPath},
      );
    }
    final backupFile = _backupFile(target);
    if (!await backupFile.exists()) {
      final legacyBackupFile = _backupFile(target, legacy: true);
      if (!await legacyBackupFile.exists()) return null;
      return legacyBackupFile.readAsString();
    }
    return backupFile.readAsString();
  }

  AudioDetailTarget _normalizeTarget(AudioDetailTarget target) {
    return AudioDetailTarget(
      targetType: target.targetType,
      targetPath: PathMatcher.normalize(target.targetPath),
    );
  }

  File _backupFile(AudioDetailTarget target, {bool legacy = false}) {
    if (target.isLibraryRootFolder) {
      return File(
        path.join(
          target.targetPath,
          legacy ? legacyBackupFileName : backupFileName,
        ),
      );
    }
    return File('${target.targetPath}$singleBackupSuffix');
  }

  Future<void> _deleteLegacyBackupIfNeeded(AudioDetailTarget target) async {
    if (!target.isLibraryRootFolder ||
        PathMatcher.isContentUri(target.targetPath)) {
      return;
    }
    final legacyBackupFile = _backupFile(target, legacy: true);
    try {
      if (await legacyBackupFile.exists()) {
        await legacyBackupFile.delete();
      }
    } catch (_) {
      // Legacy cleanup is best-effort; the modern backup and database are
      // already saved, so cleanup failure should not discard user edits.
    }
  }
}
