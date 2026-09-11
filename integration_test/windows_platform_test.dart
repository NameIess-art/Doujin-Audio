import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:doujin_audio/core/platform/update_platform_service.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/subtitle_overlay_platform_service.dart';
import 'package:doujin_audio/core/platform/windows_desktop_service.dart';
import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';

import 'windows_video_playback_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows native channels and real multi-session playback',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(() async {
        final version = await UpdatePlatformService().getAppVersion();
        expect(version.isOk, true, reason: version.errorOrNull);
        expect(version.valueOrNull!.platform, 'windows');
        final storage = await FileCachePlatformGateway.instance
            .readStorageUsage();
        expect(storage, isNotNull);
        sqfliteFfiInit();
        final database = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
        );
        try {
          await database.execute('CREATE TABLE smoke (name TEXT NOT NULL)');
          await database.insert('smoke', {'name': '音声 Windows'});
          expect((await database.query('smoke')).single['name'], '音声 Windows');
        } finally {
          await database.close();
        }
        final overlay = SubtitleOverlayPlatformService();
        expect(await overlay.canDrawOverlays(), true);
        await overlay.updateStyle({
          'fontSize': 24.0,
          'textColor': '#ffffff',
          'backgroundOpacity': 0.0,
        });
        await overlay.updateSubtitle('Windows subtitle smoke test');
        await overlay.startOverlay();
        await overlay.updateSubtitle(List.filled(30, '多行字幕 Windows wrapping').join(' '));
        await overlay.updateStyle({'fontSize': 36.0, 'borderDepth': 0.5});
        await overlay.updateSubtitle('Short subtitle');
        await overlay.stopOverlay();
        await WindowsDesktopService.instance.setFullscreen(true);
        await WindowsDesktopService.instance.setFullscreen(false);
        final resumed = Completer<void>();
        await WindowsDesktopService.instance.attach((action) async {
          if (action == 'resume' && !resumed.isCompleted) resumed.complete();
        });
        final secondInstance = await Process.run(Platform.resolvedExecutable, [
          '--background',
        ]);
        expect(secondInstance.exitCode, 0);
        await resumed.future.timeout(const Duration(seconds: 5));
        const power = MethodChannel('doujin_audio/power');
        final timer = <String, Object?>{
          'timerMode': 0,
          'timerDurationMs': 3600000,
          'timerWaitingForPlayback': false,
          'timerEndsAtWallClockMs': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          'autoResumeEnabled': false,
          'autoResumeHour': 0,
          'autoResumeMinute': 0,
          'autoResumeAtMs': null,
          'pausedSessionIds': <String>[],
          'generation': 1,
        };
        try {
          final result = await power.invokeMapMethod<String, Object?>(
            'syncPlaybackTimerAlarms',
            timer,
          );
          expect(result?['ok'], true);
        } finally {
          timer['timerMode'] = null;
          timer['timerEndsAtWallClockMs'] = null;
          final result = await power.invokeMapMethod<String, Object?>(
            'syncPlaybackTimerAlarms',
            timer,
          );
          expect(result?['ok'], true);
        }
        expect(
          () => const MethodChannel(
            'doujin_audio/power',
          ).invokeMethod<Object?>('acquireWakeLock', <String, Object?>{}),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );

        MediaKit.ensureInitialized();
        final directory = await Directory.systemTemp.createTemp(
          'doujin_windows_playback_',
        );
        final track = File('${directory.path}/音声 test.wav');
        const rate = 48000, seconds = 10;
        final bytes = ByteData(44 + rate * seconds * 2);
        void text(int offset, String value) {
          for (var i = 0; i < value.length; i++) {
            bytes.setUint8(offset + i, value.codeUnitAt(i));
          }
        }

        text(0, 'RIFF');
        bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
        text(8, 'WAVEfmt ');
        bytes.setUint32(16, 16, Endian.little);
        bytes.setUint16(20, 1, Endian.little);
        bytes.setUint16(22, 1, Endian.little);
        bytes.setUint32(24, rate, Endian.little);
        bytes.setUint32(28, rate * 2, Endian.little);
        bytes.setUint16(32, 2, Endian.little);
        bytes.setUint16(34, 16, Endian.little);
        text(36, 'data');
        bytes.setUint32(40, rate * seconds * 2, Endian.little);
        for (var sample = 0; sample < rate * seconds; sample++) {
          bytes.setInt16(
            44 + sample * 2,
            sample < rate * 3
                ? 0
                : (math.sin(sample * 2 * math.pi * 440 / rate) * 1000).round(),
            Endian.little,
          );
        }
        await track.writeAsBytes(bytes.buffer.asUint8List());
        final video = File('${directory.path}/视频 test.mp4');
        final conversion = await WindowsMediaTools.instance.start('ffmpeg', [
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=320x180:r=24',
          '-i',
          track.path,
          '-t',
          '2',
          '-c:v',
          'mpeg4',
          '-c:a',
          'aac',
          video.path,
        ]);
        final conversionOutput = Future.wait([
          conversion.stdout.drain<void>(),
          conversion.stderr.drain<void>(),
        ]);
        expect(await conversion.exitCode, 0);
        await conversionOutput;
        final frame = await WindowsMediaTools.instance.extractImage(
          video.path,
          videoFrame: true,
        );
        expect(frame, isNotNull);
        expect(await File(frame!).length(), greaterThan(0));
        await File(frame).delete();
        expect(
          await WindowsMediaTools.instance.readDuration(track.path),
          const Duration(seconds: 10),
        );
        final players = [Player(), Player()];
        for (final player in players) {
          await (player.platform! as NativePlayer).setProperty('mute', 'yes');
        }
        if (const bool.fromEnvironment('WINDOWS_TEST_NULL_AUDIO')) {
          for (final player in players) {
            await (player.platform! as NativePlayer).setProperty('ao', 'null');
          }
        }
        var nextPlayer = 0;
        final bridge = WindowsPlaybackBridge(
          createPlayer: () => players[nextPlayer++],
        )..startListening();
        try {
          for (final id in ['one', 'two']) {
            final result = await bridge.prepareSession(
              sessionId: id,
              uri: track.uri,
              title: id,
              volume: id == 'one' ? 2.7 : 0,
              autoPlay: true,
              startPosition: const Duration(seconds: 1),
              audioEffects: NativeAudioEffects(
                channelSwapEnabled: true,
                state: AudioEffectsState(
                  eqEnabled: true,
                  eqBandLevels: {1000: 3},
                  noiseReductionEnabled: true,
                  volumeNormalizationEnabled: true,
                  skipSilenceEnabled: true,
                  panning: 0.3,
                ),
              ),
            );
            expect(result.isOk, true, reason: result.errorOrNull);
          }
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          var playing = false;
          while (DateTime.now().isBefore(deadline)) {
            final state = (await bridge.snapshot()).valueOrNull!;
            if (state.sessions.every(
              (s) => s.playing && s.position > const Duration(seconds: 3),
            )) {
              playing = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final state = (await bridge.snapshot()).valueOrNull!;
          expect(
            playing,
            true,
            reason: state.sessions
                .map((s) => '${s.processingState}: ${s.error} @ ${s.position}')
                .join(', '),
          );
          final player = bridge.playerForSession('one');
          expect(
            double.parse(
              await (player!.platform! as NativePlayer).getProperty('volume'),
            ),
            closeTo(270, 0.01),
          );
          await bridge.setRepeatOne(
            'one',
            true,
            queue: [
              {
                'uri': track.uri.toString(),
                'path': track.path,
                'title': 'same',
              },
            ],
          );
          expect(bridge.playerForSession('one'), same(player));
          await bridge.pause('one');
          expect(
            (await bridge.snapshot()).valueOrNull!.sessions.first.playing,
            false,
          );
        } finally {
          await bridge.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
    skip: !Platform.isWindows,
  );
  registerWindowsVideoPlaybackTest();
}
