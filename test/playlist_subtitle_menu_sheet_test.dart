import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// The plugin exposes its platform test seam from this library.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/domain/audio_detail_store.dart';
import 'package:doujin_audio/features/library/domain/library_persistence_repository.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_menu_sheet.dart';
import 'package:doujin_audio/features/player/presentation/playlist/subtitle_generation_dialog.dart';

final class _SubtitleFilePicker extends FilePickerPlatform {
  _SubtitleFilePicker(this.file);

  final File file;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => FilePickerResult([
    PlatformFile(
      name: file.uri.pathSegments.last,
      path: file.path,
      size: file.lengthSync(),
    ),
  ]);
}

Future<void> _waitForImportAction(
  WidgetTester tester,
  bool Function() finished,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (finished()) {
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
  }
  fail('Subtitle import did not finish');
}

class _ReadyModelStore extends SubtitleModelStore {
  @override
  Future<SubtitleModelStatus> status(SubtitleModelSpec spec) async =>
      const SubtitleModelStatus(ready: true, bytes: 0, availableBytes: null);
}

class _LibraryRepository extends Fake
    implements LibraryPersistenceRepository, AudioDetailStore {}

LibraryFacade _workLibrary(String folderPath, String trackPath) {
  final libraryService = LibraryService()
    ..watchedFolders.add(folderPath)
    ..libraryByPath[trackPath] = MusicTrack(
      path: trackPath,
      displayName: 'audio',
      groupKey: folderPath,
      groupTitle: 'work',
      groupSubtitle: folderPath,
      isSingle: false,
    );
  return LibraryFacade.create(
    databaseRepository: _LibraryRepository(),
    service: libraryService,
  );
}

class _WorkTexts extends WorkTextService {
  _WorkTexts(this.files);

  final List<WorkTextFile> files;
  String? requestedFolder;

  @override
  Future<List<WorkTextFile>> findWorkTextFiles(String workFolderPath) async {
    requestedFolder = workFolderPath;
    return files;
  }
}

class _ScriptSelectionService extends PlaybackSubtitleService {
  _ScriptSelectionService()
    : super(
        trackResolver: (_) => null,
        aiEngine: SubtitleAiEngine(models: _ReadyModelStore()),
      );

  String? selectedScript;

  @override
  bool startScriptGeneration(
    String trackPath,
    String scriptPath, {
    VoidCallback? onApplied,
  }) {
    selectedScript = scriptPath;
    return false;
  }
}

class _DelayedModelStore extends SubtitleModelStore {
  final checked = Completer<SubtitleModelStatus>();

  @override
  Future<SubtitleModelStatus> status(SubtitleModelSpec spec) => checked.future;
}

class _PendingGenerationEngine extends SubtitleAiEngine {
  _PendingGenerationEngine({SubtitleModelStore? models})
    : super(models: models ?? _ReadyModelStore());

  final result = Completer<SubtitleDraft>();

  @override
  Future<SubtitleDraft> prepareTranslation(
    List<SubtitleCue> source,
    String targetLanguage, {
    required String trackPath,
    void Function(SubtitleTaskProgress)? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) => result.future;
}

class _RecordingGenerationService extends PlaybackSubtitleService {
  _RecordingGenerationService(_PendingGenerationEngine engine)
    : super(
        trackResolver: (_) => null,
        aiEngine: engine,
        subtitleLoader: (_, _) async => SubtitleTrack(
          sourcePath: 'japanese.srt',
          cues: const [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: '今日は天気がいいですね。どこへ行きましょうか。',
            ),
          ],
        ),
      );
}

