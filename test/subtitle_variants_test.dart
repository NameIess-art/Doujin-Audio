import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late Directory directory;
  late String audio;
  late File original;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('subtitle_variants_');
    audio = path.join(directory.path, 'voice.mp3');
    await File(audio).writeAsBytes([]);
    original = File(path.join(directory.path, 'voice.srt'));
    await original.writeAsString(_srt('Original'));
  });
  tearDown(() => directory.delete(recursive: true));

  PlaybackSubtitleService service({FileCachePlatformGateway? gateway}) {
    final result = PlaybackSubtitleService(
      trackResolver: (_) => null,
      fileCacheGateway: gateway,
      subtitlesDirectoryResolver: () async => directory,
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'translations from different sources and languages preserve every file',
    () async {
      final subtitles = service();
      final alternate = File(path.join(directory.path, 'voice.ja.srt'));
      await alternate.writeAsString(_srt('Other original'));
      final originalBytes = await original.readAsBytes();
      final alternateBytes = await alternate.readAsBytes();

      await subtitles.load(audio);
      final first = await subtitles.saveDraft(audio, _draft('First'));
      await subtitles.selectSubtitleFile(audio, alternate.path);
      final second = await subtitles.saveDraft(audio, _draft('Second'));
      final third = await subtitles.saveDraft(audio, _draft('Third'));
      final english = await subtitles.saveDraft(audio, _draft('English', 'en'));

      expect(path.basename(first.sourcePath), 'voice.mp3.translated.zh-CN.srt');
      expect(
        path.basename(second.sourcePath),
        'voice.mp3.translated.zh-CN.2.srt',
      );
      expect(
        path.basename(third.sourcePath),
        'voice.mp3.translated.zh-CN.3.srt',
      );
      expect(path.basename(english.sourcePath), 'voice.mp3.translated.en.srt');
      expect(await original.readAsBytes(), originalBytes);
      expect(await alternate.readAsBytes(), alternateBytes);
      for (final entry in [
        (first, 'First'),
        (second, 'Second'),
        (third, 'Third'),
        (english, 'English'),
      ]) {
        expect(
          await File(entry.$1.sourcePath).readAsString(),
          contains(entry.$2),
        );
        expect(entry.$1.cues.single.start, const Duration(seconds: 1));
        expect(entry.$1.cues.single.end, const Duration(seconds: 2));
      }
      expect(subtitles.trackSync(audio)?.sourcePath, english.sourcePath);
      final candidates = await subtitles.availableSubtitleFiles(audio);
      expect(
        candidates.map((item) => item.sourcePath),
        containsAll([
          original.path,
          alternate.path,
          first.sourcePath,
          second.sourcePath,
          third.sourcePath,
          english.sourcePath,
        ]),
      );
    },
  );

  test(
    'same-stem audio extensions do not share translated files or candidates',
    () async {
      final wav = path.join(directory.path, 'voice.wav');
      await File(wav).writeAsBytes([]);
      final subtitles = service();
      final mp3Result = await subtitles.saveDraft(audio, _draft('MP3'));
      final wavResult = await subtitles.saveDraft(wav, _draft('WAV'));

      expect(
        path.basename(wavResult.sourcePath),
        'voice.wav.translated.zh-CN.srt',
      );
      expect(wavResult.sourcePath, isNot(mp3Result.sourcePath));
      expect(await File(mp3Result.sourcePath).readAsString(), contains('MP3'));
      expect(await File(wavResult.sourcePath).readAsString(), contains('WAV'));
      expect(
        (await subtitles.availableSubtitleFiles(
          audio,
        )).map((item) => item.sourcePath),
        isNot(contains(wavResult.sourcePath)),
      );
      expect(
        (await subtitles.availableSubtitleFiles(
          wav,
        )).map((item) => item.sourcePath),
        isNot(contains(mp3Result.sourcePath)),
      );
    },
  );

  test(
    'switching retains per-audio offset and selected file across restart',
    () async {
      final subtitles = service();
      await subtitles.load(audio);
      await subtitles.setTrackOffset(audio, const Duration(milliseconds: 500));
      final translated = await subtitles.saveDraft(audio, _draft('Translated'));
      expect(translated.offset, const Duration(milliseconds: 500));
      final selectedOriginal = await subtitles.selectSubtitleFile(
        audio,
        original.path,
      );
      expect(selectedOriginal.offset, const Duration(milliseconds: 500));
      expect(subtitles.trackSync(audio)?.cues.single.text, 'Original');
      await subtitles.selectSubtitleFile(audio, translated.sourcePath);

      final restarted = service();
      final restored = await restarted.load(audio);
      expect(restored?.sourcePath, translated.sourcePath);
      expect(restored?.offset, const Duration(milliseconds: 500));
      expect(restored?.cues.single.text, 'Source\nTranslated');
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getStringList('subtitle_custom_paths'),
        contains('$audio|${translated.sourcePath}'),
      );
    },
  );

  test(
    'missing selection falls back to original and clears stale association',
    () async {
      final subtitles = service();
      final selected = await subtitles.saveDraft(audio, _draft('Selected'));
      final remaining = await subtitles.saveDraft(
        audio,
        _draft('Other version'),
      );
      await subtitles.selectSubtitleFile(audio, selected.sourcePath);
      await File(selected.sourcePath).delete();

      final restarted = service();
      expect((await restarted.load(audio))?.sourcePath, original.path);
      expect(
        await File(remaining.sourcePath).readAsString(),
        contains('Other version'),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getStringList('subtitle_custom_paths') ?? [],
        isNot(contains('$audio|${selected.sourcePath}')),
      );
    },
  );

  test(
    'automatic loading never picks translated versions without a selection',
    () async {
      final subtitles = service();
      final translated = await subtitles.saveDraft(audio, _draft('Translated'));
      await original.delete();
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove('subtitle_custom_paths');

      final restarted = service();
      expect(await restarted.load(audio), isNull);
      expect(
        (await restarted.availableSubtitleFiles(
          audio,
        )).map((item) => item.sourcePath),
        contains(translated.sourcePath),
      );
    },
  );

  test(
    'remote choices include cached original and all independent versions',
    () async {
      const remoteAudio = 'https://example.com/audio/voice.mp3';
      final cachedOriginal = File(
        path.join(
          directory.path,
          '${md5.convert(utf8.encode(remoteAudio))}-remote.srt',
        ),
      );
      await cachedOriginal.writeAsString(_srt('Remote original'));
      PlaybackSubtitleService remoteService() {
        final result = PlaybackSubtitleService(
          trackResolver: (_) => MusicTrack(
            path: remoteAudio,
            displayName: 'Voice',
            groupKey: 'work',
            groupTitle: 'Work',
            groupSubtitle: 'ASMR',
            isSingle: false,
            remoteMetadataKind: 'asmr.one',
            remoteMetadata: const {
              'subtitleUrl': 'https://example.com/subtitle.srt',
              'subtitleExtension': '.srt',
            },
          ),
          subtitlesDirectoryResolver: () async => directory,
        );
        addTearDown(result.dispose);
        return result;
      }

      final subtitles = remoteService();
      expect(
        (await subtitles.load(remoteAudio))?.sourcePath,
        cachedOriginal.path,
      );
      final chinese = await subtitles.saveDraft(remoteAudio, _draft('Chinese'));
      final english = await subtitles.saveDraft(
        remoteAudio,
        _draft('English', 'en'),
      );
      final repeated = await subtitles.saveDraft(
        remoteAudio,
        _draft('Repeated'),
      );
      final candidates = await subtitles.availableSubtitleFiles(remoteAudio);
      expect(
        candidates.map((item) => item.sourcePath),
        containsAll([
          cachedOriginal.path,
          chinese.sourcePath,
          english.sourcePath,
          repeated.sourcePath,
        ]),
      );
      expect(
        candidates.map((item) => item.name),
        contains('voice.mp3.translated.zh-CN.2.srt'),
      );
      await subtitles.selectSubtitleFile(remoteAudio, cachedOriginal.path);
      expect(
        (await remoteService().load(remoteAudio))?.sourcePath,
        cachedOriginal.path,
      );
      expect(await cachedOriginal.readAsString(), _srt('Remote original'));
      expect(
        await File(chinese.sourcePath).readAsString(),
        contains('Chinese'),
      );
    },
  );

  test(
    'cancelled late save cannot change current subtitle association',
    () async {
      final gateway = _ControlledSaveGateway();
      final subtitles = service(gateway: gateway);
      await subtitles.load(audio);
      var cancelled = false;
      final result = subtitles.saveDraft(
        audio,
        _draft('Late'),
        isCancelled: () => cancelled,
      );
      final assertion = expectLater(
        result,
        throwsA(isA<SubtitleTaskCancelled>()),
      );
      await gateway.started.future;
      cancelled = true;
      gateway.release.complete();
      await assertion;

      expect(subtitles.trackSync(audio)?.sourcePath, original.path);
      expect(await original.readAsString(), _srt('Original'));
      expect((await service().load(audio))?.sourcePath, original.path);
    },
  );

  test(
    'write failure preserves previous selected translation and original',
    () async {
      final subtitles = service();
      final selected = await subtitles.saveDraft(audio, _draft('Selected'));
      final failing = service(gateway: _ControlledSaveGateway(fail: true));
      expect((await failing.load(audio))?.sourcePath, selected.sourcePath);
      await expectLater(
        failing.saveDraft(audio, _draft('Failed')),
        throwsStateError,
      );
      expect(failing.trackSync(audio)?.sourcePath, selected.sourcePath);
      expect((await service().load(audio))?.sourcePath, selected.sourcePath);
      expect(await original.readAsString(), _srt('Original'));
      expect(
        await File(selected.sourcePath).readAsString(),
        contains('Selected'),
      );
    },
  );

  test(
    'case-insensitive filename collisions preserve existing content',
    () async {
      final existing = File(
        path.join(directory.path, 'VOICE.MP3.TRANSLATED.ZH-CN.SRT'),
      );
      await existing.writeAsString(_srt('Existing'));
      final saved = await service().saveDraft(audio, _draft('New'));
      expect(
        path.basename(saved.sourcePath),
        'voice.mp3.translated.zh-CN.2.srt',
      );
      expect(await existing.readAsString(), _srt('Existing'));
    },
  );

  test(
    'paths with Unicode and spaces preserve names and restart selection',
    () async {
      final folder = Directory(
        path.join(directory.path, '\u4f5c\u54c1 library'),
      );
      await folder.create();
      final unicodeAudio = path.join(folder.path, '\u97f3\u8f68 01.mp3');
      await File(unicodeAudio).writeAsBytes([]);
      final source = File(path.join(folder.path, '\u97f3\u8f68 01.srt'));
      await source.writeAsString(_srt('Original'));
      final translated = await service().saveDraft(
        unicodeAudio,
        _draft('Translated'),
      );
      expect(
        path.basename(translated.sourcePath),
        '\u97f3\u8f68 01.mp3.translated.zh-CN.srt',
      );
      expect(path.dirname(translated.sourcePath), folder.path);
      expect(
        (await service().load(unicodeAudio))?.sourcePath,
        translated.sourcePath,
      );
      expect(await source.readAsString(), _srt('Original'));
    },
  );

  test(
    'concurrent create-only saves cannot claim the same destination',
    () async {
      final gateway = FileCachePlatformGateway();
      final saved = await Future.wait([
        for (final text in ['First', 'Second', 'Third'])
          gateway.saveTrackSubtitle(
            trackPath: audio,
            extension: '.srt',
            bytes: Uint8List.fromList(utf8.encode(_srt(text))),
            createNew: true,
            fileNameSuffix: '.translated.zh-CN',
          ),
      ]);
      expect(saved.toSet(), hasLength(3));
      expect(saved, isNot(contains(null)));
      final contents = await Future.wait(
        saved.map((file) => File(file!).readAsString()),
      );
      expect(
        contents,
        unorderedEquals([_srt('First'), _srt('Second'), _srt('Third')]),
      );
      expect(await original.readAsString(), _srt('Original'));
    },
  );

  test(
    'SAF subtitle candidates and selection survive restart without moving files',
    () async {
      const safAudio = 'content://provider/tree/root/document/root%2Fvoice.mp3';
      final gateway = _SafChoicesGateway();
      final subtitles = service(gateway: gateway);
      expect(
        (await subtitles.load(safAudio))?.sourcePath,
        _SafChoicesGateway.original,
      );
      final candidates = await subtitles.availableSubtitleFiles(safAudio);
      expect(
        candidates.map((item) => item.name),
        unorderedEquals(['voice.srt', 'voice.mp3.translated.en.srt']),
      );
      final selected = await subtitles.selectSubtitleFile(
        safAudio,
        _SafChoicesGateway.translated,
      );
      expect(selected.cues.single.text, 'Translated');
      expect(
        (await service(gateway: gateway).load(safAudio))?.sourcePath,
        _SafChoicesGateway.translated,
      );
      expect(gateway.content, {
        _SafChoicesGateway.original: _srt('Original'),
        _SafChoicesGateway.translated: _srt('Translated'),
      });
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getStringList('subtitle_custom_paths'),
        contains('$safAudio|${_SafChoicesGateway.translated}'),
      );
    },
  );

  test(
    'failed selection persistence restores previous committed association',
    () async {
      final preferences = _FailingPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final subtitles = service();
      final selected = await subtitles.saveDraft(audio, _draft('Selected'));
      preferences.failNext = true;
      await expectLater(
        subtitles.selectSubtitleFile(audio, original.path),
        throwsStateError,
      );
      expect(subtitles.trackSync(audio)?.sourcePath, selected.sourcePath);
      expect((await service().load(audio))?.sourcePath, selected.sourcePath);
      expect(await original.readAsString(), _srt('Original'));
    },
  );
}

