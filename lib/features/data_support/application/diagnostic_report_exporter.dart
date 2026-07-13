import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import 'diagnostic_report_service.dart';

class DiagnosticReportExporter {
  DiagnosticReportExporter({DiagnosticReportService? reportService})
    : _reportService = reportService ?? DiagnosticReportService();

  final DiagnosticReportService _reportService;

  Future<String?> export({required String dialogTitle}) async {
    final directory = await getTemporaryDirectory();
    final report = await _reportService.exportReport(
      path.join(directory.path, 'NamelessAudio-diagnostic.zip'),
    );
    try {
      return FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: path.basename(report.path),
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
        bytes: await report.readAsBytes(),
        lockParentWindow: true,
      );
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
}
