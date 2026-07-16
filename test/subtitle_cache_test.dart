import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/application/playback_subtitle_service.dart';

void main() {
  test('subtitle track requests share the in-flight load', () async {
    final tempDir = await Directory.systemTemp.createTemp('subtitle_cache_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final audioFile = File('${tempDir.path}${Platform.pathSeparator}track.mp3');
    final subtitleFile = File(
      '${tempDir.path}${Platform.pathSeparator}track.srt',
    );
    await audioFile.writeAsBytes(const <int>[]);
    await subtitleFile.writeAsString('''
1
00:00:01,000 --> 00:00:02,000
hello
''');

    final subtitles = PlaybackSubtitleService(trackResolver: (_) => null);

    final first = subtitles.load(audioFile.path);
    final second = subtitles.load(audioFile.path);

    expect(identical(first, second), isTrue);

    final track = await first;
    expect(track, isNotNull);
    expect(track!.cues.single.text, 'hello');

    final cached = await subtitles.load(audioFile.path);
    expect(cached, same(track));
  });

  test(
    'subtitle track discovery matches double-extension subtitle files',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'subtitle_cache_double_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final audioFile = File(
        '${tempDir.path}${Platform.pathSeparator}track.mp3',
      );
      final subtitleFile = File(
        '${tempDir.path}${Platform.pathSeparator}track.mp3.vtt',
      );
      await audioFile.writeAsBytes(const <int>[]);
      await subtitleFile.writeAsString('''
WEBVTT

00:00:01.000 --> 00:00:02.000
hello
''');

      final subtitles = PlaybackSubtitleService(trackResolver: (_) => null);

      final track = await subtitles.load(audioFile.path);
      expect(track, isNotNull);
      expect(track!.cues.single.text, 'hello');
    },
  );

  test('content uri subtitle requests cache the null result', () async {
    final subtitles = PlaybackSubtitleService(trackResolver: (_) => null);

    final first = subtitles.load('content://media/audio/1');
    final second = subtitles.load('content://media/audio/1');

    expect(identical(first, second), isTrue);
    expect(await first, isNull);
    expect(await subtitles.load('content://media/audio/1'), isNull);
  });
}
