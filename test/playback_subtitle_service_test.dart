import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  test('loads, caches, and clears a local subtitle track', () async {
    final directory = await Directory.systemTemp.createTemp(
      'doujin_audio_subtitle_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final audioPath = '${directory.path}${Platform.pathSeparator}track.mp3';
    final subtitlePath = '${directory.path}${Platform.pathSeparator}track.lrc';
    await File(audioPath).writeAsBytes(const <int>[]);
    await File(subtitlePath).writeAsString('[00:01.00]first line');

    var loadedCount = 0;
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      onTrackLoaded: (_, _) => loadedCount++,
    );

    final first = await service.load(audioPath);
    final second = await service.load(audioPath);

    expect(first, isNotNull);
    expect(second, same(first));
    expect(service.trackSync(audioPath), same(first));
    expect(service.hasKnownSubtitle(audioPath), isTrue);
    expect(
      service.textAt(audioPath, const Duration(milliseconds: 1100)),
      'first line',
    );
    expect(loadedCount, 1);

    service.clear();
    expect(service.hasResult(audioPath), isFalse);
    expect(service.trackSync(audioPath), isNull);
  });

  test('clear prevents an old load from overwriting a new load', () async {
    const path = 'content://media/audio/clear-race';
    final oldTrack = SubtitleTrack(
      sourcePath: 'old.srt',
      cues: <SubtitleCue>[],
    );
    final newTrack = SubtitleTrack(
      sourcePath: 'new.srt',
      cues: <SubtitleCue>[],
    );
    final oldLoad = Completer<SubtitleTrack?>();
    final newLoad = Completer<SubtitleTrack?>();
    var calls = 0;
    final callbacks = <SubtitleTrack?>[];
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) => calls++ == 0 ? oldLoad.future : newLoad.future,
      onTrackLoaded: (_, track) => callbacks.add(track),
    );

    final oldFuture = service.load(path);
    service.clear();
    final newFuture = service.load(path);
    oldLoad.complete(oldTrack);
    expect(await oldFuture, oldTrack);
    expect(service.isLoading(path), isTrue);
    expect(service.trackSync(path), isNull);

    newLoad.complete(newTrack);
    expect(await newFuture, newTrack);
    expect(service.trackSync(path), newTrack);
    expect(callbacks, <SubtitleTrack?>[newTrack]);
  });

  test('temporary ASMR subtitle miss is not negative cached', () async {
    const path = 'https://api.asmr.one/audio.mp3';
    final loaded = SubtitleTrack(
      sourcePath: 'subtitle.vtt',
      cues: <SubtitleCue>[],
    );
    var calls = 0;
    final track = _remoteTrack(path);
    final service = PlaybackSubtitleService(
      trackResolver: (_) => track,
      subtitleLoader: (_, _) async => calls++ == 0 ? null : loaded,
    );

    expect(await service.load(path), isNull);
    expect(service.hasResult(path), isFalse);
    expect(await service.load(path), loaded);
    expect(calls, 2);
  });

  test('reports an unloaded subtitle only from track metadata', () {
    const knownPath = 'https://api.asmr.one/known.mp3';
    const unknownPath = 'https://api.asmr.one/unknown.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (path) => path == knownPath
          ? _remoteTrack(path)
          : MusicTrack(
              path: path,
              displayName: 'Unknown ASMR track',
              groupKey: 'work',
              groupTitle: 'Work',
              groupSubtitle: 'ASMR',
              isSingle: false,
              remoteMetadataKind: 'asmr.one',
              remoteMetadata: const <String, Object?>{},
            ),
    );

    expect(service.hasKnownSubtitle(knownPath), isTrue);
    expect(service.hasKnownSubtitle(unknownPath), isFalse);
  });

  test('remote subtitle stalled response respects idle timeout', () async {
    final requestStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.add(<int>[1]);
      requestStarted.complete();
    });
    addTearDown(() => server.close(force: true));
    final url = 'http://${server.address.address}:${server.port}/subtitle.vtt';

    final future = loadSubtitleTrackFromUrl(
      url: url,
      requestTimeout: const Duration(milliseconds: 100),
      downloadIdleTimeout: const Duration(milliseconds: 30),
    );
    await requestStarted.future.timeout(const Duration(seconds: 1));

    await expectLater(
      future.timeout(const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('setTrackOffset updates offset, notifies listeners, and shifts cue evaluation', () async {
    const cues = [
      SubtitleCue(
        start: Duration(seconds: 2),
        end: Duration(seconds: 4),
        text: 'hello',
      ),
    ];
    final track = SubtitleTrack(sourcePath: 'test.lrc', cues: cues);
    const audioPath = '/path/to/audio.mp3';

    var notifyCount = 0;
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) async => track,
    );

    await service.load(audioPath);
    service.addListener(() => notifyCount++);
    expect(service.getOffset(audioPath), Duration.zero);
    expect(service.textAt(audioPath, const Duration(milliseconds: 2500)), 'hello');

    // Add +1000ms offset (delay subtitle by 1s)
    await service.setTrackOffset(audioPath, const Duration(seconds: 1));
    expect(notifyCount, 1);
    expect(service.getOffset(audioPath), const Duration(seconds: 1));
    expect(service.trackSync(audioPath)?.offset, const Duration(seconds: 1));

    // At 2500ms audio position, effective subtitle position is 1500ms -> no text
    expect(service.textAt(audioPath, const Duration(milliseconds: 2500)), isNull);
    // At 3500ms audio position, effective subtitle position is 2500ms -> 'hello'
    expect(service.textAt(audioPath, const Duration(milliseconds: 3500)), 'hello');

    // Reset offset
    await service.setTrackOffset(audioPath, Duration.zero);
    expect(notifyCount, 2);
    expect(service.getOffset(audioPath), Duration.zero);
    expect(service.textAt(audioPath, const Duration(milliseconds: 2500)), 'hello');
  });

  test('importSubtitle and removeCustomSubtitle persist and update track', () async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final supportDir = await Directory.systemTemp.createTemp('sub_support_');
    final tempDir = await Directory.systemTemp.createTemp('sub_temp_');
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await supportDir.exists()) await supportDir.delete(recursive: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return supportDir.path;
          }
          return null;
        });

    final externalSub = File('${tempDir.path}/external.lrc');
    await externalSub.writeAsString('[00:01.00]external text');

    const audioPath = '/music/song.mp3';
    var notifyCount = 0;
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    service.addListener(() => notifyCount++);

    final importedTrack = await service.importSubtitle(audioPath, externalSub.path);
    expect(importedTrack, isNotNull);
    expect(notifyCount, 1);
    expect(service.hasCustomSubtitle(audioPath), isTrue);
    expect(service.getCustomSubtitlePath(audioPath), isNotNull);

    final loaded = service.trackSync(audioPath);
    expect(loaded, isNotNull);
    expect(service.textAt(audioPath, const Duration(milliseconds: 1500)), 'external text');

    // Now remove custom subtitle
    await service.removeCustomSubtitle(audioPath);
    expect(notifyCount, 2);
    expect(service.hasCustomSubtitle(audioPath), isFalse);
    expect(service.getCustomSubtitlePath(audioPath), isNull);
    expect(service.trackSync(audioPath), isNull);
  });
}

MusicTrack _remoteTrack(String path) => MusicTrack(
  path: path,
  displayName: 'ASMR track',
  groupKey: 'work',
  groupTitle: 'Work',
  groupSubtitle: 'ASMR',
  isSingle: false,
  remoteMetadataKind: 'asmr.one',
  remoteMetadata: const <String, Object?>{
    'subtitleUrl': 'https://api.asmr.one/subtitle.vtt',
  },
);
