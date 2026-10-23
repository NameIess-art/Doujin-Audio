import 'dart:io';

import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerWindowsChapterPlaybackTest();
}

void registerWindowsChapterPlaybackTest() {
  testWidgets(
    'Windows HLS chapters remain bounded through shuffle and restore',
    (tester) => tester.runAsync(() async {
      MediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'windows_chapter_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final badHeaders = <String>[];
      var segmentRequests = 0;
      final serving = server.listen((request) async {
        if (request.headers.value('referer') != 'https://japaneseasmr.com/') {
          badHeaders.add(request.uri.path);
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          final file = File(
            '${directory.path}/${request.uri.pathSegments.last}',
          );
          if (await file.exists()) {
            if (file.path.endsWith('.ts')) segmentRequests++;
            request.response.headers.contentType = ContentType.parse(
              file.path.endsWith('.m3u8')
                  ? 'application/vnd.apple.mpegurl'
                  : 'video/mp2t',
            );
            await request.response.addStream(file.openRead());
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
        }
        await request.response.close();
      });
      final bridge = WindowsPlaybackBridge()..startListening();
      try {
        final encoder = await WindowsMediaTools.instance.start('ffmpeg', [
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000',
          '-t',
          '15',
          '-c:a',
          'aac',
          '-f',
          'hls',
          '-hls_time',
          '1',
          '-hls_playlist_type',
          'vod',
          '${directory.path}/chapters.m3u8',
        ]);
        final output = Future.wait([
          encoder.stdout.drain<void>(),
          encoder.stderr.drain<void>(),
        ]);
        expect(await encoder.exitCode, 0);
        await output;
        final stream =
            'http://${server.address.address}:${server.port}/chapters.m3u8';
        final queue = [
          for (final start in [3000, 7000])
            <String, Object?>{
              'uri': stream,
              'path': '$stream#eara-chapter=$start,${start + 2000}',
              'title': 'Chapter $start',
              'clipStartMs': start,
              'clipEndMs': start + 2000,
              'httpHeaders': {'Referer': 'https://japaneseasmr.com/'},
            },
        ];
        Future<NativePlaybackSnapshot> snapshot() async =>
            (await bridge.snapshot()).valueOrNull!.sessions.single;
        Future<NativePlaybackSnapshot> waitFor(
          bool Function(NativePlaybackSnapshot) matches,
        ) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          var state = await snapshot();
          while (!matches(state) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            state = await snapshot();
          }
          expect(
            matches(state),
            true,
            reason:
                '${state.processingState} ${state.error} ${state.queueIndex} ${state.position}',
          );
          return state;
        }

        for (final mode in ['sequential', 'shuffle', 'repeatOne']) {
          final prepared = await bridge.prepareSession(
            sessionId: 'chapters',
            uri: Uri.parse(stream),
            title: mode,
            queue: queue,
            autoPlay: true,
            shuffle: mode == 'shuffle',
            repeatAll: mode == 'shuffle',
            repeatOne: mode == 'repeatOne',
          );
          expect(prepared.isOk, true, reason: prepared.errorOrNull);
          var state = await waitFor(
            (s) => s.playing && s.position > const Duration(milliseconds: 100),
          );
          expect(state.duration, const Duration(seconds: 2));
          final player = bridge.playerForSession('chapters')!;
          final native = player.platform! as NativePlayer;
          await native.setProperty('mute', 'yes');
          await bridge.seek('chapters', const Duration(milliseconds: 800));
          await Future<void>.delayed(const Duration(milliseconds: 80));
          state = await snapshot();
          final expectedStart =
              (queue[state.queueIndex]['clipStartMs'] as int) / 1000;
          expect(
            double.parse(await native.getProperty('time-pos')),
            closeTo(expectedStart + 0.8, 0.25),
          );
          if (mode == 'repeatOne') {
            await Future<void>.delayed(const Duration(milliseconds: 1600));
            state = await snapshot();
            expect(state.playing, true);
            expect(state.queueIndex, 0);
            expect(
              state.position,
              lessThan(const Duration(milliseconds: 1500)),
            );
          } else {
            await waitFor(
              (s) =>
                  s.queueIndex == 1 &&
                  s.position > const Duration(milliseconds: 100),
            );
            expect(double.parse(await native.getProperty('start')), 7);
            expect(double.parse(await native.getProperty('end')), 9);
            if (mode == 'shuffle') {
              expect(
                (await bridge.setStopAfterCurrentTrack('chapters', true)).isOk,
                true,
              );
            }
            await waitFor((s) => s.processingState == 'completed');
            expect(bridge.playerForSession('chapters'), isNull);
          }
        }

        await bridge.seek('chapters', const Duration(milliseconds: 500));
        await bridge.pause('chapters');
        final saved = (await snapshot()).position;
        expect((await bridge.play('chapters')).isOk, true);
        final resumed = await waitFor((s) => s.playing);
        expect(
          resumed.position.inMilliseconds,
          closeTo(saved.inMilliseconds, 350),
        );
        final native =
            bridge.playerForSession('chapters')!.platform! as NativePlayer;
        expect(double.parse(await native.getProperty('start')), 3);
        expect(double.parse(await native.getProperty('end')), 5);
        expect(segmentRequests, greaterThan(0));
        expect(badHeaders, isEmpty);
      } finally {
        await bridge.dispose();
        await server.close(force: true);
        await serving.cancel();
        await directory.delete(recursive: true);
      }
    }),
    skip: !Platform.isWindows,
  );
}
