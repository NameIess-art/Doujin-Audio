import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:doujin_audio/features/player/presentation/playlist/subtitle_generation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSubtitleAiEngine extends SubtitleAiEngine {
  _FakeSubtitleAiEngine({super.models});

  final scriptResult = Completer<SubtitleDraft?>();
  final translationResult = Completer<SubtitleDraft>();
  void Function(SubtitleTaskProgress)? scriptProgress;
  void Function(SubtitleTaskProgress)? translationProgress;
  bool Function()? scriptCancelled;

  @override
  Future<SubtitleDraft?> prepareScript(
    String trackPath,
    String scriptPath, {
    void Function(SubtitleTaskProgress)? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) {
    scriptProgress = onProgress;
    scriptCancelled = isCancelled;
    return scriptResult.future;
  }

  @override
  Future<SubtitleDraft> prepareTranslation(
    List<SubtitleCue> source,
    String targetLanguage, {
    required String trackPath,
    void Function(SubtitleTaskProgress)? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) {
    translationProgress = onProgress;
    return translationResult.future;
  }
}

class _FakeModelStore extends SubtitleModelStore {
  SubtitleModelDownloadSnapshot? current;

  @override
  SubtitleModelDownloadSnapshot snapshot(SubtitleModelSpec spec) =>
      current ?? super.snapshot(spec);

  void update(SubtitleModelDownloadSnapshot progress) {
    current = progress;
    notifyListeners();
  }
}

const _japaneseCue = SubtitleCue(
  start: Duration(seconds: 1),
  end: Duration(seconds: 3),
  text: '今日は天気がいいですね。どこへ行きましょうか。',
);
const _laterJapaneseCue = SubtitleCue(
  start: Duration(seconds: 6),
  end: Duration(seconds: 8),
  text: '次の台詞です。',
);

Future<void> _waitForGeneration(PlaybackSubtitleService service) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (service.generationJob?.status != SubtitleGenerationStatus.running) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Subtitle generation did not finish');
}

void main() {
  late Directory subtitleDir;
  late String audioPath;
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    subtitleDir = await Directory.systemTemp.createTemp('generated_subtitles_');
    final audioFile = File(p.join(subtitleDir.path, 'audio', 'audio.mp3'));
    await audioFile.parent.create();
    await audioFile.writeAsBytes([0]);
    audioPath = audioFile.path;
  });
  tearDown(() => subtitleDir.delete(recursive: true));

  test(
    'script task saves and reloads subtitles without a menu listener',
    () async {
      final engine = _FakeSubtitleAiEngine();
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        aiEngine: engine,
        subtitlesDirectoryResolver: () async => subtitleDir,
      );
      var applied = false;
      expect(
        service.startScriptGeneration(
          audioPath,
          'script.txt',
          onApplied: () => applied = true,
        ),
        isTrue,
      );
      expect(service.startScriptGeneration('other.mp3', 'other.txt'), isFalse);
      await Future<void>.delayed(Duration.zero);
      engine.scriptProgress!(
        const SubtitleTaskProgress('matching', 0.5, '50%'),
      );
      expect(service.generationJob?.progress?.fraction, 0.5);
      expect(engine.scriptCancelled!(), isFalse);

      const draft = SubtitleDraft(
        cues: [_japaneseCue, _laterJapaneseCue],
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
      );
      engine.scriptResult.complete(draft);
      await _waitForGeneration(service);
      expect(service.generationJob?.status, SubtitleGenerationStatus.completed);
      expect(applied, isTrue);
      final savedPath = service.trackSync(audioPath)!.sourcePath;
      expect(savedPath, p.setExtension(audioPath, '.lrc'));
      expect(await File(savedPath).readAsString(), contains('今日は天気'));
      expect(service.textAt(audioPath, const Duration(seconds: 4)), isNull);
      final restarted = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitlesDirectoryResolver: () async => subtitleDir,
      );
      expect((await restarted.load(audioPath))?.sourcePath, savedPath);
      expect(
        restarted.textAt(audioPath, const Duration(seconds: 2)),
        _japaneseCue.text,
      );
      expect(restarted.textAt(audioPath, const Duration(seconds: 4)), isNull);
      expect(
        restarted.textAt(audioPath, const Duration(seconds: 7)),
        _laterJapaneseCue.text,
      );
      service.clearGenerationJob();
      expect(service.generationJob, isNull);
    },
  );

  test('script is saved only after complete alignment', () async {
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitleLoader: (_, _) async =>
          SubtitleTrack(sourcePath: 'old.srt', cues: const [_japaneseCue]),
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    await service.load(audioPath);
    var appliedCount = 0;
    service.startScriptGeneration(
      audioPath,
      'script.txt',
      onApplied: () => appliedCount++,
    );
    await Future<void>.delayed(Duration.zero);
    expect(await File(p.setExtension(audioPath, '.lrc')).exists(), isFalse);
    expect(service.trackSync(audioPath)?.sourcePath, 'old.srt');
    expect(service.generationJob?.status, SubtitleGenerationStatus.running);
    expect(appliedCount, 0);

    engine.scriptResult.complete(
      const SubtitleDraft(
        cues: [_japaneseCue, _laterJapaneseCue],
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
      ),
    );
    await _waitForGeneration(service);
    final savedPath = service.trackSync(audioPath)!.sourcePath;
    expect(service.generationJob?.status, SubtitleGenerationStatus.completed);
    expect(savedPath, p.setExtension(audioPath, '.lrc'));
    expect(await File(savedPath).readAsString(), contains('次の台詞'));
    expect(appliedCount, 1);
  });

  test('late automatic subtitle load cannot replace a generated LRC', () async {
    final oldLoad = Completer<SubtitleTrack?>();
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) => oldLoad.future,
      aiEngine: engine,
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    final pendingLoad = service.load(audioPath);
    service.startScriptGeneration(audioPath, 'script.txt');
    engine.scriptResult.complete(
      const SubtitleDraft(
        cues: [_japaneseCue],
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
      ),
    );
    await _waitForGeneration(service);
    final generatedPath = service.trackSync(audioPath)?.sourcePath;
    expect(generatedPath, isNotNull);
    oldLoad.complete(
      SubtitleTrack(sourcePath: 'old.srt', cues: const [_japaneseCue]),
    );
    expect((await pendingLoad)?.sourcePath, generatedPath);
    expect(service.trackSync(audioPath)?.sourcePath, generatedPath);
    expect(await File(generatedPath!).exists(), isTrue);
  });

  test('translation task saves and applies bilingual subtitles', () async {
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitleLoader: (_, _) async =>
          SubtitleTrack(sourcePath: 'source.srt', cues: const [_japaneseCue]),
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    expect(service.startTranslationGeneration(audioPath, 'zh'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    engine.translationProgress!(
      const SubtitleTaskProgress('translating', 0.75, '75%'),
    );
    expect(service.generationJob?.progress?.message, '75%');
    const draft = SubtitleDraft(
      cues: [
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: '今日は天気がいいですね。どこへ行きましょうか。\n今天天气不错。',
        ),
      ],
      kind: SubtitleDraftKind.translation,
      sourceLanguage: 'ja',
      targetLanguage: 'zh',
    );
    engine.translationResult.complete(draft);
    await _waitForGeneration(service);
    expect(
      service.generationJob?.status,
      SubtitleGenerationStatus.completed,
      reason: 'stage=${service.generationJob?.progress?.stage}',
    );
    final savedPath = service.trackSync(audioPath)!.sourcePath;
    expect(savedPath, p.setExtension(audioPath, '.srt'));
    expect(await File(savedPath).readAsString(), contains('今天天气'));
    expect(
      service.trackSync(audioPath)?.cues.single.text,
      draft.cues.single.text,
    );
    expect(
      (await service.japaneseSourceCues(audioPath)).single.text,
      _japaneseCue.text,
    );
  });

  test(
    'no reliable script match leaves the active subtitle unchanged',
    () async {
      final engine = _FakeSubtitleAiEngine();
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        aiEngine: engine,
        subtitlesDirectoryResolver: () async => subtitleDir,
        subtitleLoader: (_, _) async => SubtitleTrack(
          sourcePath: 'existing.srt',
          cues: const [_japaneseCue],
        ),
      );
      await service.load(audioPath);
      var applied = false;
      service.startScriptGeneration(
        audioPath,
        'wrong-script.txt',
        onApplied: () => applied = true,
      );
      engine.scriptResult.complete(null);
      await _waitForGeneration(service);
      expect(service.generationJob?.status, SubtitleGenerationStatus.noMatch);
      expect(await File(p.setExtension(audioPath, '.lrc')).exists(), isFalse);
      expect(service.trackSync(audioPath)?.sourcePath, 'existing.srt');
      expect(applied, isFalse);
    },
  );

  test('explicit pause marks the task cancelled', () async {
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    service.startScriptGeneration(audioPath, 'script.txt');
    await Future<void>.delayed(Duration.zero);
    service.cancelGeneration();
    expect(engine.scriptCancelled!(), isTrue);
    engine.scriptResult.complete(
      const SubtitleDraft(
        cues: [_japaneseCue],
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.generationJob?.status, SubtitleGenerationStatus.cancelled);
    expect(service.trackSync(audioPath)?.sourcePath, isNull);
    expect(await File(p.setExtension(audioPath, '.lrc')).exists(), isFalse);
  });

  test('cancelled alignment retains the active subtitle', () async {
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitleLoader: (_, _) async =>
          SubtitleTrack(sourcePath: 'old.srt', cues: const [_japaneseCue]),
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    await service.load(audioPath);
    service.startScriptGeneration(audioPath, 'script.txt');
    await Future<void>.delayed(Duration.zero);
    service.cancelGeneration();
    engine.scriptResult.completeError(const SubtitleTaskCancelled());
    await _waitForGeneration(service);
    expect(service.generationJob?.status, SubtitleGenerationStatus.cancelled);
    expect(await File(p.setExtension(audioPath, '.lrc')).exists(), isFalse);
    expect(service.trackSync(audioPath)?.sourcePath, 'old.srt');
  });

  testWidgets('dialog updates live and background action leaves task running', (
    tester,
  ) async {
    final models = _FakeModelStore();
    final engine = _FakeSubtitleAiEngine(models: models);
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    final language = AppLanguageProvider();
    service.startScriptGeneration(audioPath, 'script.txt');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => SubtitleGenerationDialog(service: service),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 300));
    engine.scriptProgress!(
      const SubtitleTaskProgress('download', 0.5, '1 / 2 MiB'),
    );
    models.update(
      const SubtitleModelDownloadSnapshot(
        received: 1048576,
        total: 2097152,
        active: true,
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('subtitle_generation_progress')),
          )
          .value,
      0.5,
    );
    engine.scriptProgress!(const SubtitleTaskProgress('matching', 0.5, '50%'));
    await tester.pump();
    expect(find.text(language.tr('subtitle_stage_matching')), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('subtitle_generation_progress')),
          )
          .value,
      0.5,
    );
    await tester.tap(find.text(language.tr('subtitle_run_in_background')));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleGenerationDialog), findsNothing);
    expect(engine.scriptCancelled!(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(engine.scriptCancelled!(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    engine.scriptResult.complete(
      const SubtitleDraft(
        cues: [_japaneseCue],
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
      ),
    );
    for (var attempt = 0; attempt < 100; attempt++) {
      if (service.generationJob?.status != SubtitleGenerationStatus.running) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(
      service.generationJob?.status,
      SubtitleGenerationStatus.completed,
      reason: 'stage=${service.generationJob?.progress?.stage}',
    );
    await tester.pump();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text(language.tr('subtitle_generation_ready')), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('translation dialog displays the live translation percent', (
    tester,
  ) async {
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitleLoader: (_, _) async =>
          SubtitleTrack(sourcePath: 'source.srt', cues: const [_japaneseCue]),
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    final language = AppLanguageProvider();
    service.startTranslationGeneration(audioPath, 'en');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
        ],
        child: MaterialApp(
          home: Scaffold(body: SubtitleGenerationDialog(service: service)),
        ),
      ),
    );
    await tester.pump();
    engine.translationProgress!(
      const SubtitleTaskProgress('translating', 0.25, '25%'),
    );
    await tester.pump();
    expect(
      find.text(language.tr('subtitle_stage_translating')),
      findsOneWidget,
    );
    expect(find.text('25%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('subtitle_generation_progress')),
          )
          .value,
      0.25,
    );
  });

  testWidgets('translation failure shows its actual error', (tester) async {
    final engine = _FakeSubtitleAiEngine();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      aiEngine: engine,
      subtitleLoader: (_, _) async =>
          SubtitleTrack(sourcePath: 'source.srt', cues: const [_japaneseCue]),
      subtitlesDirectoryResolver: () async => subtitleDir,
    );
    service.startTranslationGeneration(audioPath, 'zh');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            AppLanguageProvider(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: SubtitleGenerationDialog(service: service)),
        ),
      ),
    );
    await tester.pump();
    engine.translationResult.completeError(
      const FormatException('Translation count does not match source'),
    );
    await tester.pumpAndSettle();
    expect(service.generationJob?.status, SubtitleGenerationStatus.failed);
    expect(
      find.textContaining('Translation count does not match source'),
      findsOneWidget,
    );
  });
}
