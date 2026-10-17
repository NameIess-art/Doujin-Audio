import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;
  late Directory remoteCache;
  late Directory userSubtitles;
  late HttpServer server;
  late MusicTrack track;
  late Map<String, int> requests;
  const audioPath = 'https://example.com/audio.mp3';

  String url(String name) =>
      'http://${server.address.host}:${server.port}/$name';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    AppCacheService.resetForTest();
    AppCacheService.scheduledEnforceEnabled = false;
    directory = await Directory.systemTemp.createTemp('asmr_subtitle_cache_');
    remoteCache = Directory(path.join(directory.path, 'asmr_subtitles'));
    userSubtitles = await Directory(
      path.join(directory.path, 'imported_subtitles'),
    ).create();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = {};
    track = MusicTrack(
      path: audioPath,
      displayName: 'Audio',
      groupKey: 'work',
      groupTitle: 'Work',
      groupSubtitle: 'ASMR',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: {'subtitleUrl': url('old.srt')},
    );
  });

  tearDown(() async {
    await server.close(force: true);
    AppCacheService.resetForTest();
    await directory.delete(recursive: true);
  });

  PlaybackSubtitleService service({
    void Function(String, SubtitleTrack?)? onTrackLoaded,
  }) {
    final result = PlaybackSubtitleService(
      trackResolver: (_) => track,
      subtitlesDirectoryResolver: () async => userSubtitles,
      remoteSubtitlesDirectoryResolver: () async => remoteCache,
      onTrackLoaded: onTrackLoaded,
    );
    addTearDown(result.dispose);
    return result;
  }

  void serve() {
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      requests.update(name, (count) => count + 1, ifAbsent: () => 1);
      request.response.write(_srt(name));
      await request.response.close();
    });
  }

  test(
    'source replacement invalidates sync results and survives restart',
    () async {
      serve();
      final subtitles = service();
      final old = await subtitles.load(audioPath);
      expect(old?.cues.single.text, 'old.srt');
      expect(path.isWithin(remoteCache.path, old!.sourcePath), isTrue);

      track = track.copyWith(remoteMetadata: {'subtitleUrl': url('new.srt')});
      expect(subtitles.hasResult(audioPath), isFalse);
      expect(subtitles.trackSync(audioPath), isNull);
      expect(
        subtitles.textAt(audioPath, const Duration(milliseconds: 1500)),
        isNull,
      );

      final replacement = await subtitles.loadAutomatically(audioPath);
      expect(replacement?.cues.single.text, 'new.srt');
      expect(replacement!.sourcePath, isNot(old.sourcePath));
      final restarted = service();
      expect((await restarted.load(audioPath))?.cues.single.text, 'new.srt');
      expect(requests, {'old.srt': 1, 'new.srt': 1});
    },
  );

  test('late source cannot publish or write after its replacement', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      if (name == 'old.srt') {
        started.complete();
        await release.future;
      }
      request.response.write(_srt(name));
      await request.response.close();
    });
    final callbacks = <String?>[];
    final subtitles = service(
      onTrackLoaded: (_, loaded) => callbacks.add(loaded?.cues.single.text),
    );
    final old = subtitles.load(audioPath);
    await started.future;
    track = track.copyWith(remoteMetadata: {'subtitleUrl': url('new.srt')});
    expect(subtitles.isLoading(audioPath), isFalse);
    final replacement = await subtitles.load(audioPath);
    expect(replacement?.cues.single.text, 'new.srt');
    release.complete();
    expect(await old, same(replacement));
    expect(subtitles.trackSync(audioPath), same(replacement));
    expect(callbacks, ['new.srt']);
    expect(await remoteCache.list().length, 1);
  });

  test('clearing during a remote request retires its disk write', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    server.listen((request) async {
      started.complete();
      await release.future;
      request.response.write(_srt('Old'));
      await request.response.close();
    });
    final subtitles = service();
    final loading = subtitles.load(audioPath);
    await started.future;
    subtitles.clear();
    release.complete();
    expect(await loading, isNull);
    expect(subtitles.hasResult(audioPath), isFalse);
    expect(await remoteCache.list().isEmpty, isTrue);
  });

  test(
    'temporary cleanup preserves imported generated and legacy files',
    () async {
      serve();
      final legacy = File(
        path.join(
          userSubtitles.path,
          '${md5.convert(utf8.encode(audioPath))}-remote.srt',
        ),
      );
      await legacy.writeAsString(_srt('Unverified legacy'));
      final subtitles = service();
      expect((await subtitles.load(audioPath))?.cues.single.text, 'old.srt');
      final generated = await subtitles.saveDraft(
        audioPath,
        const SubtitleDraft(
          kind: SubtitleDraftKind.translation,
          sourceLanguage: 'ja',
          targetLanguage: 'en',
          cues: [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 2),
              text: 'Generated',
            ),
          ],
        ),
      );
      expect(path.isWithin(userSubtitles.path, generated.sourcePath), isTrue);
      final imported = File(path.join(directory.path, 'external.srt'));
      await imported.writeAsString(_srt('Imported'));
      final selected = await subtitles.importSubtitle(
        audioPath,
        imported.path,
        overwrite: true,
      );
      expect(selected?.cues.single.text, 'Imported');
      expect(path.isWithin(userSubtitles.path, selected!.sourcePath), isTrue);

      AppCacheService.resetForTest(
        temporaryDirectories: () async => [directory],
      );
      AppCacheService.scheduledEnforceEnabled = false;
      await AppCacheService.clearTemporaryCaches();
      expect(await File(generated.sourcePath).exists(), isTrue);
      expect(await legacy.readAsString(), _srt('Unverified legacy'));
      expect(await remoteCache.list().isEmpty, isTrue);
      expect((await service().load(audioPath))?.cues.single.text, 'Imported');
    },
  );
}

String _srt(String text) => '1\n00:00:01,000 --> 00:00:02,000\n$text\n';
