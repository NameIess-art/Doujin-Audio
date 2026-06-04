import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_effects.dart';
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
          expect(call.method, NativePlaybackMethod.play);
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
              'speed': 1.5,
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
    expect(result.valueOrNull!.speed, closeTo(1.5, 0.001));
  });

  test('setSpeed forwards session id and speed to native playback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, NativePlaybackMethod.setSpeed);
          expect(call.arguments, <String, Object?>{
            'sessionId': 'session-1',
            'speed': 1.25,
          });
          return <String, Object?>{
            'ok': true,
            'value': <String, Object?>{
              'sessionId': 'session-1',
              'playing': false,
              'playWhenReady': false,
              'processingState': 'ready',
              'positionMs': 0,
              'bufferedPositionMs': 0,
              'durationMs': 5000,
              'speed': 1.25,
              'volume': 1.0,
              'channelSwap': false,
            },
          };
        });

    final result = await NativePlaybackBridge.instance.setSpeed(
      'session-1',
      1.25,
    );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull?.speed, closeTo(1.25, 0.001));
  });

  test('setAudioEffects forwards the complete effects payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, NativePlaybackMethod.setAudioEffects);
          expect(call.arguments, <String, Object?>{
            'sessionId': 'session-1',
            'effects': <String, Object?>{
              'skipSilenceEnabled': true,
              'noiseReductionEnabled': true,
              'volumeNormalizationEnabled': false,
              'eqEnabled': true,
              'eqPresetId': 'voice_clear',
              'eqBandLevels': <Object?>[
                <String, Object?>{'frequencyHz': 1000, 'gainDb': 2.5},
              ],
              'panning': 0.0,
              'channelSwapEnabled': true,
            },
          });
          return <String, Object?>{
            'ok': true,
            'value': <String, Object?>{
              'sessionId': 'session-1',
              'playing': false,
              'playWhenReady': false,
              'processingState': 'ready',
              'positionMs': 0,
              'bufferedPositionMs': 0,
              'durationMs': 5000,
              'speed': 1.0,
              'volume': 1.0,
              'channelSwap': true,
              'audioEffects': <String, Object?>{
                'skipSilenceEnabled': true,
                'noiseReductionEnabled': true,
                'eqEnabled': true,
                'eqPresetId': 'voice_clear',
                'eqBandLevels': <Object?>[
                  <String, Object?>{'frequencyHz': 1000, 'gainDb': 2.5},
                ],
              },
              'eqCapabilities': <String, Object?>{
                'supported': true,
                'minGainDb': -12.0,
                'maxGainDb': 12.0,
                'bands': <Object?>[
                  <String, Object?>{'frequencyHz': 1000},
                ],
              },
            },
          };
        });

    final result = await NativePlaybackBridge.instance.setAudioEffects(
      'session-1',
      const NativeAudioEffects(
        state: AudioEffectsState(
          skipSilenceEnabled: true,
          noiseReductionEnabled: true,
          eqEnabled: true,
          eqPresetId: 'voice_clear',
          eqBandLevels: <int, double>{1000: 2.5},
        ),
        channelSwapEnabled: true,
      ),
    );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull?.channelSwapEnabled, isTrue);
    expect(result.valueOrNull?.audioEffects.skipSilenceEnabled, isTrue);
    expect(result.valueOrNull?.audioEffects.eqBandLevels[1000], 2.5);
    expect(result.valueOrNull?.eqCapabilities.supported, isTrue);
  });

  test(
    'snapshot decodes bundle payload and failure keeps the error message',
    () async {
      var callCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            callCount++;
            if (callCount == 1) {
              expect(call.method, NativePlaybackMethod.snapshot);
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
      expect(snapshot.valueOrNull?.sessions.single.speed, 1.0);
      expect(failure.isFailure, isTrue);
      expect(failure.errorOrNull, 'native unavailable');
    },
  );
}
