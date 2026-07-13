import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;
  late HttpServer server;
  late List<int> payload;
  const assetName = 'NamelessAudio-android-arm64-test.apk';

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
      tagName: '1.0.1',
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

  test('concurrent callers share one update download', () async {
    var assetRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/checksum') {
        request.response.write('${sha256.convert(payload)}  $assetName');
      } else {
        assetRequests++;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        request.response.add(payload);
      }
      await request.response.close();
    });

    final first = AppUpdateService.downloadUpdate(
      info(checksumPath: 'checksum'),
      onProgress: (_) {},
    );
    final second = AppUpdateService.downloadUpdate(
      info(checksumPath: 'checksum'),
      onProgress: (_) {},
    );
    final files = await Future.wait(<Future<File>>[first, second]);

    expect(assetRequests, 1);
    expect(files.first.path, files.last.path);
    expect(await files.first.readAsBytes(), payload);
  });

  test('refuses update without checksum asset', () async {
    await expectLater(
      AppUpdateService.downloadUpdate(info(), onProgress: (_) {}),
      throwsFormatException,
    );
    final updatesDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}updates',
    );
    expect(
      updatesDir.existsSync()
          ? updatesDir.listSync().whereType<File>()
          : const Iterable<File>.empty(),
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

  test('stable channel selects newer stable releases', () {
    final selected = AppUpdateService.selectCompatibleReleaseForTesting(
      <Map<String, dynamic>>[
        {'tag_name': 'v0.12.4', 'draft': false, 'prerelease': false},
        {'tag_name': 'v0.13.0-rc.1', 'draft': false, 'prerelease': true},
        {'tag_name': 'v0.13.0', 'draft': false, 'prerelease': false},
      ],
      const AppVersionInfo(versionName: '0.12.4', buildNumber: 1204),
    );

    expect(selected?['tag_name'], 'v0.13.0');
  });

  test('stable channel ignores prereleases', () {
    final selected = AppUpdateService.selectCompatibleReleaseForTesting(
      <Map<String, dynamic>>[
        {'tag_name': 'v0.13.1-rc.1', 'draft': false, 'prerelease': true},
        {'tag_name': 'v0.13.0', 'draft': false, 'prerelease': false},
      ],
      const AppVersionInfo(versionName: '0.12.4', buildNumber: 1204),
    );

    expect(selected?['tag_name'], 'v0.13.0');
  });

  test('Android updater selects only the universal APK', () {
    final selected = AppUpdateService.selectApkAssetForTesting(
      <Map<String, dynamic>>[
        {'name': 'NamelessAudio-android-arm64-v0.13.0.apk'},
        {'name': 'NamelessAudio-android-armv7-v0.13.0.apk'},
        {'name': 'NamelessAudio-android-x64-v0.13.0.apk'},
        {'name': 'NamelessAudio-android-universal-v0.13.0.apk'},
      ],
    );

    expect(selected?['name'], 'NamelessAudio-android-universal-v0.13.0.apk');
    expect(
      AppUpdateService.selectApkAssetForTesting(<Map<String, dynamic>>[
        {'name': 'NamelessAudio-android-arm64-v0.13.0.apk'},
        {'name': 'NamelessAudio-android-armv7-v0.13.0.apk'},
      ]),
      isNull,
    );
  });

  test('Windows updater selects the x64 ZIP from mixed release assets', () {
    final selected = AppUpdateService.selectWindowsZipAssetForTesting(
      <Map<String, dynamic>>[
        {'name': 'NamelessAudio-android-universal-v0.13.0.apk'},
        {'name': 'NamelessAudio-windows-x64-v0.13.0.zip'},
      ],
    );

    expect(selected?['name'], 'NamelessAudio-windows-x64-v0.13.0.zip');
  });

  test('update info reports missing asset and missing checksum states', () {
    const current = AppVersionInfo(versionName: '0.12.4', buildNumber: 1204);
    final noAsset = AppUpdateService.buildUpdateInfoForTesting(
      currentVersion: current,
      tagName: 'v0.13.0',
      releaseUrl: 'https://example.test/release',
      assets: const <Map<String, dynamic>>[],
    );
    expect(noAsset.status, AppUpdateStatus.missingAsset);
    expect(noAsset.isUpdateAvailable, isFalse);

    final platformAssetName = Platform.isWindows
        ? 'NamelessAudio-windows-x64-v0.13.0.zip'
        : 'NamelessAudio-android-universal-v0.13.0.apk';
    final missingChecksum = AppUpdateService.buildUpdateInfoForTesting(
      currentVersion: current,
      tagName: 'v0.13.0',
      releaseUrl: 'https://example.test/release',
      assets: <Map<String, dynamic>>[
        {
          'name': platformAssetName,
          'browser_download_url': 'https://example.test/$platformAssetName',
        },
      ],
    );
    expect(missingChecksum.status, AppUpdateStatus.missingChecksum);
    expect(missingChecksum.isUpdateAvailable, isFalse);

    final ready = AppUpdateService.buildUpdateInfoForTesting(
      currentVersion: current,
      tagName: 'v0.13.0',
      releaseUrl: 'https://example.test/release',
      assets: <Map<String, dynamic>>[
        {
          'name': platformAssetName,
          'browser_download_url': 'https://example.test/$platformAssetName',
        },
        {
          'name': '$platformAssetName.sha256',
          'browser_download_url':
              'https://example.test/$platformAssetName.sha256',
        },
      ],
    );
    expect(ready.status, AppUpdateStatus.updateAvailable);
    expect(ready.canDownload, isTrue);
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
    expect(
      script,
      contains(
        "Start-ElevatedUpdater\n"
        "      Set-Content -LiteralPath \$ReadyPath -Value 'ready'",
      ),
    );
    expect(script, contains(r'Start-Process -FilePath $targetExePath'));
  });

  test(
    'Windows updater extracts, overwrites, and marks itself ready',
    () async {
      final installDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}install',
      )..createSync();
      final exe = File(
        '${installDir.path}${Platform.pathSeparator}legacy_audio.exe',
      )..writeAsStringSync('old');
      final targetExe = File(
        '${installDir.path}${Platform.pathSeparator}nameless_audio.exe',
      );
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
      expect(await targetExe.length(), payloadBytes.length);
      expect(exe.existsSync(), isFalse);
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
