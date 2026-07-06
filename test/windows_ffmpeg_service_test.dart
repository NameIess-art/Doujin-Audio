import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/windows_ffmpeg_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  test(
    'Windows FFmpeg skips blank frames and reuses a content frame cover',
    () async {
      try {
        await Process.run(WindowsFfmpegService.ffmpegPath, const ['-version']);
      } on ProcessException {
        markTestSkipped('FFmpeg is not available on this Windows runner.');
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp(
        'windows_video_frame_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            if (call.method == 'getTemporaryDirectory') return tempDir.path;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null),
      );
      final video = File(
        '${tempDir.path}${Platform.pathSeparator}single-video.mp4',
      );
      final createResult = await Process.run(WindowsFfmpegService.ffmpegPath, [
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=64x64:d=3',
        '-f',
        'lavfi',
        '-i',
        'testsrc=s=64x64:d=1',
        '-filter_complex',
        '[0:v][1:v]concat=n=2:v=1:a=0,format=yuv420p',
        '-pix_fmt',
        'yuv420p',
        video.path,
      ]);
      expect(createResult.exitCode, 0, reason: createResult.stderr.toString());

      final first = await WindowsFfmpegService.resolveVideoFrame(
        videoPath: video.path,
        modifiedAtMs: 1,
      );
      final second = await WindowsFfmpegService.resolveVideoFrame(
        videoPath: video.path,
        modifiedAtMs: 1,
      );

      expect(first, isNotNull);
      expect(second, first);
      expect(await File(first!).length(), greaterThan(0));

      final analysis = await Process.run(WindowsFfmpegService.ffmpegPath, [
        '-hide_banner',
        '-i',
        first,
        '-vf',
        'signalstats,entropy,metadata=print',
        '-frames:v',
        '1',
        '-f',
        'null',
        '-',
      ]);
      expect(
        analysis.stderr.toString(),
        isNot(contains('lavfi.signalstats.YAVG=0')),
      );

      final blankVideo = File(
        '${tempDir.path}${Platform.pathSeparator}blank-video.mp4',
      );
      final blankResult = await Process.run(WindowsFfmpegService.ffmpegPath, [
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=64x64:d=2',
        '-pix_fmt',
        'yuv420p',
        blankVideo.path,
      ]);
      expect(blankResult.exitCode, 0, reason: blankResult.stderr.toString());
      expect(
        await WindowsFfmpegService.resolveVideoFrame(
          videoPath: blankVideo.path,
          modifiedAtMs: 1,
        ),
        isNull,
      );

      final whiteVideo = File(
        '${tempDir.path}${Platform.pathSeparator}white-video.mp4',
      );
      final whiteResult = await Process.run(WindowsFfmpegService.ffmpegPath, [
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=white:s=64x64:d=2',
        '-pix_fmt',
        'yuv420p',
        whiteVideo.path,
      ]);
      expect(whiteResult.exitCode, 0, reason: whiteResult.stderr.toString());
      expect(
        await WindowsFfmpegService.resolveVideoFrame(
          videoPath: whiteVideo.path,
          modifiedAtMs: 1,
        ),
        isNull,
      );
    },
    skip: !Platform.isWindows,
  );
}
