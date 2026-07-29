import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/library/application/library_scan_data_source.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
  const fileCacheChannel = MethodChannel(FileCacheChannel.name);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, null);
  });

  test(
    'legacy storage grant satisfies Android media read permission',
    () async {
      _mockPermissionRequests(channel, <int, int>{
        Permission.manageExternalStorage.value: PermissionStatus.denied.index,
        Permission.storage.value: PermissionStatus.granted.index,
        Permission.audio.value: PermissionStatus.denied.index,
        Permission.videos.value: PermissionStatus.denied.index,
      });

      expect(
        await PlatformLibraryScanDataSource(
          isAndroid: () => true,
        ).ensureReadPermissionForSources(const <String>['/music']),
        isTrue,
      );
    },
  );

  test('granular Android permission requires both audio and videos', () async {
    Future<bool> requestWith({required bool audio, required bool videos}) {
      _mockPermissionRequests(channel, <int, int>{
        Permission.manageExternalStorage.value: PermissionStatus.denied.index,
        Permission.storage.value: PermissionStatus.denied.index,
        Permission.audio.value:
            (audio ? PermissionStatus.granted : PermissionStatus.denied).index,
        Permission.videos.value:
            (videos ? PermissionStatus.granted : PermissionStatus.denied).index,
      });
      return PlatformLibraryScanDataSource(
        isAndroid: () => true,
      ).ensureReadPermissionForSources(const <String>['/music']);
    }

    expect(await requestWith(audio: true, videos: true), isTrue);
    expect(await requestWith(audio: true, videos: false), isFalse);
    expect(await requestWith(audio: false, videos: true), isFalse);
  });

  test('SAF-only sources do not request Android media permissions', () async {
    var requestCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          requestCount++;
          return <int, int>{};
        });

    expect(
      await PlatformLibraryScanDataSource(
        isAndroid: () => true,
      ).ensureReadPermissionForSources(const <String>[
        'content://com.example/tree/music',
      ]),
      isTrue,
    );
    expect(requestCount, 0);
  });

  test('SAF audio file accessibility uses the native document check', () async {
    const source =
        'content://com.android.externalstorage.documents/document/'
        'primary%3AMusic%2Ftrack.mp3';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          expect(call.method, FileCacheMethod.documentPathExists);
          expect(call.arguments, <String, Object?>{'path': source});
          return <String, Object?>{'ok': true, 'value': true};
        });

    final exists = await PlatformLibraryScanDataSource(
      isAndroid: () => true,
    ).sourceExists(source);

    expect(exists, isTrue);
  });

  test('external-storage URI resolves to a durable filesystem path', () async {
    const source =
        'content://com.android.externalstorage.documents/document/'
        'primary%3AMusic%2Ftrack.mp3';
    const resolved = '/storage/emulated/0/Music/track.mp3';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          expect(call.method, FileCacheMethod.resolveDocumentFileSystemPath);
          expect(call.arguments, <String, Object?>{'path': source});
          return <String, Object?>{'ok': true, 'value': resolved};
        });

    final path = await PlatformLibraryScanDataSource(
      isAndroid: () => true,
    ).resolveRestorablePath(source);

    expect(path, resolved);
  });
}

void _mockPermissionRequests(MethodChannel channel, Map<int, int> statuses) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestPermissions');
        final requested = (call.arguments as List<Object?>).cast<int>();
        return <int, int>{
          for (final permission in requested)
            permission: statuses[permission] ?? PermissionStatus.denied.index,
        };
      });
}
