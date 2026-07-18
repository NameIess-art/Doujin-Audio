import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_runtime_graph.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production facade constructor requires only five high-level owners',
    () {
      final library = LibraryFacade.create();
      final playback = PlaybackFacade.create(
        databaseRepository: library.databaseRepository,
      );
      final timer = TimerFacade.create();
      final notification = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final settings = SettingsRepository();
      final runtimeGraph = createAppRuntimeGraph(
        library: library,
        playback: playback,
        timer: timer,
        notifications: notification,
        settings: settings,
      );
      addTearDown(runtimeGraph.runtime.dispose);

      expect(runtimeGraph.library, same(library));
      expect(runtimeGraph.playback, same(playback));
      expect(runtimeGraph.timer, same(timer));
      expect(runtimeGraph.notifications, same(notification));
      expect(runtimeGraph.settings, same(settings));
    },
  );

  test(
    'production subtitles resolve ASMR tracks from session queues',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('[00:01.00]ASMR subtitle');
        await request.response.close();
      });

      final library = LibraryFacade.create();
      final playback = PlaybackFacade.create(
        databaseRepository: library.databaseRepository,
      );
      final runtimeGraph = createAppRuntimeGraph(
        library: library,
        playback: playback,
        timer: TimerFacade.create(),
        notifications: NotificationFacade.create(
          service: PlaybackNotificationService(),
        ),
        settings: SettingsRepository(),
        persistenceEnabled: false,
      );
      addTearDown(runtimeGraph.runtime.dispose);

      final track = MusicTrack(
        path: 'https://example.com/asmr/track.mp3',
        displayName: 'track',
        groupKey: 'asmr-work-1',
        groupTitle: 'ASMR Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{
          'subtitleUrl':
              'http://${server.address.host}:${server.port}/track.lrc',
          'subtitleSourcePath': 'track.lrc',
          'subtitleExtension': '.lrc',
        },
      );
      playback.createTrackSession(
        track,
        customQueueTracks: <MusicTrack>[track],
      );

      expect(library.trackByPath(track.path), isNull);
      expect(runtimeGraph.audioPaths.trackByPath(track.path), same(track));
      final subtitle = await runtimeGraph.subtitles.load(track.path);
      expect(subtitle, isNotNull);
      expect(subtitle!.cues.single.text, 'ASMR subtitle');
    },
  );
}
