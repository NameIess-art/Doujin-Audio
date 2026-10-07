import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const editedCues = [
    SubtitleCue(
      start: Duration(milliseconds: 1500),
      end: Duration(milliseconds: 2800),
      text: '修改后的字幕\n第二行',
    ),
  ];
  const ass =
      '[Script Info]\nTitle: Keep title\n[V4+ Styles]\n'
      'Format: Name, Fontname\nStyle: Custom,Arial\n[Events]\n'
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
      'Dialogue: 0,0:00:01.00,0:00:03.00,Custom,,0,0,0,,Original\n';
  for (final overwrite in [false, true]) {
    test(
      'import replaces existing subtitles only when confirmed ($overwrite)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'subtitle_move_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final audio = File('${directory.path}/audio.mp3');
        await audio.writeAsBytes([]);
        final existing = File('${directory.path}/audio.lrc');
        await existing.writeAsString('[00:01.000]Original\n[00:03.000]\n');
        final sourceDir = Directory('${directory.path}/input');
        await sourceDir.create();
        final source = File('${sourceDir.path}/selected.srt');
        const imported = '1\n00:00:01,000 --> 00:00:03,000\nImported\n';
        await source.writeAsString(imported);
        final service = PlaybackSubtitleService(trackResolver: (_) => null);
        final before = await service.load(audio.path);
        final result = await service.importSubtitle(
          audio.path,
          source.path,
          overwrite: overwrite,
        );
        if (!overwrite) {
          expect(result, isNull);
          expect(await source.readAsString(), imported);
          expect(await existing.readAsString(), contains('Original'));
          expect(service.trackSync(audio.path), same(before));
          expect(await File('${directory.path}/audio.srt').exists(), isFalse);
        } else {
          expect(
            result?.sourcePath,
            '${directory.path}${Platform.pathSeparator}audio.srt',
          );
          expect(result?.cues.single.text, 'Imported');
          expect(await source.exists(), isFalse);
          expect(await existing.exists(), isFalse);
          final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
          expect(
            (await restarted.load(audio.path))?.cues.single.text,
            'Imported',
          );
          await service.saveEditedSubtitle(audio.path, editedCues);
          expect(
            await File(result!.sourcePath).readAsString(),
            contains('修改后的字幕'),
          );
          restarted.clear();
          expect(
            (await restarted.load(audio.path))?.cues.single.text,
            editedCues.single.text,
          );
        }
      },
    );
  }

  test('importing the current subtitle keeps the source file', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_same_');
    addTearDown(() => directory.delete(recursive: true));
    final audio = File('${directory.path}/audio.mp3');
    await audio.writeAsBytes([]);
    final source = File('${directory.path}/audio.srt');
    const content = '1\n00:00:01,000 --> 00:00:03,000\nOriginal\n';
    await source.writeAsString(content);
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    final imported = await service.importSubtitle(
      audio.path,
      source.path,
      overwrite: true,
    );
    expect(imported?.cues.single.text, 'Original');
    expect(await source.readAsString(), content);
  });

  test('invalid import preserves the source and existing subtitle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'subtitle_invalid_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final audio = File('${directory.path}/audio.mp3');
    await audio.writeAsBytes([]);
    final existing = File('${directory.path}/audio.srt');
    await existing.writeAsString(
      '1\n00:00:01,000 --> 00:00:03,000\nOriginal\n',
    );
    final source = File('${directory.path}/invalid.srt');
    await source.writeAsString('No timestamps');
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    expect(
      await service.importSubtitle(audio.path, source.path, overwrite: true),
      isNull,
    );
    expect(await source.readAsString(), 'No timestamps');
    expect(await existing.readAsString(), contains('Original'));
  });

  test(
    'persisted local subtitle choice takes precedence over automatic matching',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_legacy_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final audio = File('${directory.path}/audio.mp3');
      await audio.writeAsBytes([]);
      final old = File('${directory.path}/old-cache.srt');
      await old.writeAsString('1\n00:00:01,000 --> 00:00:03,000\nOld cache\n');
      SharedPreferences.setMockInitialValues({
        'subtitle_custom_paths': ['${audio.path}|${old.path}'],
      });
      final local = File('${directory.path}/audio.zh.srt');
      await local.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\nLocal file\n',
      );
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      expect((await service.load(audio.path))?.cues.single.text, 'Old cache');
      await service.saveEditedSubtitle(audio.path, editedCues);
      final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
      expect(
        path.equals((await restarted.load(audio.path))!.sourcePath, old.path),
        isTrue,
      );
      expect((await old.readAsString()), contains(editedCues.single.text));
      expect((await local.readAsString()), contains('Local file'));
    },
  );
  for (final extension in [
    'srt',
    'lrc',
    'vtt',
    'webvtt',
    'ass',
    'ssa',
    'txt',
  ]) {
    test(
      'editing $extension overwrites the local file and reloads it',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'subtitle_edit_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final audio = File('${directory.path}/中文 音频.mp3');
        await audio.writeAsBytes([]);
        final source = File('${directory.path}/中文 音频.$extension');
        final original = switch (extension) {
          'lrc' || 'txt' => '[00:01.000]Original\n[00:03.000]\n',
          'vtt' ||
          'webvtt' => 'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nOriginal\n',
          'ass' || 'ssa' => ass,
          _ => '1\n00:00:01,000 --> 00:00:03,000\nOriginal\n',
        };
        await source.writeAsString(original);
        final service = PlaybackSubtitleService(
          trackResolver: (_) => null,
          subtitlesDirectoryResolver: () async => directory,
        );
        final loaded = await service.load(audio.path);
        final actualFile = File(loaded!.sourcePath);
        final edited = await service.saveEditedSubtitle(audio.path, editedCues);
        expect(edited.sourcePath, loaded.sourcePath);
        expect(edited.cues.single.text, editedCues.single.text);
        expect(edited.cues.single.start, editedCues.single.start);
        expect(edited.cues.single.end, editedCues.single.end);
        final content = await actualFile.readAsString();
        expect(content, isNot(contains('Original')));
        if (extension == 'ass' || extension == 'ssa') {
          expect(content, contains('Title: Keep title'));
          expect(content, contains('Style: Custom,Arial'));
          expect(content, contains(',Custom,'));
        }
        final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
        expect(
          (await restarted.load(audio.path))?.cues.single.text,
          editedCues.single.text,
        );
        expect(
          await directory
              .list()
              .where(
                (file) =>
                    file.path.endsWith('.tmp') || file.path.endsWith('.bak'),
              )
              .isEmpty,
          isTrue,
        );
        final cleared = await service.saveEditedSubtitle(audio.path, const []);
        expect(cleared.sourcePath, loaded.sourcePath);
        expect(cleared.cues, isEmpty);
        final afterClear = PlaybackSubtitleService(trackResolver: (_) => null);
        expect((await afterClear.load(audio.path))?.cues, isEmpty);
      },
    );
  }

  for (final failWrite in [false, true]) {
    test('SAF edits target the original URI (failure: $failWrite)', () async {
      const audioPath = 'content://provider/audio.mp3';
      final gateway = _EditableSubtitleGateway()..failWrite = failWrite;
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        fileCacheGateway: gateway,
      );
      final loaded = await service.load(audioPath);
      if (failWrite) {
        await expectLater(
          service.saveEditedSubtitle(audioPath, editedCues),
          throwsStateError,
        );
        expect(service.trackSync(audioPath), same(loaded));
        expect(gateway.content, contains('Original'));
      } else {
        final edited = await service.saveEditedSubtitle(audioPath, editedCues);
        expect(edited.sourcePath, _EditableSubtitleGateway.subtitleUri);
        expect(edited.cues.single.text, editedCues.single.text);
        final restarted = PlaybackSubtitleService(
          trackResolver: (_) => null,
          fileCacheGateway: gateway,
        );
        expect(
          (await restarted.load(audioPath))?.cues.single.text,
          editedCues.single.text,
        );
        await service.saveEditedSubtitle(audioPath, const []);
        final afterClear = PlaybackSubtitleService(
          trackResolver: (_) => null,
          fileCacheGateway: gateway,
        );
        expect((await afterClear.load(audioPath))?.cues, isEmpty);
      }
      expect(gateway.writtenPath, _EditableSubtitleGateway.subtitleUri);
    });
  }

  test('unrepresentable ASS timing leaves the original file intact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'subtitle_precision_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.ass');
    await source.writeAsString(ass);
    final audioPath = '${directory.path}/source.mp3';
    await File(audioPath).writeAsBytes([]);
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    final before = await service.load(audioPath);
    await expectLater(
      service.saveEditedSubtitle(audioPath, const [
        SubtitleCue(
          start: Duration(milliseconds: 1),
          end: Duration(milliseconds: 2),
          text: 'Too short for ASS',
        ),
      ]),
      throwsStateError,
    );
    expect(await source.readAsString(), ass);
    expect(service.trackSync(audioPath), same(before));
  });

  test(
    'a removed source file reports failure without creating a replacement',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_missing_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/source.srt');
      await source.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\nOriginal\n',
      );
      final audioPath = '${directory.path}/source.mp3';
      await File(audioPath).writeAsBytes([]);
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      final before = await service.load(audioPath);
      await source.delete();
      await expectLater(
        service.saveEditedSubtitle(audioPath, editedCues),
        throwsStateError,
      );
      expect(service.trackSync(audioPath), same(before));
      expect(await directory.list().length, 1);
    },
  );

  test(
    'script recognition writes the audio-named LRC beside a local audio file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_local_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final audio = File(
        '${directory.path}${Platform.pathSeparator}voice-track.mp3',
      );
      await audio.writeAsBytes(const []);
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      final saved = await service.saveDraft(
        audio.path,
        const SubtitleDraft(
          kind: SubtitleDraftKind.script,
          sourceLanguage: 'ja',
          cues: [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: 'おはようございます。',
            ),
          ],
        ),
      );
      final lrc = File(
        '${directory.path}${Platform.pathSeparator}voice-track.lrc',
      );
      expect(saved.sourcePath, lrc.path);
      expect(await lrc.readAsString(), contains('おはようございます。'));

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
      expect((await restarted.load(audio.path))?.sourcePath, lrc.path);
      expect(
        restarted.textAt(audio.path, const Duration(seconds: 2)),
        'おはようございます。',
      );
    },
  );

  test('clearing an edited subtitle remains local after restart', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_clear_');
    addTearDown(() => directory.delete(recursive: true));
    final audioPath = '${directory.path}/source.mp3';
    await File(audioPath).writeAsBytes([]);
    final source = File('${directory.path}${Platform.pathSeparator}source.srt');
    await source.writeAsString(
      '1\n00:00:01,000 --> 00:00:03,000\nおはようございます。\n',
    );
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) async => SubtitleTrack(
        sourcePath: source.path,
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'おはようございます。',
          ),
        ],
      ),
      subtitlesDirectoryResolver: () async => directory,
    );
    await service.load(audioPath);
    final cleared = await service.saveEditedSubtitle(audioPath, const []);
    expect(cleared.cues, isEmpty);
    expect(service.hasKnownSubtitle(audioPath), isFalse);
    expect(await File(cleared.sourcePath).exists(), isTrue);
    expect(cleared.sourcePath, source.path);
    expect((await source.readAsString()).trim(), isEmpty);
    final restarted = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitlesDirectoryResolver: () async => directory,
    );
    expect((await restarted.load(audioPath))?.cues, isEmpty);
    expect(restarted.hasKnownSubtitle(audioPath), isFalse);
  });

  test('SAF script writes audio-named LRC to the authorized folder', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_saf_');
    addTearDown(() => directory.delete(recursive: true));
    const audioPath =
        'content://provider/tree/root/document/root%2Fvoice-track.mp3';
    final gateway = _RecordingSubtitleGateway();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => MusicTrack(
        path: audioPath,
        displayName: 'voice-track.mp3',
        groupKey: 'content://provider/tree/root',
        groupTitle: 'root',
        groupSubtitle: '',
        isSingle: false,
      ),
      fileCacheGateway: gateway,
      subtitlesDirectoryResolver: () async => directory,
    );
    await service.saveDraft(
      audioPath,
      const SubtitleDraft(
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
        cues: [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: 'こんにちは。',
          ),
        ],
      ),
    );
    expect(gateway.groupKey, 'content://provider/tree/root');
    expect(gateway.trackPath, audioPath);
    expect(gateway.extension, '.lrc');
    expect(utf8.decode(gateway.bytes!), contains('こんにちは。'));
    await service.saveEditedSubtitle(audioPath, editedCues);
    expect(gateway.writtenPath, _RecordingSubtitleGateway.subtitleUri);
    expect(utf8.decode(gateway.bytes!), contains('修改后的字幕'));
    expect(
      service.trackSync(audioPath)?.cues.single.text,
      editedCues.single.text,
    );
  });

  test(
    'translation can reuse Japanese text after loading its local SRT',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_translation_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final audioPath = '${directory.path}/japanese.mp3';
      await File(audioPath).writeAsBytes([]);
      const japanese = 'お姉ちゃん、今日は一緒に寝ましょうね。';
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (_, _) async => SubtitleTrack(
          sourcePath: 'source.srt',
          cues: const [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: japanese,
            ),
          ],
        ),
        subtitlesDirectoryResolver: () async => directory,
      );
      await service.load(audioPath);
      await service.saveDraft(
        audioPath,
        const SubtitleDraft(
          kind: SubtitleDraftKind.translation,
          sourceLanguage: 'ja',
          targetLanguage: 'zh',
          cues: [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: '$japanese\n姐姐，今晚一起睡吧。',
            ),
          ],
        ),
      );
      final restarted = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitlesDirectoryResolver: () async => directory,
      );
      expect(
        (await restarted.japaneseSourceCues(audioPath)).single.text,
        japanese,
      );
    },
  );
}

