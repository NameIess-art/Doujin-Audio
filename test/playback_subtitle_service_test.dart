import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
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
    var sourceLookups = 0;
    final service = PlaybackSubtitleService(
      trackResolver: (_) {
        sourceLookups++;
        return null;
      },
      onTrackLoaded: (_, _) => loadedCount++,
    );

    expect(
      await service.hasLocalSubtitleFile(audioPath, includeImported: true),
      isTrue,
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

    sourceLookups = 0;
    final sample = service.readPlaybackSubtitle(
      audioPath,
      const Duration(milliseconds: 1100),
    );
    expect(sample.text, 'first line');
    expect(sample.loading, isNull);
    expect(sourceLookups, 1);

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
      final availabilityRevision = service.availabilityRevision;
      expect(availabilityRevision, greaterThan(0));
      service.addListener(() => notifyCount++);
      expect(service.getOffset(audioPath), Duration.zero);
      expect(
        service.textAt(audioPath, const Duration(milliseconds: 2500)),
        'hello',
      );

      // Add +1000ms offset (delay subtitle by 1s)
      await service.setTrackOffset(audioPath, const Duration(seconds: 1));
      expect(notifyCount, 1);
      expect(service.availabilityRevision, availabilityRevision);
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
    expect(
      await service.hasLocalSubtitleFile(
        'content://media/audio/1',
        includeImported: true,
      ),
      isTrue,
    );
    final loaded = await service.load('content://media/audio/1');
    expect(loaded?.cues.single.text, 'ローカル字幕');
    expect(loaded?.sourcePath, 'content://media/subtitle/1');
    expect(await directory.list().isEmpty, isTrue);
  });

  test('SAF subtitle save reopens an externally changed document', () async {
    final gateway = _ContentSubtitleGateway();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      fileCacheGateway: gateway,
    );
    addTearDown(service.dispose);
    const audioPath = 'content://media/audio/1';
    final loaded = (await service.loadForEditing(audioPath))!;
    gateway.text = '[00:02.00]External update';
    await expectLater(
      service.saveEditedSubtitle(audioPath, loaded.cues, source: loaded),
      throwsA(isA<SubtitleSourceChanged>()),
    );
    expect(gateway.text, '[00:02.00]External update');

    final reopened = (await service.loadForEditing(audioPath))!;
    final cue = reopened.cues.single;
    await service.saveEditedSubtitle(audioPath, [
      SubtitleCue(start: cue.start, end: cue.end, text: 'Saved after reopen'),
    ], source: reopened);
    expect(gateway.text, contains('[00:02.000]Saved after reopen'));
  });

  test('offset copies share the time index even before first lookup', () {
    var comparisons = 0;
    final track = SubtitleTrack(
      sourcePath: 'index.srt',
      cues: [
        for (var i = 1000; i >= 0; i--)
          SubtitleCue(
            start: _CountingDuration(i, () => comparisons++),
            end: Duration(seconds: i + 1),
            text: '$i',
          ),
      ],
    );
    final shifted = track.withOffset(const Duration(seconds: 2));
    expect(shifted.cueAt(const Duration(seconds: 502))?.text, '500');
    expect(comparisons, greaterThan(0));
    final builtComparisons = comparisons;
    expect(track.cueAt(const Duration(seconds: 500))?.text, '500');
    for (var i = 0; i < 100; i++) {
      expect(
        track
            .withOffset(Duration(seconds: i))
            .cueAt(Duration(seconds: 500 + i))
            ?.text,
        '500',
      );
    }
    expect(comparisons, builtComparisons);
    expect(identical(track.cues, shifted.cues), isTrue);
    expect(track.cues.first.text, '1000');
  });

  test('equal start cues retain source tie order across offsets', () {
    final track = SubtitleTrack(
      sourcePath: 'ties.ass',
      cues: const [
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 8),
          text: 'long',
        ),
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'short',
        ),
      ],
    );
    expect(track.cueAt(const Duration(seconds: 2))?.text, 'short');
    expect(track.cueAt(const Duration(seconds: 4))?.text, 'long');
    final shifted = track.withOffset(const Duration(seconds: -1));
    expect(shifted.cueAt(const Duration(seconds: 1))?.text, 'short');
    expect(shifted.cueAt(const Duration(seconds: 3))?.text, 'long');
    expect(
      shifted.cueAt(const Duration(seconds: 9), persistent: true)?.text,
      'short',
    );
  });

  test('subtitle time lookup handles out-of-order ASS dialogue', () async {
    final track = await parseSubtitleTrackFromRaw(
      sourcePath: 'unordered.ass',
      extension: '.ass',
      raw:
          '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:10.00,0:00:12.00,Later,,0,0,0,,later\n'
          'Dialogue: 0,0:00:01.00,0:00:03.00,Early,,0,0,0,,early\n',
    );
    expect(track, isNotNull);
    // Editing maps ASS styles to the source dialogue order.
    expect(track!.cues.map((cue) => cue.text), ['later', 'early']);
    expect(track.cueAt(const Duration(seconds: 2))?.text, 'early');
    expect(track.cueAt(const Duration(seconds: 11))?.text, 'later');
    expect(
      track.cueAt(const Duration(seconds: 5), persistent: true)?.text,
      'early',
    );
    expect(track.cueAt(Duration.zero, persistent: true), isNull);
  });

  test('subtitle time lookup finds a longer overlapping SRT cue', () async {
    final track = await parseSubtitleTrackFromRaw(
      sourcePath: 'overlap.srt',
      extension: '.srt',
      raw:
          '1\n00:00:00,000 --> 00:00:10,000\nlong\n\n'
          '2\n00:00:01,000 --> 00:00:02,000\nshort\n\n'
          '3\n00:00:12,000 --> 00:00:14,000\nnext\n',
    );
    expect(track, isNotNull);
    expect(track!.cueAt(const Duration(milliseconds: 1500))?.text, 'short');
    expect(track.cueAt(const Duration(seconds: 3))?.text, 'long');
    expect(track.cueAt(const Duration(seconds: 10)), isNull);
    expect(track.cueAt(const Duration(seconds: 12))?.text, 'next');
    expect(
      track.cueAt(const Duration(seconds: 11), persistent: true)?.text,
      'short',
    );
    expect(
      track
          .withOffset(const Duration(seconds: 2))
          .cueAt(const Duration(seconds: 5))
          ?.text,
      'long',
    );
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

  for (final extension in ['ass', 'ssa']) {
    test('$extension edits keep surviving event styles and tags', () async {
      final directory = await Directory.systemTemp.createTemp('edited_ass_');
      addTearDown(() => directory.delete(recursive: true));
      final audioPath = path.join(directory.path, 'original.mp3');
      await File(audioPath).create();
      final source = File(path.join(directory.path, 'original.$extension'));
      const second =
          r'Dialogue: 0,0:00:03.00,0:00:04.00,Blue,Bob,42,{\pos(20,30)}Second, with a comma';
      await source.writeAsString(
        '[Events]\nFormat: Layer,Start,End,Style,Name,MarginL,Text\n'
        'Dialogue: 0,0:00:01.00,0:00:02.00,Red,Alice,12,First\n'
        '$second\n',
      );
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      addTearDown(service.dispose);
      final loaded = (await service.load(audioPath))!;
      final edited = await service.saveEditedSubtitle(audioPath, [
        loaded.cues[1],
      ]);
      expect(await source.readAsString(), contains(second));
      expect(await source.readAsString(), isNot(contains('Red,Alice')));

      final surviving = edited.cues.single;
      final withInsertion = await service.saveEditedSubtitle(audioPath, [
        const SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 3),
          text: 'Inserted',
        ),
        SubtitleCue(
          start: const Duration(milliseconds: 3200),
          end: surviving.end,
          text: surviving.text,
          assSourceLine: surviving.assSourceLine,
        ),
      ]);
      expect(withInsertion.cues.map((cue) => cue.text), [
        'Inserted',
        'Second, with a comma',
      ]);
      expect(
        await source.readAsString(),
        contains(r'Blue,Bob,42,{\pos(20,30)}Second, with a comma'),
      );
      expect((await service.saveEditedSubtitle(audioPath, [])).cues, isEmpty);
      expect(await source.readAsString(), contains('Format: Layer'));
    });
  }

  for (final (extension, original) in [
    (
      'ass',
      '[Events]\nFormat: Layer,Start,End,Style,Text\n'
          'Dialogue: 0,0:00:10.00,0:00:12.00,Later,First row\n'
          'Dialogue: 0,0:00:01.00,0:00:03.00,Earlier,Second row\n',
    ),
    (
      'srt',
      '1\n00:00:01,000 --> 00:00:04,000\nFirst row\n\n'
          '2\n00:00:03,000 --> 00:00:06,000\nSecond row\n',
    ),
  ]) {
    test('$extension text edits preserve the existing timeline', () async {
      final directory = await Directory.systemTemp.createTemp('subtitle_edit_');
      addTearDown(() => directory.delete(recursive: true));
      final audioPath = path.join(directory.path, 'original.mp3');
      await File(audioPath).create();
      final file = File(path.join(directory.path, 'original.$extension'));
      await file.writeAsString(original);
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      addTearDown(service.dispose);
      final loaded = (await service.loadForEditing(audioPath))!;
      final first = loaded.cues.first;
      final edited = await service.saveEditedSubtitle(audioPath, [
        SubtitleCue(
          start: first.start,
          end: first.end,
          text: 'Edited first row',
          assSourceLine: first.assSourceLine,
        ),
        loaded.cues.last,
      ], source: loaded);

      expect(loaded.hasSameCueTimings(edited.cues), isTrue);
      expect(edited.cues.map((cue) => cue.text), [
        'Edited first row',
        'Second row',
      ]);
      expect(await file.readAsString(), contains('Edited first row'));
    });

    test('$extension save rejects a draft after an external change', () async {
      final directory = await Directory.systemTemp.createTemp('subtitle_edit_');
      addTearDown(() => directory.delete(recursive: true));
      final audioPath = path.join(directory.path, 'original.mp3');
      await File(audioPath).create();
      final file = File(path.join(directory.path, 'original.$extension'));
      await file.writeAsString(original);
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      addTearDown(service.dispose);
      final loaded = (await service.loadForEditing(audioPath))!;
      final externallyEdited = original.replaceFirst('Second row', 'New text');
      await file.writeAsString(externallyEdited);
      await expectLater(
        service.saveEditedSubtitle(audioPath, loaded.cues, source: loaded),
        throwsA(isA<SubtitleSourceChanged>()),
      );
      expect(await file.readAsString(), externallyEdited);

      final reopened = (await service.loadForEditing(audioPath))!;
      expect(reopened.cues.last.text, 'New text');
      expect(reopened.sourceRevision, isNot(loaded.sourceRevision));
      expect(
        await service.saveEditedSubtitle(
          audioPath,
          reopened.cues,
          source: reopened,
        ),
        isNotNull,
      );
    });
  }

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

  test('subtitle cache evicts least-recently-used track beyond capacity', () async {
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (trackPath, _) async => SubtitleTrack(
        sourcePath: '$trackPath.srt',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: 'line',
          ),
        ],
      ),
    );
    addTearDown(service.dispose);

    for (var i = 0; i < 20; i++) {
      await service.load('/audio/$i.mp3');
    }
    // Touch track 0 so track 1 becomes the least-recently-used entry.
    expect(service.trackSync('/audio/0.mp3'), isNotNull);

    await service.load('/audio/20.mp3');

    expect(service.hasResult('/audio/0.mp3'), isTrue);
    expect(service.hasResult('/audio/1.mp3'), isFalse);
    expect(service.hasResult('/audio/20.mp3'), isTrue);
  });

  test('setTrackOffset debounces persistence and flushes on dispose', () async {
    const audioPath = '/path/to/debounce.mp3';
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    await service.setTrackOffset(audioPath, const Duration(milliseconds: 100));
    await service.setTrackOffset(audioPath, const Duration(milliseconds: 200));
    await service.setTrackOffset(audioPath, const Duration(milliseconds: 300));
    final prefsBeforeFlush = await SharedPreferences.getInstance();
    expect(prefsBeforeFlush.getStringList('subtitle_track_offsets'), isNull);

    service.dispose();
    await Future<void>.delayed(Duration.zero);
    final prefsAfterDispose = await SharedPreferences.getInstance();
    expect(prefsAfterDispose.getStringList('subtitle_track_offsets'), [
      '$audioPath|300',
    ]);
  });

  test(
    'PlaybackSubtitleService normalizes Windows path case and separators for offsets and cache',
    () async {
      const canonical = r'C:\Media\WorkA\Track01.mp3';
      const lowerSlash = 'c:/media/worka/track01.mp3';
      const upperBackslash = r'C:\MEDIA\WORKA\TRACK01.MP3';
      var loads = 0;
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (trackPath, _) async {
          loads++;
          return SubtitleTrack(
            sourcePath: r'C:\Media\WorkA\Track01.lrc',
            cues: const <SubtitleCue>[
              SubtitleCue(
                start: Duration(seconds: 1),
                end: Duration(seconds: 3),
                text: 'hello',
              ),
            ],
          );
        },
      );
      addTearDown(service.dispose);

      await service.setTrackOffset(
        canonical,
        const Duration(milliseconds: 250),
      );
      expect(service.getOffset(lowerSlash), const Duration(milliseconds: 250));
      expect(
        service.getOffset(upperBackslash),
        const Duration(milliseconds: 250),
      );

      final loaded = await service.load(canonical);
      expect(loaded, isNotNull);
      expect(loads, 1);
      expect(service.hasResult(lowerSlash), isTrue);
      expect(service.trackSync(upperBackslash), same(loaded));
      expect(await service.load(lowerSlash), same(loaded));
      expect(loads, 1);
    },
  );

  test(
    'PlaybackSubtitleService.dispose cancels running generation job without throwing after dispose',
    () async {
      final dir = await Directory.systemTemp.createTemp('sub_dispose_gen_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final audioFile = File('${dir.path}/track.mp3');
      await audioFile.writeAsBytes(const <int>[0]);
      final scriptFile = File('${dir.path}/script.txt');
      await scriptFile.writeAsString('line one\nline two');

      final started = Completer<void>();
      final release = Completer<void>();
      void Function(SubtitleTaskProgress)? capturedProgress;
      Future<void>? capturedCancellation;
      final aiEngine = _BlockingSubtitleAiEngine(
        onGenerate: (onProgress, cancellation) async {
          capturedProgress = onProgress;
          capturedCancellation = cancellation;
          if (!started.isCompleted) started.complete();
          await release.future;
          return const SubtitleDraft(
            kind: SubtitleDraftKind.script,
            sourceLanguage: 'ja',
            cues: <SubtitleCue>[
              SubtitleCue(
                start: Duration(seconds: 1),
                end: Duration(seconds: 2),
                text: 'line one',
              ),
            ],
          );
        },
      );
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        aiEngine: aiEngine,
      );
      final startedOk = service.startScriptGeneration(
        audioFile.path,
        scriptFile.path,
      );
      expect(startedOk, isTrue);
      await started.future;
      expect(service.generationJob?.status, SubtitleGenerationStatus.running);

      service.dispose();

      // Cancellation signal should fire immediately on dispose.
      await capturedCancellation!.timeout(const Duration(seconds: 1));
      expect(service.generationJob?.cancellationRequested, isTrue);
      // Late progress & completion callbacks must not throw FlutterError.
      expect(
        () => capturedProgress?.call(
          const SubtitleTaskProgress('aligning', 0.5, ''),
        ),
        returnsNormally,
      );
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.generationJob?.status, SubtitleGenerationStatus.cancelled);
    },
  );
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

