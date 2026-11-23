import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';

import '../../../core/cache/app_cache_service.dart';
import '../../../core/persistence/app_database.dart';
import '../../../core/logging/app_log_service.dart';
import '../../settings/application/app_update_service.dart';
import '../../settings/application/permission_status_service.dart';
import '../../../core/platform/power_platform_service.dart';

class DiagnosticReportService {
  DiagnosticReportService({
    PermissionStatusService? permissionStatusService,
    Future<AppVersionInfo> Function()? appVersionProvider,
    AppUpdateService? appUpdateService,
    Future<int> Function()? cacheBytesProvider,
    Future<List<File>> Function()? logFilesProvider,
    Future<BackgroundRunDiagnostics?> Function()?
    backgroundRunDiagnosticsProvider,
    String? platformName,
    String? platformVersion,
  }) : _permissionStatusService =
           permissionStatusService ??
           PermissionStatusService(appUpdateService: appUpdateService),
       _appVersionProvider =
           appVersionProvider ??
           (appUpdateService ?? AppUpdateService()).currentAppVersion,
       _cacheBytesProvider =
           cacheBytesProvider ?? AppCacheService.estimateCacheBytes,
       _logFilesProvider = logFilesProvider ?? _defaultLogFiles,
       _backgroundRunDiagnosticsProvider =
           backgroundRunDiagnosticsProvider ??
           PowerPlatformService().getBackgroundRunDiagnostics,
       _platformName = platformName ?? Platform.operatingSystem,
       _platformVersion = platformVersion ?? Platform.operatingSystemVersion;

  final PermissionStatusService _permissionStatusService;
  final Future<AppVersionInfo> Function() _appVersionProvider;
  final Future<int> Function() _cacheBytesProvider;
  final Future<List<File>> Function() _logFilesProvider;
  final Future<BackgroundRunDiagnostics?> Function()
  _backgroundRunDiagnosticsProvider;
  final String _platformName;
  final String _platformVersion;

  Future<File> exportReport(String outputPath) async {
    final version = await _appVersionProvider();
    final (permissions, exactAlarmsAllowed) = await (
      _permissionStatusService.load(),
      _permissionStatusService.isGranted(PermissionCapability.exactAlarms),
    ).wait;
    final cacheBytes = await _cacheBytesProvider();
    final backgroundRunDiagnostics = await _backgroundRunDiagnosticsProvider();
    final report = <String, Object?>{
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': '${version.versionName}+${version.buildNumber}',
      'platform': _platformName,
      'platformVersion': _platformVersion,
      'databaseSchemaVersion': AppDatabase.schemaVersion,
      'applicationCacheBytes': cacheBytes,
      'permissions': {
        ...permissions.toJson(),
        'exactAlarmsAllowed': exactAlarmsAllowed,
      },
      if (backgroundRunDiagnostics != null)
        'backgroundRun': backgroundRunDiagnostics.toJson(),
      'privacy':
          'Generated locally. Credentials, media files, and URL query parameters are excluded.',
    };
    await AppLogService.flush();
    final logPaths = [for (final file in await _logFilesProvider()) file.path];
    await _writeArchive(outputPath, report, logPaths);
    return File(outputPath);
  }

  static Future<void> _writeArchive(
    String outputPath,
    Map<String, Object?> report,
    List<String> logPaths,
  ) => IOOverrides.current == null
      ? Isolate.run(() => _writeArchiveImpl(outputPath, report, logPaths))
      : _writeArchiveImpl(outputPath, report, logPaths);

  static Future<void> _writeArchiveImpl(
    String outputPath,
    Map<String, Object?> report,
    List<String> logPaths,
  ) async {
    final archive = Archive();
    final logReadErrors = <Map<String, String>>[];
    for (final logPath in logPaths) {
      final logFile = File(logPath);
      final nonEmptySegments = logFile.uri.pathSegments.where(
        (segment) => segment.isNotEmpty,
      );
      final fileName = nonEmptySegments.isNotEmpty
          ? nonEmptySegments.last
          : logPath;
      try {
        if (!await logFile.exists()) continue;
        final rawBytes = await logFile.readAsBytes();
        final sanitized = AppLogService.sanitize(
          utf8.decode(rawBytes, allowMalformed: true),
        );
        final bytes = utf8.encode(sanitized);
        archive.addFile(
          ArchiveFile('logs/$fileName', bytes.length, bytes),
        );
      } on Object catch (error) {
        logReadErrors.add(<String, String>{
          'file': fileName,
          'error': AppLogService.sanitize(error.toString()),
        });
      }
    }

    final finalReport = <String, Object?>{
      ...report,
      if (logReadErrors.isNotEmpty) 'logReadErrors': logReadErrors,
    };
    final reportBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(finalReport),
    );
    archive.addFile(
      ArchiveFile('diagnostic.json', reportBytes.length, reportBytes),
    );

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(ZipEncoder().encode(archive), flush: true);
  }

  static Future<List<File>> _defaultLogFiles() async {
    final directoryPath = AppLogService.logDirectoryPath;
    if (directoryPath == null) return const <File>[];
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return const <File>[];
    return directory
        .list(followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
  }
}