String _srt(String text) => '1\n00:00:01,000 --> 00:00:02,000\n$text\n';

SubtitleDraft _draft(String text, [String language = 'zh']) => SubtitleDraft(
  kind: SubtitleDraftKind.translation,
  sourceLanguage: 'ja',
  targetLanguage: language,
  cues: [
    SubtitleCue(
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 2),
      text: 'Source\n$text',
    ),
  ],
);

class _ControlledSaveGateway extends FileCachePlatformGateway {
  _ControlledSaveGateway({this.fail = false});
  final bool fail;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String?> saveTrackSubtitle({
    required String trackPath,
    String? groupKey,
    required String extension,
    required Uint8List bytes,
    String? sourcePath,
    bool overwrite = false,
    bool createNew = false,
    String? fileNameSuffix,
  }) async {
    started.complete();
    if (fail) return null;
    await release.future;
    return super.saveTrackSubtitle(
      trackPath: trackPath,
      groupKey: groupKey,
      extension: extension,
      bytes: bytes,
      sourcePath: sourcePath,
      overwrite: overwrite,
      createNew: createNew,
      fileNameSuffix: fileNameSuffix,
    );
  }
}

class _SafChoicesGateway extends FileCachePlatformGateway {
  static const original = 'content://provider/document/root%2Fvoice.srt';
  static const translated =
      'content://provider/document/root%2Fvoice.mp3.translated.en.srt';
  final content = {original: _srt('Original'), translated: _srt('Translated')};

  @override
  Future<List<({String sourcePath, String name})>> listTrackSubtitles({
    required String trackPath,
    String? groupKey,
  }) async => [
    (sourcePath: original, name: 'voice.srt'),
    (sourcePath: translated, name: 'voice.mp3.translated.en.srt'),
  ];

  @override
  Future<Map<String, Object?>?> resolveTrackSubtitle({
    required String path,
    String? groupKey,
  }) async => {
    'sourcePath': original,
    'extension': '.srt',
    'text': content[original],
  };

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async {
    final text = content[filePath];
    return text == null ? null : Uint8List.fromList(utf8.encode(text));
  }
}

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  bool failNext = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (failNext && key == 'flutter.subtitle_custom_paths') {
      failNext = false;
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}
