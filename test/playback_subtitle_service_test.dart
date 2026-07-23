import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/core/media/subtitle_parser.dart';
import 'package:nameless_audio/features/player/application/playback_subtitle_service.dart';

void main() {
  test('loads, caches, and clears a local subtitle track', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nameless_audio_subtitle_',
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
