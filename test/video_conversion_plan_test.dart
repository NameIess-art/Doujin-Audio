import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/video_conversion_plan.dart';

void main() {
  test('parseVideoDurationMs accepts finite positive seconds only', () {
    expect(parseVideoDurationMs('12.345'), 12345);
    expect(parseVideoDurationMs('0'), 0);
    expect(parseVideoDurationMs('-1'), 0);
    expect(parseVideoDurationMs('NaN'), 0);
    expect(parseVideoDurationMs(null), 0);
  });

  test('buildVideoConversionCommand maps supported formats to ffmpeg args', () {
    expect(
      buildVideoConversionCommand(
        inputPath: r'C:\in folder\voice.mp4',
        outputPath: r'D:\out folder\voice.mp3',
        format: 'mp3',
        bitrate: '192k',
      ),
      r'-i "C:\in folder\voice.mp4" -vn -ar 44100 -ac 2 -b:a 192k "D:\out folder\voice.mp3"',
    );

    expect(
      buildVideoConversionCommand(
        inputPath: '/in/video.mkv',
        outputPath: '/out/video.flac',
        format: 'flac',
        bitrate: '320k',
      ),
      '-i "/in/video.mkv" -vn -c:a flac "/out/video.flac"',
    );

    expect(
      buildVideoConversionCommand(
        inputPath: '/in/video.mkv',
        outputPath: '/out/video.wav',
        format: 'wav',
        bitrate: '320k',
      ),
      '-i "/in/video.mkv" -vn -c:a pcm_s16le -ar 44100 -ac 2 "/out/video.wav"',
    );
  });

  test(
    'createVideoConversionPlan avoids overwriting existing output files',
    () async {
      final dir = await Directory.systemTemp.createTemp('audio_player_video_');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/clip.mp3').writeAsString('existing');

      final plan = await createVideoConversionPlan(
        inputPath: '${dir.path}/clip.mp4',
        outputDirectoryPath: dir.path,
        format: 'mp3',
        bitrate: '256k',
      );

      expect(plan.outputPath, endsWith('clip (1).mp3'));
      expect(plan.command, contains('-b:a 256k'));
      expect(plan.command, contains('"${plan.outputPath}"'));
    },
  );
}
