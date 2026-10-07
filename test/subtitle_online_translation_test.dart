import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

typedef _Reply = Future<TextTranslationResult> Function(_Call call);

class _Call {
  _Call(this.texts, this.target, this.request);
  final List<String> texts;
  final String target;
  final TextTranslationRequest request;
}

class _Translations extends TextTranslationService {
  _Translations({this.reply});
  final _Reply? reply;
  final calls = <_Call>[];

  @override
  Future<TextTranslationResult> translate(
    List<String> texts, {
    required String target,
    String source = 'auto',
    required TextTranslationRequest request,
  }) async {
    final call = _Call(List.of(texts), target, request);
    calls.add(call);
    return reply != null
        ? await reply!(call)
        : TextTranslationResult(
            translations: {for (final text in texts) text: 'Translated $text'},
          );
  }
}

class _NoTranslationModels extends SubtitleModelStore {
  @override
  Future<String> ensure(
    SubtitleModelSpec spec, {
    void Function(double, int, int)? onProgress,
    bool Function()? isCancelled,
  }) => throw StateError('Online translation must not request a local model');
}

class _SubtitleFiles extends FileCachePlatformGateway {
  final writes = <String>[];
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
    expect(extension, '.srt');
    expect(overwrite, isFalse);
    expect(createNew, isTrue);
    expect(fileNameSuffix, anyOf('.translated.zh-CN', '.translated.en'));
    this.bytes = bytes;
    writes.add(utf8.decode(bytes));
    return 'saved.srt';
  }

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async => bytes;
}

