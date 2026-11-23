import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/logging/app_log_service.dart';
import 'package:doujin_audio/features/data_support/application/diagnostic_report_service.dart';
import 'package:doujin_audio/features/settings/application/permission_status_service.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';

void main() {
  test('exports a local diagnostic report with sanitized logs', () async {
    final directory = await Directory.systemTemp.createTemp('diagnostic_test_');
    addTearDown(() => directory.delete(recursive: true));
    final logFile = File('${directory.path}/doujin_audio.log');
    await logFile.writeAsString(
      'Bearer secret-token https://example.test/path?token=secret',
    );
    final output = File('${directory.path}/diagnostic.zip');
    final service = DiagnosticReportService(
      permissionStatusService: PermissionStatusService(
        isAndroidOverride: false,
      ),
      appVersionProvider: () async =>
          const AppVersionInfo(versionName: '1.2.3', buildNumber: 4),
      cacheBytesProvider: () async => 42,
      logFilesProvider: () async => <File>[logFile],
      backgroundRunDiagnosticsProvider: () async =>
          const BackgroundRunDiagnostics(
            manufacturer: 'vivo',
            batteryOptimizationExempt: true,
            vendorBackgroundSettingsAvailable: true,
            cleanerForceStopDetected: true,
            lastExitDescription: 'single-cleaner',
          ),
      platformName: 'test',
      platformVersion: 'test-version',
    );

    await service.exportReport(output.path);

    final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
    final report =
        jsonDecode(
              utf8.decode(
                archive.findFile('diagnostic.json')!.content as List<int>,
              ),
            )
            as Map<String, dynamic>;
    final log = utf8.decode(
      archive.findFile('logs/doujin_audio.log')!.content as List<int>,
    );
    expect(report['appVersion'], '1.2.3+4');
    expect(report['applicationCacheBytes'], 42);
    expect(report['permissions'], containsPair('exactAlarmsAllowed', true));
    expect(
      (report['backgroundRun']
          as Map<String, dynamic>)['cleanerForceStopDetected'],
      isTrue,
    );
    expect(report, isNot(contains('mediaFiles')));
    expect(log, contains('Bearer [REDACTED]'));
    expect(log, isNot(contains('token=secret')));
  });

  test(
    'flushes active logs, decodes malformed UTF-8, and records unreadable log errors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'diagnostic_resilience_',
      );
      addTearDown(() async {
        await AppLogService.resetForTest();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      await AppLogService.initialize(
        supportDirectoryProvider: () async => directory,
      );
      AppLogService.info('fresh_unflushed_entry');
      final activeLog = File('${directory.path}/logs/doujin_audio.log');

      final malformedLog = File('${directory.path}/malformed.log');
      await malformedLog.writeAsBytes(<int>[
        ...utf8.encode('prefix '),
        0xFF,
        0xFE,
        ...utf8.encode(' token=secret-value'),
      ]);

      final unreadableLog = File('${directory.path}/locked.log');
      await unreadableLog.writeAsString('cannot read');

      final output = File('${directory.path}/diagnostic.zip');
      final service = DiagnosticReportService(
        permissionStatusService: PermissionStatusService(
          isAndroidOverride: false,
        ),
        appVersionProvider: () async =>
            const AppVersionInfo(versionName: '1.2.3', buildNumber: 4),
        cacheBytesProvider: () async => 0,
        logFilesProvider: () async => <File>[
          activeLog,
          malformedLog,
          unreadableLog,
        ],
        backgroundRunDiagnosticsProvider: () async => null,
        platformName: 'test',
        platformVersion: 'test-version',
      );

      await IOOverrides.runWithIOOverrides(
        () => service.exportReport(output.path),
        _FailingLogReadIO(blockedPath: unreadableLog.path),
      );

      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      final report =
          jsonDecode(
                utf8.decode(
                  archive.findFile('diagnostic.json')!.content as List<int>,
                ),
              )
              as Map<String, dynamic>;
      final flushedContent = utf8.decode(
        archive.findFile('logs/doujin_audio.log')!.content as List<int>,
      );
      final malformedContent = utf8.decode(
        archive.findFile('logs/malformed.log')!.content as List<int>,
      );

      expect(flushedContent, contains('fresh_unflushed_entry'));
      expect(malformedContent, contains('prefix '));
      expect(malformedContent, contains('token=[REDACTED]'));
      expect(malformedContent, isNot(contains('secret-value')));
      expect(archive.findFile('logs/locked.log'), isNull);
      final errors = report['logReadErrors'] as List<dynamic>;
      expect(errors, hasLength(1));
      expect(
        (errors.single as Map<String, dynamic>)['file'],
        'locked.log',
      );
    },
  );
}

final class _FailingLogReadIO extends IOOverrides {
  _FailingLogReadIO({required this.blockedPath});

  final String blockedPath;

  @override
  File createFile(String path) =>
      _FailingLogReadFile(super.createFile(path), blockedPath: blockedPath);
}

final class _FailingLogReadFile implements File {
  _FailingLogReadFile(this._delegate, {required this.blockedPath});

  final File _delegate;
  final String blockedPath;

  @override
  String get path => _delegate.path;

  @override
  Uri get uri => _delegate.uri;

  @override
  Directory get parent => _delegate.parent;

  @override
  Future<bool> exists() => _delegate.exists();

  @override
  Future<Uint8List> readAsBytes() {
    if (_delegate.path == blockedPath) {
      return Future<Uint8List>.error(
        FileSystemException('Access denied', _delegate.path),
      );
    }
    return _delegate.readAsBytes();
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => _delegate.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
