import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/file_cache_platform_gateway.dart';
import 'package:nameless_audio/services/platform_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/file_cache_gateway');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FileCachePlatformGateway gateway;
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    gateway = FileCachePlatformGateway(channel: channel, isAndroid: () => true);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('typed document operations preserve the platform payload', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(
      await gateway.copyFileToFolder(
        sourcePath: '/tmp/source.mp3',
        folder: 'content://library',
        relativePath: 'work/source.mp3',
        overwrite: true,
      ),
      isTrue,
    );

    expect(calls.single.method, FileCacheMethod.copyFileToFolder);
    expect(calls.single.arguments, <String, Object?>{
      'sourcePath': '/tmp/source.mp3',
      'folder': 'content://library',
      'relativePath': 'work/source.mp3',
      'overwrite': true,
    });
  });

  test('typed media helpers parse native values', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        FileCacheMethod.discoverRootImages => <String>[
          ' content://cover-a ',
          '',
          'content://cover-b',
        ],
        FileCacheMethod.resolveTrackSubtitle => <String, Object?>{
          'sourcePath': 'content://subtitle',
          'text': 'subtitle',
          'extension': '.srt',
        },
        FileCacheMethod.resolveMediaDuration => 123456,
        _ => null,
      };
    });

    expect(
      await gateway.discoverRootImages(
        path: 'content://track',
        rootFolder: 'content://folder',
      ),
      <String>['content://cover-a', 'content://cover-b'],
    );
    expect(
      await gateway.resolveTrackSubtitle(path: 'content://track'),
      containsPair('extension', '.srt'),
    );
    expect(
      await gateway.resolveMediaDuration('content://track'),
      const Duration(milliseconds: 123456),
    );
  });

  test('typed backup and byte-write helpers preserve values', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        FileCacheMethod.writeAudioDetailBackup => true,
        FileCacheMethod.writeFileBytesToFolder => 'content://saved',
        _ => null,
      };
    });

    expect(
      await gateway.writeAudioDetailBackup(
        folder: 'content://folder',
        json: '{"ok":true}',
      ),
      isTrue,
    );
    expect(
      await gateway.writeFileBytesToFolder(
        folder: 'content://folder',
        name: 'cover.jpg',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        mimeType: 'image/jpeg',
      ),
      'content://saved',
    );
    expect(calls.map((call) => call.method), <String>[
      FileCacheMethod.writeAudioDetailBackup,
      FileCacheMethod.writeFileBytesToFolder,
    ]);
  });

  test(
    'non-Android scan and listing report unsupported without calls',
    () async {
      final nonAndroidGateway = FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => false,
      );

      expect(
        (await nonAndroidGateway.scanFolder('/music')).notSupported,
        isTrue,
      );
      expect(await nonAndroidGateway.listChildFolders('/music'), isNull);
      expect(
        await nonAndroidGateway.resolveMediaDuration('/music/track.flac'),
        isNull,
      );
    },
  );
}