class _CountingDuration extends Duration {
  _CountingDuration(int seconds, this.onCompare) : super(seconds: seconds);
  final void Function() onCompare;

  @override
  int compareTo(Duration other) {
    onCompare();
    return super.compareTo(other);
  }
}

class _ContentSubtitleGateway extends FileCachePlatformGateway {
  String text = '[00:01.00]ローカル字幕';

  @override
  Future<Map<String, Object?>?> resolveTrackSubtitle({
    required String path,
    String? groupKey,
  }) async => {
    'sourcePath': 'content://media/subtitle/1',
    'extension': '.lrc',
    'text': text,
  };

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async =>
      utf8.encode(text);

  @override
  Future<bool> writeTrackSubtitle({
    required String path,
    required Uint8List bytes,
  }) async {
    text = utf8.decode(bytes);
    return true;
  }
}

final class _BlockingSubtitleAiEngine extends SubtitleAiEngine {
  _BlockingSubtitleAiEngine({required this.onGenerate});

  final Future<SubtitleDraft?> Function(
    void Function(SubtitleTaskProgress)? onProgress,
    Future<void>? cancellation,
  )
  onGenerate;

  @override
  Future<SubtitleDraft?> prepareScript(
    String trackPath,
    String scriptPath, {
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) => onGenerate(onProgress, cancellation);
}
