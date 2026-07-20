import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nameless_audio/app/presentation/main_screen.dart';
import 'package:nameless_audio/app/presentation/onboarding_page.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android version channel and native playback critical path',
    (tester) async {
      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      if (find.byType(OnboardingPage).evaluate().isNotEmpty) {
        await tester.tap(find.byType(FilledButton).first);
        await tester.pumpAndSettle();
      }
      expect(find.byType(MainScreen), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MainScreen)),
        listen: false,
      );
      final version = await container
          .read(appUpdateServiceProvider)
          .currentAppVersion();
      expect(
        version.versionName,
        matches(RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')),
      );
      expect(version.buildNumber, greaterThan(0));
      expect(const <String>{
        'arm64',
        'armv7',
        'x64',
        'universal',
      }, contains(version.androidAssetVariant));

      final playback = container.read(playbackFacadeProvider);
      final wav = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'nameless_audio_native_smoke_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await wav.writeAsBytes(_pcmWav(seconds: 8), flush: true);

      try {
        await playback.launchQueue(
          <MusicTrack>[
            MusicTrack(
              path: wav.path,
              displayName: 'Native smoke WAV',
              groupKey: wav.parent.path,
              groupTitle: 'Integration test',
              groupSubtitle: '',
              isSingle: true,
              fileSizeBytes: await wav.length(),
              duration: const Duration(seconds: 8),
            ),
          ],
          autoPlay: true,
          loopMode: SessionLoopMode.folderSequential,
        );

        await _waitFor(
          tester,
          () =>
              playback.state.activeSessions.length == 1 &&
              playback.state.activeSessions.single.position >
                  const Duration(milliseconds: 300),
          'native playback did not advance',
        );
        final session = playback.state.activeSessions.single;

        await playback.toggleSessionPlayPause(session.id);
        await _waitFor(
          tester,
          () => !session.effectivePlaying,
          'native playback did not pause',
        );
        var nativeSession = await _nativeSession(playback, session.id);
        expect(nativeSession.playWhenReady, isFalse);

        const seekPosition = Duration(seconds: 2);
        await playback.seekSession(session.id, seekPosition);
        nativeSession = await _nativeSession(playback, session.id);
        expect(
          nativeSession.position.inMilliseconds,
          inInclusiveRange(1500, 2500),
        );

        await playback.toggleSessionPlayPause(session.id);
        await _waitFor(
          tester,
          () => session.position > const Duration(milliseconds: 2300),
          'native playback did not resume after seek',
        );

        final beforeBackground = await _nativeSession(playback, session.id);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        nativeSession = await _nativeSession(playback, session.id);
        expect(nativeSession.playWhenReady, isTrue);
        expect(nativeSession.position, greaterThan(beforeBackground.position));

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _waitFor(
          tester,
          () => session.position > nativeSession.position,
          'playback did not reconcile after foreground resume',
        );
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await playback.clearAllSessions();
        if (await wav.exists()) await wav.delete();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  String failureMessage,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (!condition()) throw TestFailure(failureMessage);
}

Future<NativePlaybackSnapshot> _nativeSession(
  PlaybackFacade playback,
  String sessionId,
) async {
  final result = await playback.nativeRepository.snapshot();
  expect(
    result.isOk,
    isTrue,
    reason: '${result.errorCodeOrNull}: ${result.errorOrNull}',
  );
  return result.valueOrNull!.sessions.singleWhere(
    (session) => session.sessionId == sessionId,
  );
}

Uint8List _pcmWav({required int seconds}) {
  const sampleRate = 44100;
  const channelCount = 1;
  const bitsPerSample = 16;
  const bytesPerSample = bitsPerSample ~/ 8;
  final dataLength = seconds * sampleRate * channelCount * bytesPerSample;
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.view(bytes.buffer);

  bytes.setAll(0, 'RIFF'.codeUnits);
  data.setUint32(4, 36 + dataLength, Endian.little);
  bytes.setAll(8, 'WAVE'.codeUnits);
  bytes.setAll(12, 'fmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channelCount, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channelCount * bytesPerSample, Endian.little);
  data.setUint16(32, channelCount * bytesPerSample, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  bytes.setAll(36, 'data'.codeUnits);
  data.setUint32(40, dataLength, Endian.little);
  return bytes;
}
