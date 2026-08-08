import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/logging/app_log_service.dart';
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

  Future<String?> exportDiagnostics({required String dialogTitle}) async {
    final temporary = await _temporaryFile(
      'NamelessAudio-diagnostic-${_timestamp()}.zip',
    );
    try {
      final report = await _diagnosticService.exportReport(temporary.path);
      return await _saveGeneratedFile(
        source: report,
        dialogTitle: dialogTitle,
        allowedExtensions: const <String>['zip'],
        mimeType: 'application/zip',
      );
    } finally {
      await _deleteTemporaryFile(temporary);
    }
  }

  Future<String?> exportBackup({required String dialogTitle}) async {
    final temporary = await _temporaryFile(
      'NamelessAudio-backup-${_timestamp()}.nabackup',
    );
    try {
      final backup = await _backupService.exportBackup(temporary.path);
      return await _saveGeneratedFile(
        source: backup,
        dialogTitle: dialogTitle,
        allowedExtensions: const <String>['nabackup'],
        mimeType: 'application/zip',
      );
    } finally {
      await _deleteTemporaryFile(temporary);
    }
  }

  Future<BackupValidationResult?> pickAndStageBackup({
    required String dialogTitle,
  }) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: const <String>['nabackup'],
      withReadStream: true,
      lockParentWindow: true,
    );
    final selected = result?.files.singleOrNull;
    if (selected == null) return null;
    final selectedPath = selected.path;
    if (selectedPath != null && selectedPath.isNotEmpty) {
      return _backupService.inspectAndStageRestore(selectedPath);
    }
    final stream = selected.readStream;
    if (stream == null) return null;
    final temporary = await _temporaryFile('selected-backup.nabackup');
    try {
      await stream.pipe(temporary.openWrite());
      return _backupService.inspectAndStageRestore(temporary.path);
    } finally {
      await _deleteTemporaryFile(temporary);
    }
  }

  Future<File> _temporaryFile(String name) async {
    final directory = await getTemporaryDirectory();
    final exportDirectory = Directory(path.join(directory.path, 'exports'));
    await exportDirectory.create(recursive: true);
    return File(path.join(exportDirectory.path, name));
  }

  Future<String?> _saveGeneratedFile({
    required File source,
    required String dialogTitle,
    required List<String> allowedExtensions,
    required String mimeType,
  }) async {
    if (_isAndroid()) {
      return _fileCacheGateway.exportFile(
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
    await source.openRead().pipe(File(savedPath).openWrite());
    return savedPath;
  }

  Future<void> _deleteTemporaryFile(File file) async {
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

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