SubtitleCue _cue(String text, [int index = 0]) => SubtitleCue(
  start: Duration(seconds: index * 3 + 1),
  end: Duration(seconds: index * 3 + 3),
  text: text,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Subtitle task did not reach the expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    support = await Directory.systemTemp.createTemp('subtitle_online_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => support.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });

  for (final target in ['zh', 'en']) {
    test(
      'online $target translation keeps original cue timing and order',
      () async {
        final translations = _Translations();
        final source = [_cue('今日は一緒に眠りましょう。'), _cue('次の台詞です。', 1)];
        final progress = <SubtitleTaskProgress>[];
        final draft =
            await SubtitleAiEngine(
              translations: translations,
              models: _NoTranslationModels(),
            ).prepareTranslation(
              source,
              target,
              trackPath: 'audio.mp3',
              onProgress: progress.add,
            );
        expect(draft.kind, SubtitleDraftKind.translation);
        expect(draft.sourceLanguage, 'ja');
        expect(draft.targetLanguage, target);
        expect(
          translations.calls.single.target,
          target == 'zh' ? 'zh-CN' : 'en',
        );
        for (var index = 0; index < source.length; index++) {
          expect(draft.cues[index].start, source[index].start);
          expect(draft.cues[index].end, source[index].end);
          expect(
            draft.cues[index].text,
            '${source[index].text}\nTranslated ${source[index].text}',
          );
        }
        expect(progress.last.stage, 'translating');
        expect(progress.last.fraction, 1);
        expect(progress.any((item) => item.stage == 'download'), isFalse);
      },
    );
  }

  test(
    'duplicates map back to every cue without dropping multiline source',
    () async {
      final translations = _Translations();
      final draft = await SubtitleAiEngine(translations: translations)
          .prepareTranslation(
            [_cue('同じ台詞です。\n旧译文'), _cue('同じ台詞です。', 1)],
            'zh',
            trackPath: 'audio.mp3',
          );
      expect(translations.calls.single.texts.toSet(), {
        '同じ台詞です。\n旧译文',
        '同じ台詞です。',
      });
      expect(draft.cues.map((cue) => cue.text), [
        '同じ台詞です。\n旧译文\nTranslated 同じ台詞です。\n旧译文',
        '同じ台詞です。\nTranslated 同じ台詞です。',
      ]);
    },
  );

  test(
    'batches respect item and character limits for many long cues',
    () async {
      final translations = _Translations();
      final source = [
        for (var i = 0; i < 55; i++) _cue('日本語の字幕$i ${'あ' * 90}', i),
      ];
      final draft = await SubtitleAiEngine(
        translations: translations,
      ).prepareTranslation(source, 'en', trackPath: 'audio.mp3');
      expect(draft.cues.length, source.length);
      expect(translations.calls.length, greaterThan(1));
      for (final call in translations.calls) {
        expect(call.texts.length, lessThanOrEqualTo(50));
        expect(
          call.texts.fold<int>(0, (sum, text) => sum + text.length),
          lessThanOrEqualTo(4000),
        );
      }
    },
  );

  test(
    'one oversized cue is segmented without losing the source text',
    () async {
      final original = '${'あ' * 3999}😀${'い' * 4200}';
      final translations = _Translations(
        reply: (call) async => TextTranslationResult(
          translations: {for (final text in call.texts) text: 'Translated'},
        ),
      );
      final draft = await SubtitleAiEngine(
        translations: translations,
      ).prepareTranslation([_cue(original)], 'en', trackPath: 'audio.mp3');
      expect(draft.cues.single.text, startsWith('$original\n'));
      expect(
        draft.cues.single.text.substring(original.length + 1),
        contains('Translated'),
      );
      for (final call in translations.calls) {
        for (final text in call.texts) {
          expect(text.length, lessThanOrEqualTo(4000));
          expect(utf8.decode(utf8.encode(text)), text);
        }
      }
    },
  );

  test(
    'a completed batch is checkpointed and resumed after online failure',
    () async {
      final source = [for (var i = 0; i < 51; i++) _cue('日本語の字幕$i', i)];
      var count = 0;
      final translations = _Translations(
        reply: (call) async {
          count++;
          return count == 2
              ? TextTranslationResult(
                  failure: TextTranslationFailure.unavailable,
                )
              : TextTranslationResult(
                  translations: {
                    for (final text in call.texts) text: 'Translated $text',
                  },
                );
        },
      );
      final engine = SubtitleAiEngine(translations: translations);
      await expectLater(
        engine.prepareTranslation(source, 'zh', trackPath: 'audio.mp3'),
        throwsA(TextTranslationFailure.unavailable),
      );
      final checkpoints = await Directory(
        path.join(support.path, 'subtitle_progress'),
      ).list().where((file) => file is File).toList();
      expect(checkpoints, hasLength(1));
      final saved =
          jsonDecode(await File(checkpoints.single.path).readAsString()) as Map;
      expect(saved['nextChunk'], 50);
      expect(saved['cues'], hasLength(50));
      final resumed = await engine.prepareTranslation(
        source,
        'zh',
        trackPath: 'audio.mp3',
      );
      expect(resumed.cues, hasLength(51));
      expect(translations.calls.last.texts, ['日本語の字幕50']);
      expect(translations.calls, hasLength(3));
    },
  );

  test(
    'missing response entries fail without producing a partial draft',
    () async {
      final translations = _Translations(
        reply: (call) async => TextTranslationResult(
          translations: {call.texts.first: 'Translated'},
        ),
      );
      await expectLater(
        SubtitleAiEngine(translations: translations).prepareTranslation(
          [_cue('最初の台詞です。'), _cue('次の台詞です。', 1)],
          'zh',
          trackPath: 'audio.mp3',
        ),
        throwsA(TextTranslationFailure.invalidResponse),
      );
      expect(
        await Directory(
          path.join(support.path, 'subtitle_progress'),
        ).list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'cancellation aborts pending request without blocking a new translation',
    () async {
      final result = Completer<TextTranslationResult>();
      var first = true;
      final translations = _Translations(
        reply: (call) {
          if (first) {
            first = false;
            return result.future;
          }
          return Future.value(
            TextTranslationResult(
              translations: {
                for (final text in call.texts) text: 'Fresh translation',
              },
            ),
          );
        },
      );
      final cancellation = Completer<void>();
      var cancelled = false;
      final progress = <SubtitleTaskProgress>[];
      final engine = SubtitleAiEngine(translations: translations);
      final task = engine.prepareTranslation(
        [_cue('今日は一緒に眠りましょう。')],
        'zh',
        trackPath: 'audio.mp3',
        onProgress: progress.add,
        isCancelled: () => cancelled,
        cancellation: cancellation.future,
      );
      final assertion = expectLater(
        task,
        throwsA(isA<SubtitleTaskCancelled>()),
      );
      await _waitUntil(() => translations.calls.isNotEmpty);
      cancelled = true;
      cancellation.complete();
      await assertion;
      expect(translations.calls.single.request.cancelled, isTrue);
      final priorProgress = progress.length;
      expect(
        await Directory(
          path.join(support.path, 'subtitle_progress'),
        ).list().toList(),
        isEmpty,
      );
      final fresh = await engine.prepareTranslation(
        [_cue('今日は一緒に眠りましょう。')],
        'zh',
        trackPath: 'audio.mp3',
      );
      expect(fresh.cues.single.text, endsWith('\nFresh translation'));
      expect(
        identical(
          translations.calls.first.request,
          translations.calls.last.request,
        ),
        isFalse,
      );
      final checkpoint =
          (await Directory(
                path.join(support.path, 'subtitle_progress'),
              ).list().toList()).single
              as File;
      final saved = await checkpoint.readAsString();
      result.complete(
        TextTranslationResult(
          translations: {'今日は一緒に眠りましょう。': 'Late translation'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(progress, hasLength(priorProgress));
      expect(await checkpoint.readAsString(), saved);
    },
  );

  for (final succeeds in [true, false]) {
    test(
      'generation ${succeeds ? 'saves and reloads bilingual SRT' : 'does not save failed translation'}',
      () async {
        final source = [_cue('今日は一緒に眠りましょう。')];
        final files = _SubtitleFiles();
        final translations = _Translations(
          reply: (call) async => succeeds
              ? TextTranslationResult(
                  translations: {call.texts.single: '今天一起睡吧。'},
                )
              : TextTranslationResult(
                  failure: TextTranslationFailure.rateLimited,
                ),
        );
        final service = PlaybackSubtitleService(
          trackResolver: (_) => null,
          fileCacheGateway: files,
          aiEngine: SubtitleAiEngine(translations: translations),
          subtitleLoader: (_, _) async =>
              SubtitleTrack(sourcePath: 'original.srt', cues: source),
          subtitlesDirectoryResolver: () async => support,
        );
        addTearDown(service.dispose);
        expect(service.startTranslationGeneration('audio.mp3', 'zh'), isTrue);
        await _waitUntil(
          () =>
              service.generationJob!.status != SubtitleGenerationStatus.running,
        );
        expect(
          service.generationJob!.status,
          succeeds
              ? SubtitleGenerationStatus.completed
              : SubtitleGenerationStatus.failed,
        );
        if (succeeds) {
          expect(
            files.writes.single,
            contains('00:00:01,000 --> 00:00:03,000'),
          );
          expect(
            files.writes.single,
            contains(
              '${source.single.text}\n$subtitleTranslationBoundary今天一起睡吧。',
            ),
          );
          expect(
            service.trackSync('audio.mp3')!.cues.single.text,
            '${source.single.text}\n今天一起睡吧。',
          );
        } else {
          expect(files.writes, isEmpty);
          expect(
            service.trackSync('audio.mp3')!.cues.single.text,
            source.single.text,
          );
        }
      },
    );
  }

  test(
    'cancelled generation never writes or applies a late translation',
    () async {
      final source = [_cue('今日は一緒に眠りましょう。')];
      final files = _SubtitleFiles();
      final result = Completer<TextTranslationResult>();
      final translations = _Translations(reply: (_) => result.future);
      var applied = 0;
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        fileCacheGateway: files,
        aiEngine: SubtitleAiEngine(translations: translations),
        subtitleLoader: (_, _) async =>
            SubtitleTrack(sourcePath: 'original.srt', cues: source),
        subtitlesDirectoryResolver: () async => support,
      );
      addTearDown(service.dispose);
      expect(
        service.startTranslationGeneration(
          'audio.mp3',
          'zh',
          onApplied: () => applied++,
        ),
        isTrue,
      );
      await _waitUntil(() => translations.calls.isNotEmpty);
      service.cancelGeneration();
      await _waitUntil(
        () =>
            service.generationJob!.status == SubtitleGenerationStatus.cancelled,
      );
      expect(translations.calls.single.request.cancelled, isTrue);
      final priorProgress = service.generationJob!.progress;
      result.complete(
        TextTranslationResult(
          translations: {source.single.text: 'Late translation'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.generationJob!.status, SubtitleGenerationStatus.cancelled);
      expect(service.generationJob!.progress, same(priorProgress));
      expect(files.writes, isEmpty);
      expect(applied, 0);
      expect(
        service.trackSync('audio.mp3')!.cues.single.text,
        source.single.text,
      );
    },
  );
}
