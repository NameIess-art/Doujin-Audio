import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

const _original =
    '\u4eca\u65e5\u306f\u4e00\u7dd2\u306b\u7720\u308a\u307e\u3057\u3087\u3046\u3002\n'
    '\u3086\u3063\u304f\u308a\u4f11\u3093\u3067\u304f\u3060\u3055\u3044\u3002';
const _marker = '<!--doujin-audio:translation-->';
const _translated = 'Sleep together today.\nPlease rest comfortably.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String audio;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('subtitle_quality_');
    audio = path.join(directory.path, 'voice.mp3');
    await File(audio).writeAsBytes([]);
    await File(
      path.join(directory.path, 'voice.srt'),
    ).writeAsString(_srt(_original));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  PlaybackSubtitleService service({
    _Translations? translations,
    FileCachePlatformGateway? gateway,
  }) {
    final result = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: SubtitleAiEngine(translations: translations ?? _Translations()),
      fileCacheGateway: gateway,
      subtitlesDirectoryResolver: () async => directory,
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'ordinary multiline subtitles send every original line with source ja',
    () async {
      final translations = _Translations();
      final subtitles = service(translations: translations);
      final draft = await subtitles.prepareTranslation(audio, 'en');

      expect(translations.calls.single.source, 'ja');
      expect(translations.calls.single.texts, [_original]);
      expect(draft.cues.single.originalText, _original);
      expect(draft.cues.single.text, '$_original\n$_translated');
      expect(draft.cues.single.start, const Duration(milliseconds: 1250));
      expect(draft.cues.single.end, const Duration(milliseconds: 4750));
    },
  );

  test(
    'saved boundary survives selection and restart without translating old output',
    () async {
      final translations = _Translations();
      final subtitles = service(translations: translations);
      final draft = await subtitles.prepareTranslation(audio, 'en');
      final saved = await subtitles.saveDraft(audio, draft);
      final raw = await File(saved.sourcePath).readAsString();
      expect(raw, contains('$_original\n$_marker$_translated'));
      expect(saved.cues.single.text, '$_original\n$_translated');
      expect(saved.cues.single.text, isNot(contains(_marker)));
      expect(saved.cues.single.originalText, _original);

      await subtitles.selectSubtitleFile(
        audio,
        path.join(directory.path, 'voice.srt'),
      );
      await subtitles.selectSubtitleFile(audio, saved.sourcePath);
      final freshTranslations = _Translations();
      final restarted = service(translations: freshTranslations);
      final restored = await restarted.load(audio);
      expect(restored!.cues.single.originalText, _original);
      expect(
        (await restarted.japaneseSourceCues(audio)).single.text,
        _original,
      );
      await restarted.prepareTranslation(audio, 'zh');
      expect(freshTranslations.calls.single.texts, [_original]);
      expect(freshTranslations.calls.single.source, 'ja');
      expect(
        await File(path.join(directory.path, 'voice.srt')).readAsString(),
        _srt(_original),
      );
    },
  );

  test(
    'editing translation and timing retains source boundary across restart',
    () async {
      final subtitles = service();
      final draft = await subtitles.prepareTranslation(audio, 'en');
      final saved = await subtitles.saveDraft(audio, draft);
      final edited = await subtitles.saveEditedSubtitle(audio, [
        const SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 6),
          text: '$_original\nEdited translation',
        ),
      ]);
      expect(edited.sourcePath, saved.sourcePath);
      expect(edited.cues.single.originalText, _original);
      expect(edited.cues.single.start, const Duration(seconds: 2));
      expect(edited.cues.single.end, const Duration(seconds: 6));
      expect(edited.cues.single.text, '$_original\nEdited translation');
      final restarted = service();
      expect(
        (await restarted.load(audio))!.cues.single.originalText,
        _original,
      );
      expect(
        (await restarted.japaneseSourceCues(audio)).single.text,
        _original,
      );
      expect(
        await File(path.join(directory.path, 'voice.srt')).readAsString(),
        _srt(_original),
      );
    },
  );

  for (final separator in ['\n\n', '\r\n \r\n\r\n']) {
    test(
      'translated blank paragraphs ${jsonEncode(separator)} do not split a saved cue',
      () async {
        final translations = _Translations(
          reply: Future.value(
            TextTranslationResult(
              translations: {
                _original:
                    'Sleep together today.${separator}Please rest comfortably.',
              },
            ),
          ),
        );
        final subtitles = service(translations: translations);
        final draft = await subtitles.prepareTranslation(audio, 'en');
        expect(draft.cues.single.text, '$_original\n$_translated');
        final saved = await subtitles.saveDraft(audio, draft);
        expect(saved.cues, hasLength(1));
        final restored = (await service().load(audio))!;
        expect(restored.cues, hasLength(1));
        expect(restored.cues.single.start, const Duration(milliseconds: 1250));
        expect(restored.cues.single.end, const Duration(milliseconds: 4750));
        expect(restored.cues.single.originalText, _original);
        expect(restored.cues.single.text, '$_original\n$_translated');
      },
    );
  }

  for (final keepTranslation in [true, false]) {
    test(
      'edited multiline source remains complete ${keepTranslation ? 'with updated translation' : 'after removing translation'}',
      () async {
        const updatedOriginal =
            '\u3053\u3093\u3070\u3093\u306f\u3001\u304a\u3084\u3059\u307f\u306a\u3055\u3044\u3002\n'
            '\u307e\u305f\u660e\u65e5\u304a\u4f1a\u3044\u3057\u307e\u3057\u3087\u3046\u3002\n'
            '\u3086\u3063\u304f\u308a\u4f11\u3093\u3067\u304f\u3060\u3055\u3044\u3002';
        final updatedText = keepTranslation
            ? '$updatedOriginal\nNew translation'
            : updatedOriginal;
        final subtitles = service();
        final draft = await subtitles.prepareTranslation(audio, 'en');
        final saved = await subtitles.saveDraft(audio, draft);
        final edited = await subtitles.saveEditedSubtitle(audio, [
          SubtitleCue(
            start: const Duration(milliseconds: 1250),
            end: const Duration(milliseconds: 4750),
            text: updatedText,
            originalText: updatedOriginal,
          ),
        ]);
        expect(edited.sourcePath, saved.sourcePath);
        expect(edited.cues.single.originalText, updatedOriginal);
        expect(edited.cues.single.text, updatedText);
        expect(await File(saved.sourcePath).readAsString(), contains(_marker));
        final restarted = service();
        final restored = (await restarted.load(audio))!;
        expect(restored.cues.single.originalText, updatedOriginal);
        expect(restored.cues.single.text, updatedText);
        expect(
          (await restarted.japaneseSourceCues(audio)).single.text,
          updatedOriginal,
        );
        expect(
          await File(path.join(directory.path, 'voice.srt')).readAsString(),
          _srt(_original),
        );
      },
    );
  }

  test(
    'opaque SAF document URI retains multiline source metadata across restart',
    () async {
      const safAudio = 'content://provider/document/47';
      final gateway = _SafGateway(_srt('$_original\n$_marker\n$_translated'));
      final subtitles = service(gateway: gateway);
      final selected = await subtitles.selectSubtitleFile(
        safAudio,
        _SafGateway.subtitle,
      );
      expect(selected.cues.single.originalText, _original);
      expect(selected.cues.single.text, '$_original\n$_translated');
      final restarted = service(gateway: gateway);
      expect(
        (await restarted.load(safAudio))!.cues.single.originalText,
        _original,
      );
      expect(
        (await restarted.japaneseSourceCues(safAudio)).single.text,
        _original,
      );
      expect(gateway.content, _srt('$_original\n$_marker\n$_translated'));
    },
  );

  test(
    'long English output does not dilute Japanese source classification',
    () async {
      final subtitles = service();
      final translated = File(
        path.join(directory.path, 'voice.mp3.translated.en.srt'),
      );
      await translated.writeAsString(
        _srt('$_original\n$_marker${'English translation. ' * 100}'),
      );
      await subtitles.selectSubtitleFile(audio, translated.path);
      expect(
        subtitles.classifyCurrentSubtitle(audio),
        SubtitleLanguage.japanese,
      );
      expect(
        (await subtitles.japaneseSourceCues(audio)).single.text,
        _original,
      );
    },
  );

  test(
    'legacy named translations use first line but unmarked originals keep all lines',
    () async {
      final subtitles = service();
      final originalCues = await subtitles.japaneseSourceCues(audio);
      expect(originalCues.single.text, _original);
      final firstLine = _original.split('\n').first;
      final legacy = File(
        path.join(directory.path, 'voice.mp3.translated.en.srt'),
      );
      await legacy.writeAsString(_srt('$firstLine\n$_translated'));
      await subtitles.selectSubtitleFile(audio, legacy.path);
      expect(
        (await subtitles.japaneseSourceCues(audio)).single.text,
        firstLine,
      );
      expect(subtitles.trackSync(audio)!.cues.single.originalText, isNull);
    },
  );

  test(
    'v2 checkpoint cannot supply old truncated translation and v3 retains source',
    () async {
      final source = [_cue(_original)];
      final workDir = Directory(path.join(directory.path, 'subtitle_progress'));
      await workDir.create();
      final sourceIdentity = sha256
          .convert(utf8.encode(jsonEncode([audio, 'en'])))
          .toString();
      final oldIdentity = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                [1250000, 4750000, _original.split('\n').first],
              ]),
            ),
          )
          .toString();
      final oldCheckpoint = File(
        path.join(workDir.path, '${sourceIdentity}_v2_$oldIdentity.json'),
      );
      await oldCheckpoint.writeAsString(
        jsonEncode({
          'version': 2,
          'nextChunk': 1,
          'cues': [
            [1250, 4750, '${_original.split('\n').first}\nOld translation'],
          ],
        }),
      );
      final translations = _Translations();
      final engine = SubtitleAiEngine(translations: translations);
      final draft = await engine.prepareTranslation(
        source,
        'en',
        trackPath: audio,
      );
      expect(translations.calls.single.texts, [_original]);
      expect(draft.cues.single.originalText, _original);
      expect(draft.cues.single.text, isNot(contains('Old translation')));
      final checkpoints = await workDir
          .list()
          .where((entry) => entry is File)
          .toList();
      expect(checkpoints, hasLength(1));
      expect(path.basename(checkpoints.single.path), contains('_v3_'));
      expect(
        jsonDecode(
          await File(checkpoints.single.path).readAsString(),
        )['version'],
        3,
      );

      final resumedTranslations = _Translations();
      final resumed = await SubtitleAiEngine(
        translations: resumedTranslations,
      ).prepareTranslation(source, 'en', trackPath: audio);
      expect(resumedTranslations.calls, isEmpty);
      expect(resumed.cues.single.originalText, _original);
      expect(resumed.cues.single.text, '$_original\n$_translated');
    },
  );

  test(
    'cancelling multiline translation prevents late save and source changes',
    () async {
      final reply = Completer<TextTranslationResult>();
      final translations = _Translations(reply: reply.future);
      final subtitles = service(translations: translations);
      expect(subtitles.startTranslationGeneration(audio, 'en'), isTrue);
      for (var i = 0; i < 500 && translations.calls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(translations.calls.single.texts, [_original]);
      subtitles.cancelGeneration();
      reply.complete(
        TextTranslationResult(translations: {_original: 'Late output'}),
      );
      for (
        var i = 0;
        i < 500 &&
            subtitles.generationJob!.status == SubtitleGenerationStatus.running;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(
        subtitles.generationJob!.status,
        SubtitleGenerationStatus.cancelled,
      );
      expect(subtitles.trackSync(audio)!.cues.single.text, _original);
      expect(
        (await subtitles.availableSubtitleFiles(
          audio,
        )).map((file) => file.name),
        ['voice.srt'],
      );
    },
  );
}

String _srt(String text) => '1\n00:00:01,250 --> 00:00:04,750\n$text\n';

SubtitleCue _cue(String text) => SubtitleCue(
  start: const Duration(milliseconds: 1250),
  end: const Duration(milliseconds: 4750),
  text: text,
);

class _Call {
  _Call(this.texts, this.source);
  final List<String> texts;
  final String source;
}

class _Translations extends TextTranslationService {
  _Translations({this.reply});
  final Future<TextTranslationResult>? reply;
  final calls = <_Call>[];

  @override
  Future<TextTranslationResult> translate(
    List<String> texts, {
    required String target,
    required TextTranslationRequest request,
    String source = 'auto',
  }) async {
    calls.add(_Call(List.of(texts), source));
    return reply ??
        TextTranslationResult(
          translations: {for (final text in texts) text: _translated},
        );
  }
}

class _SafGateway extends FileCachePlatformGateway {
  _SafGateway(this.content);
  static const subtitle = 'content://provider/document/82';
  final String content;

  @override
  Future<List<({String sourcePath, String name})>> listTrackSubtitles({
    required String trackPath,
    String? groupKey,
  }) async => [(sourcePath: subtitle, name: 'voice.mp3.translated.en.srt')];

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async =>
      filePath == subtitle ? Uint8List.fromList(utf8.encode(content)) : null;
}
