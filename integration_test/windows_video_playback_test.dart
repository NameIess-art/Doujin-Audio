import 'dart:io';

import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
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
      final bridge = WindowsPlaybackBridge.instance..startListening();
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
          '10',
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
              child: NativeSessionVideoSurface(sessionId: sessionId),
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
        final player = bridge.playerForSession('video')!;
        await tester.pumpWidget(surface('video'));
        await tester.pump();
        final controller = tester.widget<Video>(find.byType(Video)).controller;
        final playResult = await bridge.play('video');
        expect(playResult.isOk, true, reason: playResult.errorOrNull);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline) &&
            (controller.rect.value?.width ?? 0) <= 0) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if ((controller.rect.value?.width ?? 0) <= 0) {
          final native = player.platform! as NativePlayer;
          final snapshot =
              (await bridge.snapshot()).valueOrNull!.sessions.single;
          throw TestFailure(
            'No video frame: playlist-pos=${await native.getProperty('playlist-pos')}, '
            'path=${await native.getProperty('path')}, error=${snapshot.error}',
          );
        }
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.rect.value?.size, const Size(320, 180));
        expect(find.byType(Texture), findsOneWidget);
        expect(player.state.position, greaterThan(Duration.zero));
        expect(await player.screenshot(format: 'image/png'), isNotEmpty);

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

        final autoResult = await bridge.prepareSession(
          sessionId: 'autoVideo',
          uri: file.uri,
          title: 'Auto Video',
          volume: 0,
          autoPlay: true,
        );
        expect(autoResult.isOk, true, reason: autoResult.errorOrNull);
        await tester.pumpWidget(surface('autoVideo'));
        await tester.pump();
        final autoController = tester.widget<Video>(find.byType(Video)).controller;
        final autoDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(autoDeadline) &&
            (autoController.rect.value?.width ?? 0) <= 0) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(autoController.rect.value?.size, const Size(320, 180));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await bridge.dispose();
        await directory.delete(recursive: true);
      }
    }),
    skip: !Platform.isWindows,
  );
}
