import '../../../core/platform/app_platform.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import 'data_support_file_service.dart';
import 'diagnostic_report_service.dart';

class DiagnosticReportExporter {
  DiagnosticReportExporter({
    DiagnosticReportService? reportService,
    FileCachePlatformGateway? fileCacheGateway,
    bool Function()? isAndroid,
  }) : _reportService = reportService ?? DiagnosticReportService(),
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _isAndroid = isAndroid ?? (() => AppPlatform.isAndroid);

  final DiagnosticReportService _reportService;
  final FileCachePlatformGateway _fileCacheGateway;
  final bool Function() _isAndroid;

  Future<String?> export({required String dialogTitle}) =>
      DataSupportFileService.exportDiagnosticReport(
        reportService: _reportService,
        fileCacheGateway: _fileCacheGateway,
        isAndroid: _isAndroid,
        dialogTitle: dialogTitle,
      );
}