PlaybackSessionSnapshot _createSnapshot({required String trackPath}) {
  return PlaybackSessionSnapshot(
    id: 'test-session',
    createdAt: DateTime(2026),
    lastPlayedAt: null,
    currentTrackPath: trackPath,
    loadedPath: trackPath,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.crossSequential,
    volume: 1,
    channelSwapEnabled: false,
    position: Duration.zero,
    duration: const Duration(minutes: 1),
    bufferedPosition: Duration.zero,
    speed: 1,
    audioEffects: AudioEffectsState.flat,
    eqCapabilities: EqCapabilities.unsupported,
    state: const PlaybackStatus(
      playing: true,
      processing: PlaybackProcessingStatus.ready,
    ),
    effectivePlaying: true,
    playbackRequested: true,
    isLoading: false,
    isPlaybackLoading: false,
    playbackError: null,
    currentQueueIndex: 0,
    playbackQueue: null,
    customQueueTracks: null,
    positionStream: const Stream<Duration>.empty(),
    durationStream: const Stream<Duration?>.empty(),
    bufferedPositionStream: const Stream<Duration>.empty(),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final (name, hasExisting, confirm) in const [
    ('cancelled subtitle import preserves both files', true, false),
    ('confirmed subtitle import replaces and moves the local file', true, true),
    ('first subtitle import moves the file without confirmation', false, true),
  ]) {
    testWidgets(name, (tester) async {
      final root = Directory.systemTemp.createTempSync('subtitle_import_');
      addTearDown(() => root.deleteSync(recursive: true));
      final audioDirectory = Directory(p.join(root.path, 'audio'))
        ..createSync();
      final audioFile = File(p.join(audioDirectory.path, 'voice.mp3'))
        ..writeAsBytesSync([0]);
      final existing = File(p.join(audioDirectory.path, 'voice.ja.lrc'));
      const original = '[00:01.00]原字幕\n[00:03.00]\n';
      if (hasExisting) existing.writeAsStringSync(original);
      final selected = File(p.join(root.path, 'selected.srt'))
        ..writeAsStringSync('1\n00:00:01,000 --> 00:00:03,000\n新字幕\n');
      final destination = File(p.join(audioDirectory.path, 'voice.srt'));
      final previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _SubtitleFilePicker(selected);
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      await tester.runAsync(() => service.load(audioFile.path));
      final language = AppLanguageProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: _createSnapshot(trackPath: audioFile.path),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final importTile = find.byKey(const ValueKey('subtitle_import_tile'));
      await tester.ensureVisible(importTile);
      await tester.tap(importTile);
      await _waitForImportAction(
        tester,
        () => hasExisting
            ? find.byType(AlertDialog).evaluate().isNotEmpty
            : service.trackSync(audioFile.path)?.sourcePath == destination.path,
      );
      if (hasExisting) {
        expect(
          find.text(language.tr('subtitle_import_overwrite_title')),
          findsOneWidget,
        );
        expect(existing.readAsStringSync(), original);
        expect(selected.existsSync(), isTrue);
        expect(destination.existsSync(), isFalse);
        await tester.tap(
          find.text(
            language.tr(confirm ? 'subtitle_import_overwrite' : 'cancel'),
          ),
        );
        if (confirm) {
          await _waitForImportAction(
            tester,
            () =>
                service.trackSync(audioFile.path)?.sourcePath ==
                destination.path,
          );
        } else {
          await tester.pumpAndSettle();
          expect(existing.readAsStringSync(), original);
          expect(selected.existsSync(), isTrue);
          expect(destination.existsSync(), isFalse);
          expect(service.trackSync(audioFile.path)?.sourcePath, existing.path);
        }
      } else {
        expect(find.byType(AlertDialog), findsNothing);
      }
      if (confirm) {
        expect(selected.existsSync(), isFalse);
        expect(existing.existsSync(), isFalse);
        expect(destination.readAsStringSync(), contains('新字幕'));
        final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
        final reloaded = await tester.runAsync(
          () => restarted.load(audioFile.path),
        );
        expect(reloaded?.sourcePath, destination.path);
        expect(reloaded?.cues.single.text, '新字幕');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'SubtitleMenuSheet disables and greys out switches and sync controls when no subtitle',
    (tester) async {
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      final session = _createSnapshot(
        trackPath: '/path/to/no_subtitle_audio.mp3',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              AppLanguageProvider(),
            ),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: session,
                onToggleGlobalSubtitle: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find both SwitchListTiles
      final switchTiles = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList(growable: false);
      expect(switchTiles.length, 2);

      // Both switch tiles should be disabled (onChanged == null)
      expect(switchTiles[0].onChanged, isNull);
      expect(switchTiles[1].onChanged, isNull);

      // Verify sync buttons are all disabled (onPressed == null)
      final buttons = tester
          .widgetList<OutlinedButton>(find.byType(OutlinedButton))
          .toList(growable: false);
      // There are 5 sync control buttons
      expect(buttons.length, 5);
      for (final button in buttons) {
        expect(button.onPressed, isNull);
      }
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('subtitle_script_tile')),
            )
            .enabled,
        subtitleGenerationUnavailableReason == null,
      );
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('subtitle_translate_tile')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets(
    'SubtitleMenuSheet enables switches and sync controls when subtitle is present',
    (tester) async {
      const audioPath = '/path/to/has_subtitle_audio.mp3';
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (trackPath, track) async => SubtitleTrack(
          sourcePath: 'sub.lrc',
          cues: const [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 5),
              text:
                  'This is a long English subtitle without Japanese characters.',
            ),
          ],
        ),
      );

      await service.load(audioPath);

      final session = _createSnapshot(trackPath: audioPath);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              AppLanguageProvider(),
            ),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: session,
                onToggleGlobalSubtitle: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find both SwitchListTiles
      final switchTiles = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList(growable: false);
      expect(switchTiles.length, 2);

      // Both switch tiles should be enabled (onChanged != null)
      expect(switchTiles[0].onChanged, isNotNull);
      expect(switchTiles[1].onChanged, isNotNull);

      // Verify step sync buttons (-0.5s, -0.1s, +0.1s, +0.5s) are enabled
      final buttons = tester
          .widgetList<OutlinedButton>(find.byType(OutlinedButton))
          .toList(growable: false);
      expect(buttons.length, 5);
      expect(buttons[0].onPressed, isNotNull); // -0.5s
      expect(buttons[1].onPressed, isNotNull); // -0.1s
      // buttons[2] is reset, offset is zero so reset is null
      expect(buttons[3].onPressed, isNotNull); // +0.1s
      expect(buttons[4].onPressed, isNotNull); // +0.5s
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('subtitle_translate_tile')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets('SubtitleMenuSheet allows translating Japanese subtitles', (
    tester,
  ) async {
    const audioPath = '/path/to/japanese_audio.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (trackPath, track) async => SubtitleTrack(
        sourcePath: 'sub.srt',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 5),
            text: '今日は天気がいいですね。どこへ行きましょうか。',
          ),
        ],
      ),
    );
    await service.load(audioPath);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            AppLanguageProvider(),
          ),
          playbackSubtitleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleMenuSheet(
              session: _createSnapshot(trackPath: audioPath),
              generationUnavailableReason: () => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('subtitle_translate_tile')),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('ASMR.ONE subtitle edit entry is disabled', (tester) async {
    const audioPath = 'https://example.com/asmr.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (_) => MusicTrack(
        path: audioPath,
        displayName: 'ASMR audio',
        groupKey: 'work',
        groupTitle: 'Work',
        groupSubtitle: '',
        isSingle: false,
        remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
      ),
      subtitleLoader: (_, _) async => SubtitleTrack(
        sourcePath: 'remote.vtt',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: '字幕',
          ),
        ],
      ),
    );
    await service.load(audioPath);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            AppLanguageProvider(),
          ),
          playbackSubtitleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleMenuSheet(
              session: _createSnapshot(trackPath: audioPath),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('subtitle_edit_tile')))
          .enabled,
      isFalse,
    );
  });

  testWidgets(
    'translation opens progress immediately and can continue in background',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'subtitle_translation_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final audioFile = File('${directory.path}/japanese_audio.mp3')
        ..writeAsBytesSync([0]);
      final audioPath = audioFile.path;
      final models = _DelayedModelStore();
      final engine = _PendingGenerationEngine(models: models);
      final service = _RecordingGenerationService(engine);
      await service.load(audioPath);
      final language = AppLanguageProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: _createSnapshot(trackPath: audioPath),
                generationUnavailableReason: () => null,
              ),
            ),
          ),
        ),
      );
      final translation = find.byKey(const ValueKey('subtitle_translate_tile'));
      await tester.ensureVisible(translation);
      await tester.tap(translation);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      await tester.tap(find.text(language.tr('subtitle_language_zh')));
      await tester.pump();
      expect(
        find.descendant(
          of: translation,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      models.checked.complete(
        const SubtitleModelStatus(ready: true, bytes: 0, availableBytes: null),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.generationJob?.status, SubtitleGenerationStatus.running);
      expect(find.byType(SubtitleGenerationDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle_generation_progress')),
        findsOneWidget,
      );
      await tester.tap(find.text(language.tr('subtitle_run_in_background')));
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleGenerationDialog), findsNothing);
      expect(find.byType(SubtitleMenuSheet), findsOneWidget);
      engine.result.complete(
        const SubtitleDraft(
          cues: [],
          kind: SubtitleDraftKind.translation,
          sourceLanguage: 'ja',
          targetLanguage: 'zh',
        ),
      );
    },
  );

  testWidgets('SubtitleMenuSheet allows script matching for remote audio', (
    tester,
  ) async {
    final service = PlaybackSubtitleService(trackResolver: (_) => null);
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          playbackSubtitleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleMenuSheet(
              session: _createSnapshot(trackPath: 'https://example.com/a.mp3'),
              generationUnavailableReason: () => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('subtitle_script_tile')))
          .enabled,
      isTrue,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('subtitle_translate_tile')),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('script menu lists only TXT and MD files from the work', (
    tester,
  ) async {
    const folder = r'E:\作品\测试';
    const scriptPath = r'E:\作品\测试\台本\トラック１.md';
    final texts = _WorkTexts(const [
      WorkTextFile(
        name: '説明.TXT',
        relativePath: '説明.TXT',
        path: r'E:\作品\测试\説明.TXT',
      ),
      WorkTextFile(
        name: 'トラック１.md',
        relativePath: '台本/トラック１.md',
        path: scriptPath,
      ),
      WorkTextFile(
        name: 'book.pdf',
        relativePath: 'book.pdf',
        path: r'E:\作品\测试\book.pdf',
      ),
    ]);
    final service = _ScriptSelectionService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            AppLanguageProvider(),
          ),
          playbackSubtitleServiceProvider.overrideWithValue(service),
          libraryFacadeProvider.overrideWithValue(
            _workLibrary(folder, r'E:\作品\测试\01.mp3'),
          ),
          workTextServiceProvider.overrideWithValue(texts),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleMenuSheet(
              session: _createSnapshot(trackPath: r'E:\作品\测试\01.mp3'),
              generationUnavailableReason: () => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final script = find.byKey(const ValueKey('subtitle_script_tile'));
    await tester.ensureVisible(script);
    await tester.tap(script);
    await tester.pumpAndSettle();

    expect(texts.requestedFolder, folder);
    expect(
      find.byKey(const ValueKey('subtitle_script_selection')),
      findsOneWidget,
    );
    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.text('説明.TXT'), findsOneWidget);
    expect(find.text('台本/トラック１.md'), findsOneWidget);
    expect(find.text('book.pdf'), findsNothing);

    await tester.tap(find.text('台本/トラック１.md'));
    await tester.pumpAndSettle();
    expect(service.selectedScript, scriptPath);
  });

  testWidgets('script matching warns when the audio already has subtitles', (
    tester,
  ) async {
    const audioPath = '/path/to/subtitled_audio.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) async => SubtitleTrack(
        sourcePath: 'existing.lrc',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: '已有字幕',
          ),
        ],
      ),
    );
    await service.load(audioPath);
    final language = AppLanguageProvider();
    final texts = _WorkTexts(const [
      WorkTextFile(
        name: 'script.md',
        relativePath: 'script.md',
        path: '/path/to/script.md',
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          playbackSubtitleServiceProvider.overrideWithValue(service),
          libraryFacadeProvider.overrideWithValue(
            _workLibrary('/path/to', audioPath),
          ),
          workTextServiceProvider.overrideWithValue(texts),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleMenuSheet(
              session: _createSnapshot(trackPath: audioPath),
              generationUnavailableReason: () => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final script = find.byKey(const ValueKey('subtitle_script_tile'));
    await tester.ensureVisible(script);
    await tester.tap(script);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subtitle_script_selection')),
      findsOneWidget,
    );
    expect(find.byType(SimpleDialog), findsNothing);
    await tester.tap(find.text('script.md'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text(language.tr('subtitle_script_existing_title')),
      findsOneWidget,
    );
    expect(
      find.text(language.tr('subtitle_script_existing_hint')),
      findsOneWidget,
    );
    expect(find.text(language.tr('subtitle_script_continue')), findsOneWidget);

    await tester.tap(find.text(language.tr('cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SubtitleMenuSheet), findsOneWidget);
  });

  testWidgets('SubtitleMenuSheet asks before translating uncertain language', (
    tester,
  ) async {
    const audioPath = '/path/to/uncertain_audio.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (trackPath, track) async => SubtitleTrack(
        sourcePath: 'sub.srt',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 5),
            text: 'はい。',
          ),
        ],
      ),
    );
    await service.load(audioPath);
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          playbackSubtitleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleMenuSheet(
              session: _createSnapshot(trackPath: audioPath),
              generationUnavailableReason: () => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final translation = find.byKey(const ValueKey('subtitle_translate_tile'));
    expect(tester.widget<ListTile>(translation).enabled, isTrue);
    await tester.ensureVisible(translation);
    await tester.tap(translation);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(SimpleDialog), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text(language.tr('subtitle_language_zh')), findsOneWidget);
    expect(find.text(language.tr('subtitle_language_en')), findsOneWidget);
  });

  testWidgets('long subtitle filenames stay within the sheet while scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(550, 1096));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.physicalSize = const Size(550, 1096);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('subtitle_sheet_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final audioFile = File(
      '${directory.path}/very_long_subtitle_filename_with_multiple_words_and_japanese_字幕ファイル名を表示してもシート内に収まります.mp3',
    )..writeAsBytesSync([0]);
    final audioPath = audioFile.path;
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitlesDirectoryResolver: () async => directory,
    );
    await tester.runAsync(
      () => service.saveDraft(
        audioPath,
        const SubtitleDraft(
          kind: SubtitleDraftKind.script,
          sourceLanguage: 'ja',
          cues: [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: '字幕の本文です。',
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            AppLanguageProvider(),
          ),
          playbackSubtitleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showSubtitleMenuBottomSheet(
                  context: context,
                  session: _createSnapshot(trackPath: audioPath),
                  onToggleGlobalSubtitle: null,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('subtitle_version_tile')), findsNothing);
    final tile = find.byKey(const ValueKey('subtitle_import_tile'));
    final sheetTop = tester.getTopLeft(find.byType(BottomSheet)).dy;
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(SubtitleMenuSheet),
        matching: find.byType(Scrollable),
      ),
    );
    scrollable.position.jumpTo(
      scrollable.position.pixels + tester.getTopLeft(tile).dy - sheetTop - 8,
    );
    await tester.pump();
    expect(tester.getTopLeft(tile).dy, lessThan(sheetTop + 48));

    await tester.tapAt(Offset(tester.getCenter(tile).dx, sheetTop + 24));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final fileCount in [2, 30]) {
      testWidgets(
        'script selection keeps subtitle sheet geometry on $platform with $fileCount files',
        (tester) async {
          tester.view.physicalSize = platform == TargetPlatform.windows
              ? const Size(1280, 800)
              : const Size(375, 812);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const folder = '/library/work';
          const audioPath = '/library/work/audio.mp3';
          const scriptPath = '/library/work/script.md';
          final longScriptName =
              '${List.filled(6, '長い台本ファイル名_完整显示_test_').join()}notes.txt';
          final texts = _WorkTexts([
            WorkTextFile(
              name: longScriptName,
              relativePath: longScriptName,
              path: '/library/work/$longScriptName',
            ),
            const WorkTextFile(
              name: 'script.md',
              relativePath: 'subfolder/script.md',
              path: scriptPath,
            ),
            for (var index = 2; index < fileCount; index++)
              WorkTextFile(
                name: 'script_$index.md',
                relativePath: 'very_long_script_folder_name/script_$index.md',
                path: '/library/work/script_$index.md',
              ),
          ]);
          final service = _ScriptSelectionService();
          addTearDown(service.dispose);
          final language = AppLanguageProvider();
          await language.setLanguage(AppLanguage.zh);
          addTearDown(language.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appLanguageProviderInstanceProvider.overrideWithValue(language),
                playbackSubtitleServiceProvider.overrideWithValue(service),
                libraryFacadeProvider.overrideWithValue(
                  _workLibrary(folder, audioPath),
                ),
                workTextServiceProvider.overrideWithValue(texts),
              ],
              child: MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => AppBottomSheet.show<void>(
                        context: context,
                        builder: (_) => ClipRect(
                          child: SubtitleMenuSheet(
                            session: _createSnapshot(trackPath: audioPath),
                            generationUnavailableReason: () => null,
                          ),
                        ),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final sheet = find.byType(BottomSheet);
          final originalRect = tester.getRect(sheet);
          final header = find.byKey(const ValueKey('subtitle_script_header'));
          final originalHeaderStyle = tester
              .widget<Text>(find.text(language.tr('subtitles')))
              .style;
          final scriptTile = find.byKey(const ValueKey('subtitle_script_tile'));
          Future<void> openScriptSelection() async {
            await tester.ensureVisible(scriptTile);
            await tester.tap(scriptTile);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 150));
            final selectionFade = find
                .ancestor(
                  of: find.byKey(const ValueKey('subtitle_script_selection')),
                  matching: find.byType(FadeTransition),
                )
                .first;
            expect(
              tester.widget<FadeTransition>(selectionFade).opacity.value,
              closeTo(0.5, 0.03),
            );
            expect(tester.getRect(sheet), originalRect);
            await tester.pumpAndSettle();
          }

          await openScriptSelection();
          final selection = find.byKey(
            const ValueKey('subtitle_script_selection'),
          );
          final back = find.byKey(const ValueKey('subtitle_script_back'));
          expect(selection, findsOneWidget);
          expect(find.byType(SimpleDialog), findsNothing);
          expect(tester.getRect(sheet), originalRect);
          expect(
            find.text('台本选择'),
            findsOneWidget,
          );
          expect(find.text(language.tr('subtitle_script_hint')), findsOneWidget);
          expect(
            find.text(language.tr('subtitle_script_hint')).hitTestable(),
            findsNothing,
          );
          expect(
            tester
                .widget<Text>(
                  find.text('台本选择'),
                )
                .style,
            originalHeaderStyle,
          );
          expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
          expect(
            tester.getCenter(back).dx,
            greaterThan(tester.getCenter(header).dx),
          );
          expect(
            tester.getCenter(back).dy,
            closeTo(tester.getCenter(header).dy, 0.01),
          );
          final longTitle = find.text(longScriptName);
          expect(longTitle, findsOneWidget);
          expect(find.text('subfolder/script.md'), findsOneWidget);
          final longRow = find.ancestor(
            of: longTitle,
            matching: find.byType(ListTile),
          );
          final shortRow = find.ancestor(
            of: find.text('subfolder/script.md'),
            matching: find.byType(ListTile),
          );
          final longIcon = find.descendant(
            of: longRow,
            matching: find.byIcon(Icons.text_snippet_rounded),
          );
          expect(
            tester.renderObject<RenderParagraph>(longTitle).didExceedMaxLines,
            isFalse,
          );
          expect(
            tester.getSize(longRow).height,
            greaterThan(tester.getSize(shortRow).height),
          );
          expect(
            tester.getRect(longTitle).bottom,
            lessThanOrEqualTo(tester.getRect(longRow).bottom),
          );
          expect(
            tester.getTopLeft(longIcon).dy,
            closeTo(tester.getTopLeft(longTitle).dy, 0.01),
          );
          expect(
            tester.getCenter(longIcon).dx,
            lessThan(tester.getTopLeft(longTitle).dx),
          );
          expect(
            find.descendant(of: selection, matching: find.byType(Scrollbar)),
            findsNothing,
          );
          if (fileCount > 2) {
            final scrollable = tester.state<ScrollableState>(
              find.descendant(of: selection, matching: find.byType(Scrollable)),
            );
            expect(scrollable.position.maxScrollExtent, greaterThan(0));
            scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
            await tester.pump();
            expect(
              find
                  .text(
                    'very_long_script_folder_name/script_${fileCount - 1}.md',
                  )
                  .hitTestable(),
              findsOneWidget,
            );
            expect(tester.getRect(sheet), originalRect);
          }
          await tester.tap(back);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          expect(selection, findsOneWidget);
          expect(tester.getRect(sheet), originalRect);
          await tester.pumpAndSettle();
          expect(selection, findsNothing);
          expect(find.text(language.tr('subtitles')), findsOneWidget);
          expect(tester.getRect(sheet), originalRect);
          await openScriptSelection();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(selection, findsNothing);
          expect(sheet, findsOneWidget);
          expect(tester.getRect(sheet), originalRect);
          await openScriptSelection();
          await tester.tap(find.text('subfolder/script.md'));
          await tester.pumpAndSettle();
          expect(service.selectedScript, scriptPath);
          expect(selection, findsNothing);
          expect(sheet, findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(sheet, findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  testWidgets(
    'translation language dialog displays styled header, language badges, and close button',
    (tester) async {
      const audioPath = '/path/to/japanese_audio.mp3';
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (trackPath, track) async => SubtitleTrack(
          sourcePath: 'sub.srt',
          cues: const [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 5),
              text: '今日は天気がいいですね。どこへ行きましょうか。',
            ),
          ],
        ),
      );
      await service.load(audioPath);
      final language = AppLanguageProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: _createSnapshot(trackPath: audioPath),
                generationUnavailableReason: () => null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final translateTile = find.byKey(const ValueKey('subtitle_translate_tile'));
      await tester.ensureVisible(translateTile);
      await tester.tap(translateTile);
      await tester.pumpAndSettle();

      final dialogFinder = find.byType(SimpleDialog);
      expect(dialogFinder, findsOneWidget);
      expect(find.byIcon(Icons.translate_rounded), findsNWidgets(2)); // tile + dialog header
      expect(find.text(language.tr('subtitle_choose_language')), findsOneWidget);
      expect(find.text(language.tr('subtitle_translate_hint')), findsNWidgets(2));
      expect(find.text('ZH'), findsOneWidget);
      expect(find.text('EN'), findsOneWidget);
      expect(find.text(language.tr('subtitle_language_zh')), findsOneWidget);
      expect(find.text(language.tr('subtitle_language_en')), findsOneWidget);

      // Verify item highlight indicators are rounded rectangles conforming to items
      final langInkWells = tester.widgetList<InkWell>(
        find.descendant(
          of: dialogFinder,
          matching: find.byType(InkWell),
        ),
      ).where((i) => i.borderRadius != null).toList();
      expect(langInkWells, hasLength(2));
      for (final inkWell in langInkWells) {
        expect(inkWell.borderRadius, BorderRadius.circular(14));
      }

      final langMaterials = tester.widgetList<Material>(
        find.descendant(
          of: dialogFinder,
          matching: find.byType(Material),
        ),
      ).where((m) => m.shape is RoundedRectangleBorder && (m.shape as RoundedRectangleBorder).borderRadius == BorderRadius.circular(14));
      expect(langMaterials, hasLength(2));

      // Verify close button dismisses dialog
      final closeButton = find.descendant(
        of: dialogFinder,
        matching: find.byIcon(Icons.close_rounded),
      );
      expect(closeButton, findsOneWidget);
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
    },
  );
}
