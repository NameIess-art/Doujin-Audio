import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/services/playback_notification_handler.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  test(
    'ASMR.ONE subtitles load even when remote metadata omits the extension',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        final format = request.uri.pathSegments.last;
        request.response.headers.contentType = ContentType.text;
        request.response.write(_subtitleBodyForFormat(format));
        await request.response.close();
      });

      final provider = AudioProvider.test(
        notificationService: PlaybackNotificationService(
          PlaybackNotificationHandler(),
        ),
      );
      addTearDown(provider.dispose);

      for (final format in <String>['vtt', 'srt', 'ass', 'ssa']) {
        final track = MusicTrack(
          path: 'https://example.com/$format.mp3',
          displayName: format,
          groupKey: 'asmr-work-1',
          groupTitle: 'ASMR Work',
          groupSubtitle: 'RJ000001',
          isSingle: false,
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: <String, Object?>{
            'subtitleUrl':
                'http://${server.address.host}:${server.port}/$format',
            'subtitleSourcePath': '01_mp3/track',
            'subtitleTitle': 'track',
          },
        );

        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);

        final subtitleTrack = await provider.subtitleTrackForPath(track.path);
        expect(subtitleTrack, isNotNull);
        expect(subtitleTrack!.cues, isNotEmpty);
        expect(subtitleTrack.cues.first.text, '第一句');
      }
    },
  );
}

String _subtitleBodyForFormat(String format) {
  return switch (format) {
    'vtt' => 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n第一句\n',
    'srt' => '1\n00:00:01,000 --> 00:00:02,000\n第一句\n',
    'ass' || 'ssa' =>
      '''
[Script Info]
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,第一句
''',
    _ => '',
  };
}
