import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const updateChannel = MethodChannel(UpdateChannel.name);
  late Directory tempDir;
  late HttpServer server;
  late List<int> payload;
  late AppUpdateService service;
  const assetName = 'NamelessAudio-android-arm64-test.apk';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_update_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') return tempDir.path;
          return null;
        });
    payload = utf8.encode('verified update payload');
    service = AppUpdateService();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(updateChannel, null);
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

  Map<String, dynamic> githubAsset(String name, {String? url}) =>
      <String, dynamic>{
        'name': name,
        'browser_download_url':
            url ?? 'https://github.com/example/releases/download/v0.13.0/$name',
      };

  Map<String, dynamic> githubRelease(
    String tagName, {
    bool draft = false,
    bool prerelease = false,
    List<Map<String, dynamic>> assets = const <Map<String, dynamic>>[],
  }) => <String, dynamic>{
    'tag_name': tagName,
    'name': 'Nameless Audio $tagName',
    'html_url': 'https://github.com/example/releases/tag/$tagName',
    'published_at': '2026-07-14T00:00:00Z',
    'draft': draft,
    'prerelease': prerelease,
    'assets': assets,
  };

  test('downloads update only after matching SHA-256 verification', () async {
    server.listen((request) async {
      if (request.uri.path == '/checksum') {
        request.response.write('${sha256.convert(payload)}  $assetName');
      } else {
        request.response.add(payload);
      }
      await request.response.close();
    });

    final file = await service.downloadUpdate(
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

    final first = service.downloadUpdate(
      info(checksumPath: 'checksum'),
      onProgress: (_) {},
    );
    final second = service.downloadUpdate(
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
      service.downloadUpdate(info(), onProgress: (_) {}),
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
      service.downloadUpdate(
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
        githubRelease('v0.12.4'),
        githubRelease('v0.13.0-rc.1', prerelease: true),
        githubRelease('v0.13.0'),
      ],
      const AppVersionInfo(versionName: '0.12.4', buildNumber: 1204),
    );

    expect(selected?['tag_name'], 'v0.13.0');
  });

  test('stable channel ignores prereleases', () {
    final selected = AppUpdateService.selectCompatibleReleaseForTesting(
      <Map<String, dynamic>>[
        githubRelease('v0.13.1-rc.1', prerelease: true),
        githubRelease('v0.13.0'),
      ],
      const AppVersionInfo(versionName: '0.12.4', buildNumber: 1204),
    );

    expect(selected?['tag_name'], 'v0.13.0');
  });

  test('release parser ignores malformed rows before version selection', () {
    final selected = AppUpdateService.selectCompatibleReleaseForTesting(
      <Map<String, dynamic>>[
        githubRelease('v0.13.4')..remove('assets'),
        <String, dynamic>{...githubRelease('v0.13.3'), 'draft': 'false'},
        <String, dynamic>{...githubRelease('v0.13.2'), 'html_url': 'not-a-url'},
        <String, dynamic>{
          ...githubRelease('v0.13.1'),
          'published_at': 'not-a-date',
        },
        githubRelease('v0.13.0'),
      ],
      const AppVersionInfo(versionName: '0.12.4', buildNumber: 1204),
    );

    expect(selected?['tag_name'], 'v0.13.0');
  });

  test('release selection ignores drafts and sorts valid versions', () {
    final selected = AppUpdateService.selectCompatibleReleaseForTesting(
      <Map<String, dynamic>>[
        githubRelease('v0.13.1', draft: true),
        githubRelease('v0.13.0'),
        githubRelease('v0.12.9'),
      ],
      const AppVersionInfo(versionName: '0.12.4', buildNumber: 1204),
    );

    expect(selected?['tag_name'], 'v0.13.0');
  });

  test('Android updater selects only the universal APK', () {
    final selected =
        AppUpdateService.selectApkAssetForTesting(<Map<String, dynamic>>[
          githubAsset('NamelessAudio-android-arm64-v0.13.0.apk'),
          githubAsset('NamelessAudio-android-armv7-v0.13.0.apk'),
          githubAsset('NamelessAudio-android-x64-v0.13.0.apk'),
          githubAsset('NamelessAudio-android-universal-v0.13.0.apk'),
        ]);

    expect(selected?['name'], 'NamelessAudio-android-universal-v0.13.0.apk');
    expect(
      AppUpdateService.selectApkAssetForTesting(<Map<String, dynamic>>[
        githubAsset('NamelessAudio-android-arm64-v0.13.0.apk'),
        githubAsset('NamelessAudio-android-armv7-v0.13.0.apk'),
      ]),
      isNull,
    );
  });

  test('Windows updater selects the x64 ZIP from mixed release assets', () {
    final selected =
        AppUpdateService.selectWindowsZipAssetForTesting(<Map<String, dynamic>>[
          githubAsset('NamelessAudio-android-universal-v0.13.0.apk'),
          githubAsset('NamelessAudio-windows-x64-v0.13.0.zip'),
        ]);

    expect(selected?['name'], 'NamelessAudio-windows-x64-v0.13.0.zip');
  });

  test('asset selection ignores missing, mistyped, and invalid URLs', () {
    final selected = AppUpdateService.selectApkAssetForTesting(
      <Map<String, dynamic>>[
        {'name': 'NamelessAudio-android-universal-v0.13.2.apk'},
        {'name': 42, 'browser_download_url': 'https://example.test/bad.apk'},
        {
          'name': 'NamelessAudio-android-universal-v0.13.1.apk',
          'browser_download_url': 'file:///tmp/update.apk',
        },
        githubAsset('NamelessAudio-android-universal-v0.13.0.apk'),
      ],
    );

    expect(selected?['name'], 'NamelessAudio-android-universal-v0.13.0.apk');
  });

  test('expanded release HTML produces typed, de-duplicated assets', () {
    final assets = AppUpdateService.parseExpandedReleaseAssetsForTesting('''
      <a href="/example/releases/download/v0.13.0/NamelessAudio-windows-x64-v0.13.0.zip?download=1&amp;source=expanded">zip</a>
      <a href="/example/releases/download/v0.13.0/NamelessAudio-windows-x64-v0.13.0.zip?download=1&amp;source=expanded">duplicate</a>
      <a href="/example/releases/download/v0.13.0/NamelessAudio-windows-x64-v0.13.0.zip.sha256">checksum</a>
      <a href="/example/releases/download/v0.13.0/invalid%zz.zip">invalid encoding</a>
      <a href="/example/not-a-release-asset">ignored</a>
    ''');

    expect(assets, hasLength(2));
    expect(
      assets.map((asset) => asset['name']),
      containsAll(<String>[
        'NamelessAudio-windows-x64-v0.13.0.zip',
        'NamelessAudio-windows-x64-v0.13.0.zip.sha256',
      ]),
    );
    expect(
      assets.first['browser_download_url'],
      contains('download=1&source=expanded'),
    );
  });

  test('API failure falls back through release HTML and expanded assets', () async {
    final origin = Uri.parse('http://${server.address.host}:${server.port}');
    HttpOverrides.global = _RewritingHttpOverrides(origin);
    final requestedPaths = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(updateChannel, (call) async {
          expect(call.method, UpdateMethod.getAppVersion);
          return <String, Object?>{
            'ok': true,
            'value': <String, Object?>{
              'versionName': '0.12.4',
              'buildNumber': 1204,
            },
          };
        });
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      switch (request.uri.path) {
        case '/repos/${AppUpdateService.owner}/${AppUpdateService.repo}/releases':
          request.response.statusCode = HttpStatus.internalServerError;
        case '/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/latest':
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/tag/v0.13.0',
          );
        case '/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/expanded_assets/v0.13.0':
          request.response.write('''
            <a href="/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/download/v0.13.0/NamelessAudio-android-universal-v0.13.0.apk">apk</a>
            <a href="/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/download/v0.13.0/NamelessAudio-android-universal-v0.13.0.apk.sha256">apk checksum</a>
            <a href="/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/download/v0.13.0/NamelessAudio-windows-x64-v0.13.0.zip">zip</a>
            <a href="/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/download/v0.13.0/NamelessAudio-windows-x64-v0.13.0.zip.sha256">zip checksum</a>
          ''');
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final result = await service.checkLatest();

    expect(result.status, AppUpdateStatus.updateAvailable);
    expect(result.latestVersionName, '0.13.0');
    expect(result.canDownload, isTrue);
    expect(
      requestedPaths,
      containsAllInOrder(<String>[
        '/repos/${AppUpdateService.owner}/${AppUpdateService.repo}/releases',
        '/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/latest',
        '/${AppUpdateService.owner}/${AppUpdateService.repo}/releases/expanded_assets/v0.13.0',
      ]),
    );
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

final class _RewritingHttpOverrides extends HttpOverrides {
  _RewritingHttpOverrides(this.origin);

  final Uri origin;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _RewritingHttpClient(super.createHttpClient(context), origin);
  }
}

final class _RewritingHttpClient implements HttpClient {
  _RewritingHttpClient(this._delegate, this._origin);

  final HttpClient _delegate;
  final Uri _origin;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    return _delegate.getUrl(
      _origin.replace(path: url.path, query: url.hasQuery ? url.query : null),
    );
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
