import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_update_service.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;
  late HttpServer server;
  late List<int> payload;
  const assetName = 'NamelessAudio-test.apk';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_update_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') return tempDir.path;
          return null;
        });
    payload = utf8.encode('verified update payload');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await server.close(force: true);
    for (var attempt = 0; attempt < 10 && await tempDir.exists(); attempt++) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  });

  AppUpdateInfo info({String? checksumPath}) {
    final base = 'http://${server.address.host}:${server.port}';
    return AppUpdateInfo(
      currentVersion: const AppVersionInfo(
        versionName: '1.0.0',
        buildNumber: 1,
      ),
      latestVersionName: '1.0.1',
      tagName: 'v1.0.1',
      assetName: assetName,
      assetUrl: '$base/update',
      checksumAssetUrl: checksumPath == null ? null : '$base/$checksumPath',
      releaseUrl: '$base/release',
      isUpdateAvailable: true,
    );
  }

  test('downloads update only after matching SHA-256 verification', () async {
    server.listen((request) async {
      if (request.uri.path == '/checksum') {
        request.response.write('${sha256.convert(payload)}  $assetName');
      } else {
        request.response.add(payload);
      }
      await request.response.close();
    });

    final file = await AppUpdateService.downloadUpdate(
      info(checksumPath: 'checksum'),
      onProgress: (_) {},
    );

    expect(await file.readAsBytes(), payload);
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('refuses update without checksum asset', () async {
    await expectLater(
      AppUpdateService.downloadUpdate(info(), onProgress: (_) {}),
      throwsFormatException,
    );
    expect(
      Directory(
        '${tempDir.path}${Platform.pathSeparator}updates',
      ).listSync().whereType<File>(),
      isEmpty,
    );
  });

  test('deletes partial update when checksum does not match', () async {
    server.listen((request) async {
      if (request.uri.path == '/checksum') {
        request.response.write('${'0' * 64}  $assetName');
      } else {
        request.response.add(payload);
      }
      await request.response.close();
    });

    await expectLater(
      AppUpdateService.downloadUpdate(
        info(checksumPath: 'checksum'),
        onProgress: (_) {},
      ),
      throwsFormatException,
    );
    expect(
      Directory(
        '${tempDir.path}${Platform.pathSeparator}updates',
      ).listSync().whereType<File>(),
      isEmpty,
    );
  });

  test('rejects checksum that names a different asset', () {
    expect(
      () => AppUpdateService.parseExpectedChecksum(
        '${'a' * 64}  another.apk',
        assetName,
      ),
      throwsFormatException,
    );
  });

  test('Windows updater verifies ZIP before requesting app exit', () {
    final script = AppUpdateService.windowsUpdateScriptForTesting;

    expect(
      script,
      contains("Set-Content -LiteralPath \$ReadyPath -Value 'ready'"),
    );
    expect(
      script.indexOf("Set-Content -LiteralPath \$ReadyPath -Value 'ready'"),
      lessThan(script.lastIndexOf('Wait-AppExit')),
    );
    expect(script, contains(r'Start-Process -FilePath $ExePath'));
  });

  test(
    'Windows updater extracts, overwrites, and marks itself ready',
    () async {
      final installDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}install',
      )..createSync();
      final exe = File(
        '${installDir.path}${Platform.pathSeparator}nameless_audio.exe',
      )..writeAsStringSync('old');
      final staleFile = File(
        '${installDir.path}${Platform.pathSeparator}stale.txt',
      )..writeAsStringSync('old file');
      final payloadExe = File(r'C:\Windows\System32\where.exe');
      expect(payloadExe.existsSync(), isTrue);
      final payloadBytes = await payloadExe.readAsBytes();
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'bundle/nameless_audio.exe',
            payloadBytes.length,
            payloadBytes,
          ),
        );
      final zip = File('${tempDir.path}${Platform.pathSeparator}update.zip');
      await zip.writeAsBytes(ZipEncoder().encode(archive), flush: true);
      final script = File(
        '${tempDir.path}${Platform.pathSeparator}updater.ps1',
      );
      await script.writeAsString(
        AppUpdateService.windowsUpdateScriptForTesting,
        flush: true,
      );
      final ready = File('${tempDir.path}${Platform.pathSeparator}ready.txt');

      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        zip.path,
        installDir.path,
        exe.path,
        '2147483647',
        ready.path,
      ]);

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(await ready.readAsString(), contains('ready'));
      expect(await exe.length(), payloadBytes.length);
      expect(staleFile.existsSync(), isFalse);
      expect(
        tempDir.listSync().whereType<Directory>().where(
          (entry) => path.basename(entry.path).startsWith('install.'),
        ),
        isEmpty,
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
