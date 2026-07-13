import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/diagnostic_report_service.dart';
import 'package:nameless_audio/services/permission_status_service.dart';
import 'package:nameless_audio/services/app_update_service.dart';
import 'package:nameless_audio/services/power_platform_service.dart';

void main() {
  test('exports a local diagnostic report with sanitized logs', () async {
    final directory = await Directory.systemTemp.createTemp('diagnostic_test_');
    addTearDown(() => directory.delete(recursive: true));
    final logFile = File('${directory.path}/nameless_audio.log');
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
            recentExits: <Map<String, Object?>>[
              <String, Object?>{'reasonName': 'user_requested'},
            ],
            nativePlayback: <String, Object?>{'foregroundStarted': true},
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
      archive.findFile('logs/nameless_audio.log')!.content as List<int>,
    );
    expect(report['appVersion'], '1.2.3+4');
    expect(report['dartVisibleCacheBytes'], 42);
    expect(
      (report['backgroundRun']
          as Map<String, dynamic>)['cleanerForceStopDetected'],
      isTrue,
    );
    expect(
      ((report['backgroundRun'] as Map<String, dynamic>)['nativePlayback']
          as Map<String, dynamic>)['foregroundStarted'],
      isTrue,
    );
    expect(report, isNot(contains('mediaFiles')));
    expect(log, contains('Bearer [REDACTED]'));
    expect(log, isNot(contains('token=secret')));
  });
}
