import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/presentation/playback_position_ui_gate.dart';

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

  test(
    'automatic remote misses cool down while explicit retry stays immediate',
    () async {
      const path = 'https://api.asmr.one/audio.mp3';
      var now = DateTime(2026);
      var calls = 0;
      final service = PlaybackSubtitleService(
        trackResolver: (_) => _remoteTrack(path),
        subtitleLoader: (_, _) async {
          calls++;
          return null;
        },
        now: () => now,
      );
      addTearDown(service.dispose);

      await service.loadAutomatically(path);
      for (var tick = 0; tick < 59; tick++) {
        now = now.add(const Duration(milliseconds: 500));
        await service.loadAutomatically(path);
      }
      expect(calls, 1);
      expect(service.hasResult(path), isFalse);
      now = now.add(const Duration(milliseconds: 500));
      await service.loadAutomatically(path);
      expect(calls, 2);
      await service.load(path);
      expect(calls, 3);
      await service.loadAutomatically(path);
      expect(calls, 3);
    },
  );

  test(
    'source changes and clearing bypass automatic subtitle cooldown',
    () async {
      const path = 'https://api.asmr.one/audio.mp3';
      var track = _remoteTrack(path);
      var calls = 0;
      final service = PlaybackSubtitleService(
        trackResolver: (_) => track,
        subtitleLoader: (_, _) async {
          calls++;
          return null;
        },
        now: () => DateTime(2026),
      );
      addTearDown(service.dispose);

      await service.loadAutomatically(path);
      track = track.copyWith(
        remoteMetadata: const {
          'subtitleUrl': 'https://api.asmr.one/replacement.vtt',
        },
      );
      await service.loadAutomatically(path);
      expect(calls, 2);
      service.clear();
      await service.loadAutomatically(path);
      expect(calls, 3);
    },
  );

  test(
    'automatic and explicit subtitle consumers share an in-flight load',
    () async {
      const path = 'https://api.asmr.one/audio.mp3';
      final completed = Completer<SubtitleTrack?>();
      var calls = 0;
      final service = PlaybackSubtitleService(
        trackResolver: (_) => _remoteTrack(path),
        subtitleLoader: (_, _) {
          calls++;
          return completed.future;
        },
      );
      addTearDown(service.dispose);

      final first = service.loadAutomatically(path);
      final explicit = service.load(path);
      final automatic = service.loadAutomatically(path);
      expect(explicit, same(first));
      expect(automatic, same(first));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      final loaded = SubtitleTrack(sourcePath: 'subtitle.vtt', cues: const []);
      completed.complete(loaded);
      expect(await first, same(loaded));
      expect(await service.loadAutomatically(path), same(loaded));
      expect(calls, 1);
    },
  );

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

  test(
    'setTrackOffset updates offset, notifies listeners, and shifts cue evaluation',
    () async {
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
      expect(
        service.textAt(audioPath, const Duration(milliseconds: 2500)),
        'hello',
      );

      // Add +1000ms offset (delay subtitle by 1s)
      await service.setTrackOffset(audioPath, const Duration(seconds: 1));
      expect(notifyCount, 1);
      expect(service.getOffset(audioPath), const Duration(seconds: 1));
      expect(service.trackSync(audioPath)?.offset, const Duration(seconds: 1));

      // At 2500ms audio position, effective subtitle position is 1500ms -> no text
      expect(
        service.textAt(audioPath, const Duration(milliseconds: 2500)),
        isNull,
      );
      // At 3500ms audio position, effective subtitle position is 2500ms -> 'hello'
      expect(
        service.textAt(audioPath, const Duration(milliseconds: 3500)),
        'hello',
      );

      // Reset offset
      await service.setTrackOffset(audioPath, Duration.zero);
      expect(notifyCount, 2);
      expect(service.getOffset(audioPath), Duration.zero);
      expect(
        service.textAt(audioPath, const Duration(milliseconds: 2500)),
        'hello',
      );
    },
  );

  test('importSubtitle moves and renames the file beside the audio', () async {
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

    final audioPath = '${supportDir.path}/song.mp3';
    await File(audioPath).writeAsBytes([]);
    var notifyCount = 0;
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    service.addListener(() => notifyCount++);

    final importedTrack = await service.importSubtitle(
      audioPath,
      externalSub.path,
    );
    expect(importedTrack, isNotNull);
    expect(notifyCount, 1);

    final loaded = service.trackSync(audioPath);
    expect(loaded, isNotNull);
    expect(
      service.textAt(audioPath, const Duration(milliseconds: 1500)),
      'external text',
    );

    final customPath = importedTrack!.sourcePath;
    expect(await File(customPath).readAsString(), contains('external text'));
    expect(importedTrack.sourcePath, customPath);
    expect(importedTrack.sourcePath, isNot(externalSub.path));
    expect(path.basename(customPath), 'song.lrc');
    expect(await externalSub.exists(), isFalse);
    final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
    expect(
      (await restarted.load(audioPath))?.cues.single.text,
      'external text',
    );
  });

  test('SAF subtitles retain their original document URI', () async {
    final directory = await Directory.systemTemp.createTemp('saf_subtitles_');
    addTearDown(() => directory.delete(recursive: true));
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      fileCacheGateway: _ContentSubtitleGateway(),
      subtitlesDirectoryResolver: () async => directory,
    );
    final loaded = await service.load('content://media/audio/1');
    expect(loaded?.cues.single.text, 'ローカル字幕');
    expect(loaded?.sourcePath, 'content://media/subtitle/1');
    expect(await directory.list().isEmpty, isTrue);
  });

  test(
    'persistent cueAt and textAt hold subtitle text across gaps between cues',
    () async {
      const cues = [
        SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 5),
          text: 'First line',
        ),
        SubtitleCue(
          start: Duration(seconds: 15),
          end: Duration(seconds: 20),
          text: 'Second line',
        ),
      ];
      final track = SubtitleTrack(sourcePath: 'gap.vtt', cues: cues);
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (_, _) async => track,
      );
      await service.load('gap.mp3');

      // Before first cue
      expect(service.textAt('gap.mp3', const Duration(seconds: 1)), isNull);
      expect(
        service.textAt('gap.mp3', const Duration(seconds: 1), persistent: true),
        isNull,
      );
      expect(track.cueAt(const Duration(seconds: 1)), isNull);
      expect(track.cueAt(const Duration(seconds: 1), persistent: true), isNull);

      // During first cue
      expect(track.cueAt(const Duration(seconds: 3))?.text, 'First line');
      expect(
        track.cueAt(const Duration(seconds: 3), persistent: true)?.text,
        'First line',
      );

      // In the gap between cue 1 and cue 2 (at 10s)
      // Non-persistent returns null
      expect(service.textAt('gap.mp3', const Duration(seconds: 10)), isNull);
      expect(track.cueAt(const Duration(seconds: 10)), isNull);
      // Persistent holds the first line
      expect(
        service.textAt(
          'gap.mp3',
          const Duration(seconds: 10),
          persistent: true,
        ),
        'First line',
      );
      expect(
        track.cueAt(const Duration(seconds: 10), persistent: true)?.text,
        'First line',
      );

      // During second cue (at 16s)
      expect(track.cueAt(const Duration(seconds: 16))?.text, 'Second line');
      expect(
        track.cueAt(const Duration(seconds: 16), persistent: true)?.text,
        'Second line',
      );

      // After second cue (at 25s)
      // Non-persistent returns null
      expect(track.cueAt(const Duration(seconds: 25)), isNull);
      // Persistent holds the second line until track ends
      expect(
        track.cueAt(const Duration(seconds: 25), persistent: true)?.text,
        'Second line',
      );

      // SubtitleTextCache tests
      final cache = SubtitleTextCache();
      expect(
        cache.resolve(
          trackPath: 'audio.mp3',
          position: const Duration(seconds: 1),
          track: track,
          persistent: true,
        ),
        isNull,
      );
      expect(
        cache.resolve(
          trackPath: 'audio.mp3',
          position: const Duration(seconds: 3),
          track: track,
          persistent: true,
        ),
        'First line',
      );
      // In the gap (at 10s), text persists
      expect(
        cache.resolve(
          trackPath: 'audio.mp3',
          position: const Duration(seconds: 10),
          track: track,
          persistent: true,
        ),
        'First line',
      );
      // Reaching cue 2 (at 16s), updates to second line
      expect(
        cache.resolve(
          trackPath: 'audio.mp3',
          position: const Duration(seconds: 16),
          track: track,
          persistent: true,
        ),
        'Second line',
      );
      // After cue 2 (at 25s), persists second line
      expect(
        cache.resolve(
          trackPath: 'audio.mp3',
          position: const Duration(seconds: 25),
          track: track,
          persistent: true,
        ),
        'Second line',
      );
    },
  );

  test('editing a subtitle writes the source and updates playback', () async {
    final directory = await Directory.systemTemp.createTemp('edited_subtitle_');
    addTearDown(() => directory.delete(recursive: true));
    final original = File('${directory.path}/original.srt');
    await original.writeAsString(
      '1\n00:00:01,000 --> 00:00:02,000\nOriginal\n',
    );
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) async => SubtitleTrack(
        sourcePath: original.path,
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: 'Original',
          ),
        ],
      ),
      subtitlesDirectoryResolver: () async => directory,
    );
    const audioPath = '/music/original.mp3';
    await service.load(audioPath);
    await expectLater(
      service.saveEditedSubtitle(audioPath, [
        const SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 1),
          text: 'Invalid',
        ),
      ]),
      throwsArgumentError,
    );
    final edited = await service.saveEditedSubtitle(audioPath, [
      const SubtitleCue(
        start: Duration(milliseconds: 1500),
        end: Duration(milliseconds: 2800),
        text: 'Edited\nTranslated',
      ),
    ]);
    expect(edited.sourcePath, original.path);
    expect(await original.readAsString(), isNot(contains('Original')));
    expect(
      await File(edited.sourcePath).readAsString(),
      contains('Edited\nTranslated'),
    );
    expect(
      service.textAt(audioPath, const Duration(seconds: 2)),
      'Edited\nTranslated',
    );
  });

  test('ASMR.ONE subtitles cannot be edited or saved', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_edit_');
    addTearDown(() => directory.delete(recursive: true));
    const audioPath = 'https://example.com/asmr.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (_) => _remoteTrack(audioPath),
      subtitlesDirectoryResolver: () async => directory,
    );
    expect(service.canEditSubtitle(audioPath), isFalse);
    await expectLater(
      service.saveEditedSubtitle(audioPath, const [
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 2),
          text: 'Changed',
        ),
      ]),
      throwsStateError,
    );
    expect(await directory.list().isEmpty, isTrue);
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

class _ContentSubtitleGateway extends FileCachePlatformGateway {
  @override
  Future<Map<String, Object?>?> resolveTrackSubtitle({
    required String path,
    String? groupKey,
  }) async => {
    'sourcePath': 'content://media/subtitle/1',
    'extension': '.lrc',
    'text': '[00:01.00]ローカル字幕',
  };
}
