import 'dart:io';

import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/presentation/session_video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerWindowsVideoPlaybackTest();
}

void registerWindowsVideoPlaybackTest() {
  testWidgets(
    'Windows renders video and reuses the player across surfaces',
    (tester) => tester.runAsync(() async {
      MediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp('windows_video_');
      final file = File('${directory.path}/中文 video.mp4');
      // CI runners may have no usable GPU or hardware video decoder.
      final bridge = WindowsPlaybackBridge(
        videoControllerConfiguration: const VideoControllerConfiguration(
          enableHardwareAcceleration: false,
          hwdec: 'no',
        ),
      )..startListening();
      final repository = NativePlaybackRepository(bridge: bridge);
      try {
        final encoder = await WindowsMediaTools.instance.start('ffmpeg', [
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x180:rate=24',
          '-t',
          // Keep the fixture alive through the first-frame and resume deadlines.
          '60',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          file.path,
        ]);
        final output = Future.wait([
          encoder.stdout.drain<void>(),
          encoder.stderr.drain<void>(),
        ]);
        expect(await encoder.exitCode, 0);
        await output;
        Widget surface(String sessionId) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 360,
              child: NativeSessionVideoSurface(
                sessionId: sessionId,
                nativeRepository: repository,
              ),
            ),
          ),
        );
        final result = await bridge.prepareSession(
          sessionId: 'video',
          uri: file.uri,
          title: 'Video',
          volume: 0,
        );
        expect(result.isOk, true, reason: result.errorOrNull);
        expect(bridge.playerForSession('video'), isNull);
        await tester.pumpWidget(surface('video'));
        await tester.pump();
        expect(find.byType(Video), findsNothing);
        expect(bridge.playerForSession('video'), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        final playResult = await bridge.play('video');
        expect(playResult.isOk, true, reason: playResult.errorOrNull);
        final player = bridge.playerForSession('video')!;
        final loadDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(loadDeadline) &&
            (!player.state.tracks.video.any((track) => track.id == '1') ||
                player.state.duration <= Duration.zero ||
                player.state.buffering)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (!player.state.tracks.video.any((track) => track.id == '1')) {
          final snapshot =
              (await bridge.snapshot()).valueOrNull!.sessions.single;
          final native = bridge.playerForSession('video')?.platform;
          final tracks = native is NativePlayer
              ? await native.getProperty('track-list')
              : 'player released';
          throw TestFailure(
            'Video without surface: playerReleased=${native == null}, '
            'playing=${snapshot.playing}, requested=${snapshot.playWhenReady}, '
            'processing=${snapshot.processingState}, position=${snapshot.position}, '
            'completed=${player.state.completed}, '
            'tracks=${player.state.tracks.video}, nativeTracks=$tracks, '
            'error=${snapshot.error}',
          );
        }
        expect(
          (await bridge.seek('video', const Duration(seconds: 12))).isOk,
          true,
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(player.state.position.inMilliseconds, closeTo(12000, 1500));
        final firstPause = await bridge.pause('video');
        expect(firstPause.isOk, true);
        expect(
          firstPause.valueOrNull!.position.inMilliseconds,
          closeTo(12000, 1500),
        );
        expect(bridge.playerForSession('video'), same(player));
        await tester.pumpWidget(surface('video'));
        final surfaceDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(surfaceDeadline) &&
            find.byType(Video).evaluate().isEmpty) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byType(Video), findsOneWidget);
        final controller = tester.widget<Video>(find.byType(Video)).controller;
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline) &&
            (controller.rect.value?.width ?? 0) <= 0) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if ((controller.rect.value?.width ?? 0) <= 0) {
          final snapshot =
              (await bridge.snapshot()).valueOrNull!.sessions.single;
          final currentPlayer = bridge.playerForSession('video');
          throw TestFailure(
            'No video frame: playerReleased=${currentPlayer == null}, '
            'playing=${snapshot.playing}, requested=${snapshot.playWhenReady}, '
            'processing=${snapshot.processingState}, position=${snapshot.position}, '
            'path=${snapshot.path ?? snapshot.uri}, error=${snapshot.error}',
          );
        }
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.rect.value?.size, const Size(320, 180));
        expect(find.byType(Texture), findsOneWidget);
        expect(player.state.playing, false);
        expect(player.state.position.inMilliseconds, closeTo(12000, 1500));
        expect(await player.screenshot(format: 'image/png'), isNotEmpty);
        final initialPosition = player.state.position;
        await tester.pump(const Duration(milliseconds: 500));
        expect(player.state.position, initialPosition);
        expect((await bridge.play('video')).isOk, true);
        await tester.pump(const Duration(milliseconds: 500));
        expect(player.state.playing, true);

        // The detail surface is removed while fullscreen owns the same session.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(surface('video'));
        await tester.pump();
        expect(
          tester.widget<Video>(find.byType(Video)).controller,
          same(controller),
        );
        expect(bridge.playerForSession('video'), same(player));
        expect(controller.id.value, isNotNull);

        final paused = await bridge.pause('video');
        expect(paused.isOk, true, reason: paused.errorOrNull);
        await tester.pump();
        expect(bridge.playerForSession('video'), same(player));
        expect(find.byType(Video), findsOneWidget);
        expect(await player.screenshot(format: 'image/png'), isNotEmpty);
        expect(
          (await bridge.seek('video', const Duration(seconds: 20))).isOk,
          true,
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(player.state.playing, false);
        expect(player.state.position.inMilliseconds, closeTo(20000, 100));
        final pausedPosition = player.state.position;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(surface('video'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(bridge.playerForSession('video'), same(player));
        expect(
          tester.widget<Video>(find.byType(Video)).controller,
          same(controller),
        );
        expect(player.state.position, pausedPosition);
        expect(await player.screenshot(format: 'image/png'), isNotEmpty);
        final resumed = await bridge.play('video');
        expect(resumed.isOk, true, reason: resumed.errorOrNull);
        final resumedPlayer = bridge.playerForSession('video');
        expect(resumedPlayer, isNotNull);
        expect(resumedPlayer, same(player));
        final resumeDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(resumeDeadline) &&
            (!resumedPlayer!.state.playing ||
                resumedPlayer.state.position < pausedPosition)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(resumedPlayer!.state.playing, true);
        expect(
          resumedPlayer.state.position,
          greaterThanOrEqualTo(pausedPosition),
        );
        expect(find.byType(Video), findsOneWidget);
        final resumedController = tester
            .widget<Video>(find.byType(Video))
            .controller;
        expect(resumedController, same(controller));
        await bridge.pause('video');
        await tester.pump();
        expect(bridge.playerForSession('video'), same(player));
        expect(find.byType(Video), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect((await bridge.removeSession('video')).isOk, true);
        expect(bridge.playerForSession('video'), isNull);

        final autoResult = await bridge.prepareSession(
          sessionId: 'autoVideo',
          uri: file.uri,
          title: 'Auto Video',
          volume: 0,
          autoPlay: true,
        );
        expect(autoResult.isOk, true, reason: autoResult.errorOrNull);
        expect(bridge.playerForSession('video'), isNull);
        await tester.pumpWidget(surface('autoVideo'));
        await tester.pump();
        final autoController = tester
            .widget<Video>(find.byType(Video))
            .controller;
        final autoDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(autoDeadline) &&
            (autoController.rect.value?.width ?? 0) <= 0) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (autoController.rect.value?.size != const Size(320, 180)) {
          final native = autoController.player.platform! as NativePlayer;
          final properties = <String, String>{};
          for (final name in [
            'vo',
            'vid',
            'playlist-pos',
            'idle-active',
            'pause',
            'time-pos',
            'duration',
            'track-list',
            'video-params',
          ]) {
            properties[name] = await native.getProperty(name);
          }
          final snapshot =
              (await bridge.snapshot()).valueOrNull!.sessions.single;
          throw TestFailure(
            'Auto video: $properties; '
            'playing=${snapshot.playing}, requested=${snapshot.playWhenReady}, '
            'processing=${snapshot.processingState}, error=${snapshot.error}; '
            'videoParams=${autoController.player.state.videoParams}',
          );
        }
        expect(bridge.playerForSession('video'), isNull);
        await bridge.pause('autoVideo');
        await tester.pump();
        expect(
          bridge.playerForSession('autoVideo'),
          same(autoController.player),
        );
        expect(find.byType(Video), findsOneWidget);
        expect(
          await autoController.player.screenshot(format: 'image/png'),
          isNotEmpty,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await bridge.dispose();
        await directory.delete(recursive: true);
      }
    }),
    skip: !Platform.isWindows,
  );
}
