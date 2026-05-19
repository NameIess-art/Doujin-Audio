import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/services/playback_notification_handler.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

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

    final provider = AudioProvider.test(
      notificationService: PlaybackNotificationService(
        PlaybackNotificationHandler(),
      ),
    );
    addTearDown(provider.dispose);

    final first = provider.subtitleTrackForPath(audioFile.path);
    final second = provider.subtitleTrackForPath(audioFile.path);

    expect(identical(first, second), isTrue);

    final track = await first;
    expect(track, isNotNull);
    expect(track!.cues.single.text, 'hello');

    final cached = await provider.subtitleTrackForPath(audioFile.path);
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

      final provider = AudioProvider.test(
        notificationService: PlaybackNotificationService(
          PlaybackNotificationHandler(),
        ),
      );
      addTearDown(provider.dispose);

      final track = await provider.subtitleTrackForPath(audioFile.path);
      expect(track, isNotNull);
      expect(track!.cues.single.text, 'hello');
    },
  );

  test('content uri subtitle requests cache the null result', () async {
    final provider = AudioProvider.test(
      notificationService: PlaybackNotificationService(
        PlaybackNotificationHandler(),
      ),
    );
    addTearDown(provider.dispose);

    final first = provider.subtitleTrackForPath('content://media/audio/1');
    final second = provider.subtitleTrackForPath('content://media/audio/1');

    expect(identical(first, second), isTrue);
    expect(await first, isNull);
    expect(
      await provider.subtitleTrackForPath('content://media/audio/1'),
      isNull,
    );
  });
}
