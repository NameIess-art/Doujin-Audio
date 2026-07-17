import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/domain/audio_effects.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativePlaybackChannel.name);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('progress event decodes independently from legacy snapshots', () {
    final updates = parseNativePlaybackProgressEvent(<String, Object?>{
      'eventType': 'progress',
      'nativeElapsedRealtimeMs': 8000,
      'updates': <Object?>[
        <String, Object?>{
          'sessionId': ' session-1 ',
          'positionMs': 1500,
          'bufferedPositionMs': 3000,
          'durationMs': 5000,
          'nativeElapsedRealtimeMs': 8000,
        },
      ],
    });

    expect(updates, hasLength(1));
    expect(updates.single.sessionId, 'session-1');
    expect(updates.single.position, const Duration(milliseconds: 1500));
    expect(updates.single.bufferedPosition, const Duration(milliseconds: 3000));
    expect(updates.single.duration, const Duration(milliseconds: 5000));
    expect(updates.single.nativeElapsedRealtimeMs, 8000);
  });

  test('unknown native event is not parsed as progress', () {
    expect(
      parseNativePlaybackProgressEvent(<String, Object?>{
        'eventType': 'future-event',
      }),
      isEmpty,
    );
  });

  test('play decodes success payload into a typed snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, NativePlaybackMethod.play);
          expect(call.arguments, <String, Object?>{
            'sessionId': 'session-1',
            'transportCommandId': 7,
            'exclusive': true,
          });
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
              'transportCommandId': 7,
            },
          };
        });

    final result = await NativePlaybackBridge.instance.play(
      'session-1',
      transportCommandId: 7,
      exclusive: true,
    );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNotNull);
    expect(result.valueOrNull!.sessionId, 'session-1');
    expect(result.valueOrNull!.position, const Duration(milliseconds: 1500));
    expect(result.valueOrNull!.volume, closeTo(0.75, 0.001));
    expect(result.valueOrNull!.speed, closeTo(1.5, 0.001));
    expect(result.valueOrNull!.transportCommandId, 7);
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

  test('prepareSession forwards audio effects atomically', () async {
    Map<Object?, Object?>? arguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, NativePlaybackMethod.prepareSession);
          arguments = call.arguments as Map<Object?, Object?>;
          return <String, Object?>{'ok': false, 'error': 'test'};
        });

    await NativePlaybackBridge.instance.prepareSession(
      sessionId: 'session-1',
      uri: Uri.file('/audio/one.mp3'),
      title: 'one',
      audioEffects: const NativeAudioEffects(
        state: AudioEffectsState(
          skipSilenceEnabled: true,
          eqEnabled: true,
          eqBandLevels: <int, double>{1000: 2.5},
        ),
        channelSwapEnabled: true,
      ),
    );

    final effects = arguments!['audioEffects'] as Map<Object?, Object?>;
    expect(effects['skipSilenceEnabled'], isTrue);
    expect(effects['eqEnabled'], isTrue);
    expect(effects['channelSwapEnabled'], isTrue);
    expect((effects['eqBandLevels'] as List<Object?>).single, <String, Object?>{
      'frequencyHz': 1000,
      'gainDb': 2.5,
    });
  });

  test(
    'snapshot decodes bundle payload and failure keeps structured details',
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
              'errorCode': 'service_unavailable',
              'error': 'native unavailable',
              'details': <String, Object?>{'method': 'pause'},
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
      expect(failure.errorCodeOrNull, 'service_unavailable');
      expect(failure.errorDetailsOrNull, <String, Object?>{'method': 'pause'});
    },
  );

  test('PlatformException preserves code and details', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'invalid_argument',
            message: 'sessionId is required',
            details: <String, Object?>{'argument': 'sessionId'},
          );
        });

    final failure = await NativePlaybackBridge.instance.pause('session-1');

    expect(failure.errorOrNull, 'sessionId is required');
    expect(failure.errorCodeOrNull, 'invalid_argument');
    expect(failure.errorDetailsOrNull, <String, Object?>{
      'argument': 'sessionId',
    });
  });

  test('a valid event resets the EventChannel reconnect backoff', () async {
    const eventsChannel = EventChannel(NativePlaybackChannel.eventName);
    final eventSinks = <MockStreamHandlerEventSink>[];
    var listenCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          eventsChannel,
          MockStreamHandler.inline(
            onListen: (_, events) {
              listenCount++;
              eventSinks.add(events);
            },
          ),
        );
    final bridge = NativePlaybackBridge.instance;
    await bridge.stopListening();

    try {
      bridge.startListening();
      await Future<void>.delayed(Duration.zero);
      expect(listenCount, 1);

      eventSinks[0].error(code: 'disconnect-1');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(listenCount, 2);

      eventSinks[1].success(<String, Object?>{
        'sessionId': 'session-1',
        'playing': false,
        'playWhenReady': false,
        'processingState': 'ready',
        'positionMs': 0,
        'bufferedPositionMs': 0,
        'volume': 1.0,
        'channelSwap': false,
      });
      await Future<void>.delayed(Duration.zero);
      eventSinks[1].error(code: 'disconnect-2');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(listenCount, 3);
    } finally {
      await bridge.stopListening();
    }
  });

  test(
    'EventChannel reconnect uses capped exponential delays indefinitely',
    () {
      expect(List<int>.generate(8, nativePlaybackReconnectDelayMs), <int>[
        200,
        400,
        800,
        1600,
        3200,
        5000,
        5000,
        5000,
      ]);
    },
  );
}
