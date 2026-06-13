import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'app_cache_service.dart';
import 'app_database.dart';
import 'app_log_service.dart';
import 'app_update_service.dart';
import 'permission_status_service.dart';

class DiagnosticReportService {
  DiagnosticReportService({
    PermissionStatusService? permissionStatusService,
    Future<AppVersionInfo> Function()? appVersionProvider,
    Future<int> Function()? cacheBytesProvider,
    Future<List<File>> Function()? logFilesProvider,
    String? platformName,
    String? platformVersion,
  }) : _permissionStatusService =
           permissionStatusService ?? PermissionStatusService(),
       _appVersionProvider =
           appVersionProvider ?? AppUpdateService.currentAppVersion,
       _cacheBytesProvider =
           cacheBytesProvider ?? AppCacheService.estimateDartCacheBytes,
       _logFilesProvider = logFilesProvider ?? _defaultLogFiles,
       _platformName = platformName ?? Platform.operatingSystem,
       _platformVersion = platformVersion ?? Platform.operatingSystemVersion;

  final PermissionStatusService _permissionStatusService;
  final Future<AppVersionInfo> Function() _appVersionProvider;
  final Future<int> Function() _cacheBytesProvider;
  final Future<List<File>> Function() _logFilesProvider;
  final String _platformName;
  final String _platformVersion;

  Future<File> exportReport(String outputPath) async {
    final version = await _appVersionProvider();
    final permissions = await _permissionStatusService.load();
    final cacheBytes = await _cacheBytesProvider();
    final report = <String, Object?>{
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': '${version.versionName}+${version.buildNumber}',
      'platform': _platformName,
      'platformVersion': _platformVersion,
      'databaseSchemaVersion': AppDatabase.schemaVersion,
      'dartVisibleCacheBytes': cacheBytes,
      'permissions': permissions.toJson(),
      'privacy':
          'Generated locally. Credentials, media files, and URL query parameters are excluded.',
    };

    final archive = Archive();
    final reportBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    archive.addFile(
      ArchiveFile('diagnostic.json', reportBytes.length, reportBytes),
    );
    for (final logFile in await _logFilesProvider()) {
      if (!await logFile.exists()) continue;
      final sanitized = AppLogService.sanitize(await logFile.readAsString());
      final bytes = utf8.encode(sanitized);
      archive.addFile(
        ArchiveFile(
          'logs/${logFile.uri.pathSegments.last}',
          bytes.length,
          bytes,
        ),
      );
    }

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(ZipEncoder().encode(archive), flush: true);
    return output;
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
