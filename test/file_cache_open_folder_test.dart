import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/file_cache_open_folder');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FileCachePlatformGateway gateway;
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    gateway = FileCachePlatformGateway(
      channel: channel,
      isAndroid: () => false,
      isWindows: () => true,
    );
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final path in <String>[
    r'E:\音频库\作品 名\音声 01.mp3',
    r'E:\音频库\作品 名',
    r'\\server\共享 音频\作品 名\音声.mp3',
  ]) {
    test('Windows preserves the filesystem path: $path', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{'ok': true, 'value': true};
      });

      expect(await gateway.openContainingFolder(path), isTrue);
      expect(calls.single.method, FileCacheMethod.openContainingFolder);
      expect(calls.single.arguments, <String, Object?>{'path': path});
    });
  }

  for (final (isAndroid, isWindows) in <(bool, bool)>[
    (true, false),
    (false, false),
    (true, true),
  ]) {
    test(
      'unsupported platform ($isAndroid, $isWindows) avoids channel',
      () async {
        gateway = FileCachePlatformGateway(
          channel: channel,
          isAndroid: () => isAndroid,
          isWindows: () => isWindows,
        );
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object?>{'ok': true, 'value': true};
        });

        expect(await gateway.openContainingFolder(r'E:\音声.mp3'), isFalse);
        expect(calls, isEmpty);
      },
    );
  }

  for (final response in <Object?>[
    <String, Object?>{'ok': true, 'value': false},
    <String, Object?>{'ok': true, 'value': null},
    <String, Object?>{'ok': true, 'value': 'true'},
    <String, Object?>{'ok': true, 'value': 1},
    <String, Object?>{
      'ok': false,
      'errorCode': 'windows_error',
      'error': 'Denied',
    },
    <String, Object?>{'ok': true},
    true,
    null,
  ]) {
    test(
      'failure or malformed native response is not success: $response',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async => response);

        expect(await gateway.openContainingFolder(r'E:\音声.mp3'), isFalse);
      },
    );
  }

  for (final error in <Exception>[
    PlatformException(code: 'windows_error', message: 'Shell open failed'),
    MissingPluginException(),
  ]) {
    test('channel error is not success: $error', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => throw error);

      expect(await gateway.openContainingFolder(r'E:\音声.mp3'), isFalse);
    });
  }

  for (final path in <String>[
    '',
    'relative.mp3',
    'https://example.com/file',
    'E:\\bad\u0000path',
  ]) {
    test('native invalid_argument is not reported as success: $path', () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'invalid_argument', message: 'path');
      });

      expect(await gateway.openContainingFolder(path), isFalse);
    });
  }
}
