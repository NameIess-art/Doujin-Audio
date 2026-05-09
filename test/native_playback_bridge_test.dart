import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/native_playback_bridge.dart';
import 'package:nameless_audio/services/platform_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativePlaybackChannel.name);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('play decodes success payload into a typed snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, NativePlaybackMethods.play);
          return <String, Object?>{
            'ok': true,
            'value': <String, Object?>{
              'sessionId': 'session-1',
              'playing': true,
              'playWhenReady': true,
              'processingState': 'ready',
              'positionMs': 1500,
              'bufferedPositionMs': 3000,
              'durationMs': 5000,
              'volume': 0.75,
              'channelSwap': false,
            },
          };
        });

    final result = await NativePlaybackBridge.instance.play('session-1');

    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNotNull);
    expect(result.valueOrNull!.sessionId, 'session-1');
    expect(result.valueOrNull!.position, const Duration(milliseconds: 1500));
    expect(result.valueOrNull!.volume, closeTo(0.75, 0.001));
  });

  test(
    'snapshot decodes bundle payload and failure keeps the error message',
    () async {
      var callCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            callCount++;
            if (callCount == 1) {
              expect(call.method, NativePlaybackMethods.snapshot);
              return <String, Object?>{
                'ok': true,
                'value': <String, Object?>{
                  'focusedSessionId': 'focus-1',
                  'sessions': <Object?>[
                    <String, Object?>{
                      'sessionId': 'focus-1',
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'idle',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'volume': 1.0,
                      'channelSwap': false,
                    },
                  ],
                },
              };
            }
            return <String, Object?>{
              'ok': false,
              'error': 'native unavailable',
            };
          });

      final snapshot = await NativePlaybackBridge.instance.snapshot();
      final failure = await NativePlaybackBridge.instance.pause('focus-1');

      expect(snapshot.isOk, isTrue);
      expect(snapshot.valueOrNull?.focusedSessionId, 'focus-1');
      expect(snapshot.valueOrNull?.sessions, hasLength(1));
      expect(failure.isFailure, isTrue);
      expect(failure.errorOrNull, 'native unavailable');
    },
  );
}
