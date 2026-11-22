import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import 'diagnostic_report_service.dart';

class DiagnosticReportExporter {
  DiagnosticReportExporter({
    DiagnosticReportService? reportService,
    FileCachePlatformGateway? fileCacheGateway,
    bool Function()? isAndroid,
  }) : _reportService = reportService ?? DiagnosticReportService(),
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final DiagnosticReportService _reportService;
  final FileCachePlatformGateway _fileCacheGateway;
  final bool Function() _isAndroid;

  Future<String?> export({required String dialogTitle}) async {
    final directory = await getTemporaryDirectory();
    final report = await _reportService.exportReport(
      path.join(directory.path, 'DoujinAudio-diagnostic.zip'),
    );
    try {
      if (_isAndroid()) {
        return await _fileCacheGateway.exportFile(
          sourcePath: report.path,
          fileName: path.basename(report.path),
          mimeType: 'application/zip',
        );
      }
      final savedPath = await FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: path.basename(report.path),
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
        lockParentWindow: true,
      );
      if (savedPath == null) return null;
      final destination = File(savedPath).absolute;
      final staging = await destination.parent.createTemp('.doujin-export-');
      final stagedFile = File(path.join(staging.path, 'export.part'));
      try {
        final sink = stagedFile.openWrite();
        sink.done.ignore();
        try {
          await sink.addStream(report.openRead());
        } finally {
          await sink.close();
        }
        await stagedFile.rename(destination.path);
      } finally {
        await _cleanupTemporaryFile(stagedFile);
      }
      return savedPath;
    } finally {
      try {
        if (await report.exists()) await report.delete();
      } on FileSystemException catch (error, stackTrace) {
        AppLogService.warning(
          'diagnostic_report_cleanup_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> _cleanupTemporaryFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
      final parent = file.parent;
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'diagnostic_report_cleanup_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
