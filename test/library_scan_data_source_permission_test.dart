import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/library/application/library_scan_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fileCacheChannel = MethodChannel(FileCacheChannel.name);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, null);
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

  test(
    'legacy path resolves only through an existing persisted tree grant',
    () async {
      const source = '/storage/emulated/0/Music';
      const grant =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, (call) async {
            expect(call.method, FileCacheMethod.findPersistedTreeGrantForPath);
            expect(call.arguments, <String, Object?>{'path': source});
            return <String, Object?>{'ok': true, 'value': grant};
          });

      final resolved = await PlatformLibraryScanDataSource(
        isAndroid: () => true,
      ).findPersistedTreeGrantForPath(source);

      expect(resolved, grant);
    },
  );

  test('SAF source never attempts a filesystem grant lookup', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          calls++;
          return <String, Object?>{'ok': true, 'value': null};
        });

    final resolved = await PlatformLibraryScanDataSource(
      isAndroid: () => true,
    ).findPersistedTreeGrantForPath('content://com.example/tree/music');

    expect(resolved, isNull);
    expect(calls, 0);
  });
}
