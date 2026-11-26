import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/cache/app_cache_service.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/logging/app_log_service.dart';
import 'cross_platform_sync_service.dart';
import 'diagnostic_report_service.dart';
import 'data_backup_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../settings/application/app_update_service.dart';

class DataSupportFileService {
  DataSupportFileService({
    DiagnosticReportService? diagnosticService,
    FileCachePlatformGateway? fileCacheGateway,
    AppUpdateService? appUpdateService,
    DataBackupService? backupService,
    bool Function()? isAndroid,
  }) : _diagnosticService =
           diagnosticService ??
           DiagnosticReportService(appUpdateService: appUpdateService),
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _backupService =
           backupService ??
           DataBackupService(appUpdateService: appUpdateService),
       _isAndroid = isAndroid ?? (() => AppPlatform.isAndroid);

  final DiagnosticReportService _diagnosticService;
  final FileCachePlatformGateway _fileCacheGateway;
  final bool Function() _isAndroid;
  final DataBackupService _backupService;

  Future<String?> exportDiagnostics({required String dialogTitle}) =>
      exportDiagnosticReport(
        reportService: _diagnosticService,
        fileCacheGateway: _fileCacheGateway,
        isAndroid: _isAndroid,
        dialogTitle: dialogTitle,
      );

  static Future<String?> exportDiagnosticReport({
    required DiagnosticReportService reportService,
    required FileCachePlatformGateway fileCacheGateway,
    required bool Function() isAndroid,
    required String dialogTitle,
  }) => _withProtectedTemporaryFile(
    'DoujinAudio-diagnostic-${_exportTimestamp()}.zip',
    (temporary) async {
      final report = await reportService.exportReport(temporary.path);
      return await _saveGeneratedExportFile(
        source: report,
        dialogTitle: dialogTitle,
        allowedExtensions: const <String>['zip'],
        mimeType: 'application/zip',
        fileCacheGateway: fileCacheGateway,
        isAndroid: isAndroid,
      );
    },
  );

  Future<String?> exportBackup({required String dialogTitle}) =>
      _withProtectedTemporaryFile(
        'DoujinAudio-backup-${_exportTimestamp()}.dabackup',
        (temporary) async {
          final backup = await _backupService.exportBackup(temporary.path);
          return await _saveGeneratedExportFile(
            source: backup,
            dialogTitle: dialogTitle,
            allowedExtensions: const <String>['dabackup'],
            mimeType: 'application/zip',
            fileCacheGateway: _fileCacheGateway,
            isAndroid: _isAndroid,
          );
        },
      );

  Future<PlatformFile?> pickBackupFile({required String dialogTitle}) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: const <String>['dabackup'],
      withReadStream: true,
      lockParentWindow: true,
    );
    return result?.files.singleOrNull;
  }

  Future<T?> withBackupFilePath<T>(
    PlatformFile selected,
    Future<T> Function(String path) action,
  ) async {
    final selectedPath = selected.path;
    if (selectedPath != null && selectedPath.isNotEmpty) {
      return action(selectedPath);
    }
    final stream = selected.readStream;
    if (stream == null) return null;
    final maxBytes = _backupService.maximumArchiveBytes;
    if (selected.size > maxBytes) {
      throw const FormatException('backup_too_large');
    }
    return _withProtectedTemporaryFile('selected-backup.dabackup', (
      temporary,
    ) async {
      final sink = temporary.openWrite();
      var writtenBytes = 0;
      try {
        await for (final chunk in stream) {
          writtenBytes += chunk.length;
          if (writtenBytes > maxBytes) {
            throw const FormatException('backup_too_large');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return await action(temporary.path);
    });
  }

  Future<BackupInspectionResult> inspectBackupPath(String sourcePath) =>
      _backupService.inspectBackup(sourcePath);

  Future<BackupValidationResult> stageRestorePath(String sourcePath) =>
      _backupService.inspectAndStageRestore(sourcePath);

  Future<BackupMergeResult> mergeBackupPath(
    String sourcePath, {
    required CrossPlatformSyncService syncService,
    bool syncAccountAndPortableSettings = false,
  }) => _backupService.mergeBackup(
    sourcePath,
    syncService: syncService,
    syncAccountAndPortableSettings: syncAccountAndPortableSettings,
  );

  Future<BackupInspectionResult?> inspectBackupFile(PlatformFile selected) =>
      withBackupFilePath(selected, inspectBackupPath);

  Future<BackupValidationResult?> stageBackupFile(PlatformFile selected) =>
      withBackupFilePath(selected, stageRestorePath);

  Future<BackupValidationResult?> pickAndStageBackup({
    required String dialogTitle,
  }) async {
    final selected = await pickBackupFile(dialogTitle: dialogTitle);
    if (selected == null) return null;
    return stageBackupFile(selected);
  }

  static Future<T> _withProtectedTemporaryFile<T>(
    String name,
    Future<T> Function(File file) operation,
  ) async {
    final lease = await AppCacheService.protectTemporaryDirectories({
      'exports',
    });
    File? temporary;
    try {
      temporary = await _temporaryExportFile(name);
      return await operation(temporary);
    } finally {
      try {
        if (temporary != null) await _deleteTemporaryExportFile(temporary);
      } finally {
        lease.release();
      }
    }
  }

  static Future<File> _temporaryExportFile(String name) async {
    final directory = await getTemporaryDirectory();
    final exportDirectory = Directory(path.join(directory.path, 'exports'));
    await exportDirectory.create(recursive: true);
    return File(path.join(exportDirectory.path, name));
  }

  static Future<String?> _saveGeneratedExportFile({
    required File source,
    required String dialogTitle,
    required List<String> allowedExtensions,
    required String mimeType,
    required FileCachePlatformGateway fileCacheGateway,
    required bool Function() isAndroid,
  }) async {
    if (isAndroid()) {
      return fileCacheGateway.exportFile(
        sourcePath: source.path,
        fileName: path.basename(source.path),
        mimeType: mimeType,
      );
    }
    final savedPath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: path.basename(source.path),
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      lockParentWindow: true,
    );
    if (savedPath == null) return null;
    final destination = File(savedPath).absolute;
    // Commit on the destination volume after the entire export is written.
    final staging = await destination.parent.createTemp('.doujin-export-');
    final stagedFile = File(path.join(staging.path, 'export.part'));
    try {
      final sink = stagedFile.openWrite();
      sink.done.ignore();
      try {
        await sink.addStream(source.openRead());
      } finally {
        await sink.close();
      }
      await stagedFile.rename(destination.path);
    } finally {
      await _deleteTemporaryExportFile(stagedFile);
    }
    return savedPath;
  }

  static Future<void> _deleteTemporaryExportFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
      final parent = file.parent;
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'temporary_export_cleanup_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static String _exportTimestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