class _EditableSubtitleGateway extends FileCachePlatformGateway {
  static const subtitleUri = 'content://provider/document/1234';
  String content = '1\n00:00:01,000 --> 00:00:03,000\nOriginal\n';
  bool failWrite = false;
  String? writtenPath;

  @override
  Future<Map<String, Object?>?> resolveTrackSubtitle({
    required String path,
    String? groupKey,
  }) async => {'sourcePath': subtitleUri, 'extension': '.srt', 'text': content};

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async =>
      filePath == subtitleUri ? Uint8List.fromList(utf8.encode(content)) : null;

  @override
  Future<bool> writeTrackSubtitle({
    required String path,
    required Uint8List bytes,
  }) async {
    writtenPath = path;
    if (failWrite) return false;
    content = utf8.decode(bytes);
    return true;
  }
}

class _RecordingSubtitleGateway extends FileCachePlatformGateway {
  static const subtitleUri =
      'content://provider/tree/root/document/root%2Fvoice-track.lrc';
  String? groupKey;
  String? trackPath;
  String? extension;
  String? writtenPath;
  Uint8List? bytes;

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
    this.groupKey = groupKey;
    this.trackPath = trackPath;
    this.extension = extension;
    this.bytes = bytes;
    return subtitleUri;
  }

  @override
  Future<Uint8List?> readDocumentBytes(String path) async => bytes;

  @override
  Future<bool> writeTrackSubtitle({
    required String path,
    required Uint8List bytes,
  }) async {
    writtenPath = path;
    this.bytes = bytes;
    return true;
  }
}
