import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

class _PendingModels extends SubtitleModelStore {
  final result = Completer<String>();
  final progress = <void Function(double, int, int)>[];

  @override
  Future<String> ensure(
    SubtitleModelSpec spec, {
    void Function(double fraction, int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) {
    expect(isCancelled, isNull, reason: 'The shared download must continue.');
    if (onProgress != null) progress.add(onProgress);
    return result.future;
  }
}

class _ScriptFiles extends FileCachePlatformGateway {
  @override
  Future<Uint8List?> readDocumentBytes(String uri) async =>
      Uint8List.fromList(utf8.encode('今日は一緒に眠りましょう。'));
}

const _source = SubtitleCue(
  start: Duration(seconds: 1),
  end: Duration(seconds: 3),
  text: '今日は一緒に眠りましょう。',
);

String _sourceKey(String trackPath, String language) =>
    sha256.convert(utf8.encode(jsonEncode([trackPath, language]))).toString();

File _checkpoint(
  Directory directory,
  SubtitleCue cue, {
  List<SubtitleCue> remaining = const [],
}) {
  final input = [
    for (final item in [cue, ...remaining])
      [item.start.inMicroseconds, item.end.inMicroseconds, item.text],
  ];
  final digest = sha256.convert(utf8.encode(jsonEncode(input))).toString();
  return File(
    path.join(
      directory.path,
      '${_sourceKey('audio.mp3', 'zh')}_v2_$digest.json',
    ),
  );
}

Future<void> _writeCompleted(File file, SubtitleCue cue) => file
    .writeAsString(
      jsonEncode({
        'version': 2,
        'nextChunk': 1,
        'cues': [
          [
            cue.start.inMilliseconds,
            cue.end.inMilliseconds,
            '${cue.text}\n今天一起睡吧。',
          ],
        ],
      }),
    )
    .then((_) {});

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Subtitle task did not reach the expected state.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late Directory checkpoints;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    support = await Directory.systemTemp.createTemp('subtitle_engine_');
    checkpoints = await Directory(
      path.join(support.path, 'subtitle_progress'),
    ).create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => support.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });

  test(
    'unchanged translation restores its completed checkpoint',
    () async {
      final file = _checkpoint(checkpoints, _source);
      await _writeCompleted(file, _source);
      final models = _PendingModels();
      final draft = await SubtitleAiEngine(
        models: models,
      ).prepareTranslation([_source], 'zh', trackPath: 'audio.mp3');
      expect(draft.cues.single.start, _source.start);
      expect(draft.cues.single.end, _source.end);
      expect(draft.cues.single.text, contains('今天一起睡吧。'));
      expect(models.progress, isEmpty);
      expect(await file.exists(), isTrue);
    },
    skip: !Platform.isWindows && !Platform.isAndroid,
  );

  test(
    'changed cue times discard old and legacy checkpoints only for that source',
    () async {
      final old = _checkpoint(checkpoints, _source);
      await _writeCompleted(old, _source);
      final legacyHash = sha256
          .convert(utf8.encode('audio.mp3|zh|${jsonEncode([_source.text])}'))
          .toString();
      final legacy = File(path.join(checkpoints.path, '$legacyHash.json'));
      await legacy.writeAsString('{}');
      final unrelated = File(
        path.join(
          checkpoints.path,
          '${_sourceKey('other.mp3', 'zh')}_v2_other.json',
        ),
      );
      await unrelated.writeAsString('{}');
      final models = _PendingModels();
      final cancelled = Completer<void>();
      var requested = false;
      final task = SubtitleAiEngine(models: models).prepareTranslation(
        [
          SubtitleCue(
            start: const Duration(seconds: 5),
            end: const Duration(seconds: 7),
            text: _source.text,
          ),
        ],
        'zh',
        trackPath: 'audio.mp3',
        isCancelled: () => requested,
        cancellation: cancelled.future,
      );
      final assertion = expectLater(
        task,
        throwsA(isA<SubtitleTaskCancelled>()),
      );
      await _waitUntil(() => models.progress.isNotEmpty);
      expect(await old.exists(), isFalse);
      expect(await legacy.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      requested = true;
      cancelled.complete();
      await assertion;
      models.result.completeError(StateError('late shared download failure'));
      await Future<void>.delayed(Duration.zero);
    },
    skip: !Platform.isWindows && !Platform.isAndroid,
  );

  test(
    'changed timing discards a partially translated checkpoint',
    () async {
      const second = SubtitleCue(
        start: Duration(seconds: 8),
        end: Duration(seconds: 10),
        text: '次の台詞です。',
      );
      final partial = _checkpoint(checkpoints, _source, remaining: [second]);
      await _writeCompleted(partial, _source);
      final models = _PendingModels();
      final cancelled = Completer<void>();
      var requested = false;
      final task = SubtitleAiEngine(models: models).prepareTranslation(
        [
          SubtitleCue(
            start: const Duration(seconds: 5),
            end: const Duration(seconds: 7),
            text: _source.text,
          ),
          second,
        ],
        'zh',
        trackPath: 'audio.mp3',
        isCancelled: () => requested,
        cancellation: cancelled.future,
      );
      final assertion = expectLater(
        task,
        throwsA(isA<SubtitleTaskCancelled>()),
      );
      await _waitUntil(() => models.progress.isNotEmpty);
      expect(await partial.exists(), isFalse);
      requested = true;
      cancelled.complete();
      await assertion;
      models.result.complete('unused-model.gguf');
      await Future<void>.delayed(Duration.zero);
    },
    skip: !Platform.isWindows && !Platform.isAndroid,
  );

  for (final script in [false, true]) {
    test(
      '${script ? 'script' : 'translation'} model wait cancels without blocking a new shared waiter',
      () async {
        final models = _PendingModels();
        final service = PlaybackSubtitleService(
          trackResolver: (_) => null,
          aiEngine: SubtitleAiEngine(models: models, files: _ScriptFiles()),
          subtitleLoader: (_, _) async =>
              SubtitleTrack(sourcePath: 'source.srt', cues: [_source]),
          subtitlesDirectoryResolver: () async => support,
        );
        bool start() => script
            ? service.startScriptGeneration('audio.mp3', 'script.txt')
            : service.startTranslationGeneration('audio.mp3', 'zh');
        expect(start(), isTrue);
        await _waitUntil(() => models.progress.length == 1);
        models.progress.first(0.2, 20, 100);
        final first = service.generationJob!;
        service.cancelGeneration();
        await _waitUntil(
          () => first.status == SubtitleGenerationStatus.cancelled,
        );
        expect(models.result.isCompleted, isFalse);
        expect(start(), isTrue);
        await _waitUntil(() => models.progress.length == 2);
        models.progress.first(0.8, 80, 100);
        expect(first.progress?.fraction, 0.2);
        expect(service.generationJob!.progress, isNull);
        models.progress.last(0.6, 60, 100);
        expect(service.generationJob!.progress?.fraction, 0.6);
        models.result.completeError(StateError('shared model unavailable'));
        await _waitUntil(
          () =>
              service.generationJob!.status == SubtitleGenerationStatus.failed,
        );
        expect(first.status, SubtitleGenerationStatus.cancelled);
        expect(
          service.generationJob!.errorMessage,
          contains('shared model unavailable'),
        );
        expect(service.getCustomSubtitlePath('audio.mp3'), isNull);
        service.dispose();
      },
      skip: !Platform.isWindows && !Platform.isAndroid,
    );
  }
}
