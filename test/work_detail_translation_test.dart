import 'dart:async';

import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/core/widgets/page_translation_scope.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_breadcrumbs.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entry_tile.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_playback_commands.dart';

class _TranslationCall {
  _TranslationCall(this.texts, this.target, this.request);
  final List<String> texts;
  final String target;
  final TextTranslationRequest request;
  final result = Completer<TextTranslationResult>();

  void complete({
    TextTranslationFailure? failure,
    Map<String, String> overrides = const {},
  }) {
    result.complete(
      TextTranslationResult(
        translations: failure == null
            ? {for (final text in texts) text: '$target:$text', ...overrides}
            : const {},
        failure: failure,
      ),
    );
  }
}

class _TranslationService extends TextTranslationService {
  final calls = <_TranslationCall>[];

  @override
  String? cached(String text, String target, {String source = 'auto'}) => null;

  @override
  Future<TextTranslationResult> translate(
    List<String> texts, {
    required String target,
    String source = 'auto',
    required TextTranslationRequest request,
  }) {
    final call = _TranslationCall(List.of(texts), target, request);
    calls.add(call);
    return call.result.future;
  }
}

const _button = ValueKey('work_detail_translation');

Future<void> _batch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

Future<void> _settleDirectory(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (i > 3 &&
        find
            .byKey(const ValueKey('work_detail_entries_skeleton'))
            .evaluate()
            .isEmpty &&
        !tester.binding.hasScheduledFrame) {
      break;
    }
  }
}

Widget _scope({Widget? child}) => WorkPageTranslationHost(
  child: Column(
    children: [
      const WorkPageTranslationButton(),
      child ?? const WorkPageTranslationText('Original title'),
    ],
  ),
);

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(
    () async => database = await AppRuntimeTestFixture.installSharedDatabase(),
  );
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final hosted in [false, true]) {
    testWidgets(
      'inactive untranslated text keeps its content without rebuilding (hosted: $hosted)',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final active = ValueNotifier(true);
        addTearDown(active.dispose);
        var builds = 0;
        final text = WorkPageTranslationBuilder(
          texts: const ['Original title'],
          builder: (context, translate, enabled) {
            builds++;
            return Text(translate('Original title'));
          },
        );
        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: active,
              child: hosted ? WorkPageTranslationHost(child: text) : text,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final initialBuilds = builds;
        active.value = false;
        await tester.pumpAndSettle();
        active.value = true;
        await tester.pumpAndSettle();
        expect(builds, initialBuilds);
        expect(find.text('Original title'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('runtime shares translation service with subtitle engine', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    TextTranslationService? shared;
    await tester.pumpWidget(
      fixture.build(
        Consumer(
          builder: (context, ref, _) {
            shared = ref.read(textTranslationServiceProvider);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(shared, same(fixture.runtimeGraph.subtitles.translationService));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'detail translation preserves metadata and navigation on $platform',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(360, 800)
            : const Size(960, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final played = <String>[];
        fixture.playback.detachCommandPort();
        fixture.playback.attachPlaybackCommands(
          prepareSession:
              (
                session, {
                required nextPath,
                autoPlay = true,
                forceStartAtZero = false,
                showLoading = true,
                targetQueueIndex,
              }) async {
                played.add(nextPath);
                session.currentTrackPath = nextPath;
                return true;
              },
          pauseSession: (_) async {},
          startSession: (_, {required shouldStartTriggerCountdown}) async =>
              true,
          resolveAdvance: (_, {required forward}) => null,
          hasAdjacent: (_, {required forward}) => false,
        );
        final service = _TranslationService();
        const folder = 'C:/translation/local';
        final target = AudioDetailTarget.libraryRootFolder(folder);
        final detail = AudioDetail.empty(target).copyWith(
          workTitle: 'Original title',
          circleName: 'Original circle',
          voiceActors: ['Voice actor'],
          tags: ['Original tag'],
        );
        final track = MusicTrack(
          path: '$folder/Original directory/Original audio.mp3',
          displayName: 'Original audio.mp3',
          groupKey: folder,
          groupTitle: 'Original title',
          groupSubtitle: '',
          isSingle: false,
        );
        fixture.library.addWatchedFolder(folder, notify: false);
        fixture.library.addTracks([track], persist: false);
        await tester.runAsync(() async {
          await fixture.library.loadLibraryFolderTree(folder);
          await WorkDirectoryInput.local(
            root: fixture.library.resolvedLibraryFolderTree(folder),
            texts: const [],
            images: const [],
            folderPath: folder,
          ).load();
        });
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notificationsChannel,
          (_) async => {'ok': true},
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            notificationsChannel,
            null,
          ),
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          fixture.build(
            MediaQuery(
              data: MediaQueryData(
                size: tester.view.physicalSize,
                textScaler: const TextScaler.linear(1.5),
              ),
              child: WorkDetailPage.forLocal(
                target: target,
                initialDetail: detail,
              ),
            ),
            overrides: [
              textTranslationServiceProvider.overrideWithValue(service),
            ],
          ),
        );
        expect(find.byKey(_button), findsOneWidget);
        expect(find.byIcon(Icons.translate), findsOneWidget);
        await _settleDirectory(tester);
        expect(find.text('Original title'), findsOneWidget);
        expect(service.calls, isEmpty);
        expect(find.byKey(_button), findsOneWidget);
        final translationRect = tester.getRect(find.byKey(_button));
        final editRect = tester.getRect(
          find.byKey(const ValueKey('work_detail_edit')),
        );
        expect(translationRect.left, greaterThanOrEqualTo(editRect.right));
        expect(translationRect.top, lessThan(80));
        await tester.tap(find.byKey(_button));
        await _batch(tester);
        expect(
          service.calls.single.texts,
          containsAll(['Original title', 'Original tag', 'Original directory']),
        );
        expect(service.calls.single.texts, isNot(contains('Voice actor')));
        expect(service.calls.single.texts, isNot(contains('Original circle')));
        service.calls.single.complete();
        await _batch(tester);
        expect(find.text('zh-CN:Original title'), findsOneWidget);
        expect(find.text('Voice actor'), findsOneWidget);
        expect(find.text('Original circle'), findsOneWidget);
        expect(find.text('zh-CN:Original circle'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('work_detail_tag_#Original tag')),
        );
        await tester.pump();
        expect(copied, contains('Original tag'));
        await tester.tap(find.text('zh-CN:Original directory'));
        await _batch(tester);
        expect(
          tester
              .widget<WorkDetailBreadcrumbs>(find.byType(WorkDetailBreadcrumbs))
              .segments,
          ['Original directory'],
        );
        expect(service.calls.last.texts, contains('Original audio'));
        service.calls.last.complete();
        await _batch(tester);
        expect(find.text('zh-CN:Original audio.mp3'), findsOneWidget);
        final tile = tester.widget<WorkDetailEntryTile>(
          find.byType(WorkDetailEntryTile),
        );
        expect(tile.item.track?.path, track.path);
        expect(tile.item.name, 'Original audio.mp3');
        expect(fixture.library.library.single.displayName, track.displayName);
        await tester.tap(find.text('zh-CN:Original audio.mp3'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(played, [track.path]);
        await tester.tap(find.byKey(_button));
        await tester.pump();
        expect(find.text('Original title'), findsOneWidget);
        expect(find.text('Original audio.mp3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'online detail has one rightmost translation entry on $platform',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(360, 800)
            : const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final service = _TranslationService();
        final work = AsmrWork(
          id: 123456,
          title: 'Online title',
          circleName: 'Online circle',
          sourceId: 'RJ123456',
          sourceType: 'asmr',
          sourceUrl: '',
          coverUrl: '',
          thumbnailUrl: '',
          mainCoverUrl: '',
          releaseDate: null,
          createDate: null,
          duration: Duration.zero,
          dlCount: 0,
          reviewCount: 0,
          rating: 0,
          voiceActors: const ['Voice actor'],
          tags: const ['Tag'],
        );
        await tester.pumpWidget(
          fixture.build(
            WorkDetailPage.forAsmr(work: work),
            overrides: [
              textTranslationServiceProvider.overrideWithValue(service),
            ],
          ),
        );
        expect(find.byKey(_button), findsOneWidget);
        expect(find.byIcon(Icons.translate), findsOneWidget);
        await _settleDirectory(tester);
        expect(find.text('Online title'), findsOneWidget);
        expect(service.calls, isEmpty);
        expect(find.byKey(_button), findsOneWidget);
        final button = tester.getRect(find.byKey(_button));
        final subtitle = tester.getRect(
          find.byKey(const ValueKey('work_detail_subtitle_status')),
        );
        expect(button.left, greaterThanOrEqualTo(subtitle.right));
        expect(button.top, lessThan(80));
        await tester.tap(find.byKey(_button));
        await _batch(tester);
        expect(service.calls.single.texts, isNot(contains('RJ123456')));
        expect(service.calls.single.texts, isNot(contains('Online circle')));
        expect(service.calls.single.texts, isNot(contains('Voice actor')));
        final longTitle = 'Translated title with a long description ' * 12;
        service.calls.single.complete(overrides: {'Online title': longTitle});
        await _batch(tester);
        expect(find.text(longTitle), findsOneWidget);
        expect(find.text('Online circle'), findsOneWidget);
        expect(find.text('Voice actor'), findsOneWidget);
        expect(find.text('zh-CN:Online circle'), findsNothing);
        expect(work.title, 'Online title');
        await tester.tap(find.byKey(_button));
        await tester.pump();
        expect(find.text('Online title'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'cancelling loading ignores late results and reopening starts original',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final service = _TranslationService();
      await tester.pumpWidget(
        fixture.build(
          _scope(),
          overrides: [
            textTranslationServiceProvider.overrideWithValue(service),
          ],
        ),
      );
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      expect(
        find.byKey(const ValueKey('work_detail_translation_loading')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_button));
      await tester.pump();
      expect(service.calls.single.request.cancelled, isTrue);
      service.calls.single.complete();
      await _batch(tester);
      expect(find.text('Original title'), findsOneWidget);
      expect(find.text('zh-CN:Original title'), findsNothing);
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      final leaving = service.calls.last;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(leaving.request.cancelled, isTrue);
      leaving.complete();
      await _batch(tester);
      await tester.pumpWidget(
        fixture.build(
          _scope(),
          overrides: [
            textTranslationServiceProvider.overrideWithValue(service),
          ],
        ),
      );
      await _batch(tester);
      expect(find.text('Original title'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work_detail_translation_loading')),
        findsNothing,
      );
      expect(service.calls, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden retained page cancels requests and resumes the enabled switch',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final service = _TranslationService();
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        fixture.build(
          ValueListenableBuilder<bool>(
            valueListenable: active,
            child: _scope(),
            builder: (_, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
          ),
          overrides: [
            textTranslationServiceProvider.overrideWithValue(service),
          ],
        ),
      );
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      final first = service.calls.single;
      active.value = false;
      await _batch(tester);
      expect(first.request.cancelled, isTrue);
      first.complete();
      await _batch(tester);
      expect(find.text('Original title'), findsOneWidget);
      expect(service.calls, hasLength(1));
      active.value = true;
      await _batch(tester);
      expect(service.calls, hasLength(2));
      service.calls.last.complete();
      await _batch(tester);
      expect(find.text('zh-CN:Original title'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('retained categories register only their active text', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final service = _TranslationService();
    final firstActive = ValueNotifier(true);
    addTearDown(firstActive.dispose);
    await tester.pumpWidget(
      fixture.build(
        _scope(
          child: ValueListenableBuilder<bool>(
            valueListenable: firstActive,
            builder: (_, first, _) => Column(
              children: [
                TickerMode(
                  enabled: first,
                  child: const WorkPageTranslationText('First category'),
                ),
                TickerMode(
                  enabled: !first,
                  child: const WorkPageTranslationText('Second category'),
                ),
              ],
            ),
          ),
        ),
        overrides: [textTranslationServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    expect(service.calls.single.texts, ['First category']);
    firstActive.value = false;
    await tester.pump();
    service.calls.single.complete();
    await _batch(tester);
    expect(service.calls, hasLength(2));
    expect(service.calls.last.texts, ['Second category']);
    service.calls.last.complete();
    await _batch(tester);
    expect(find.text('zh-CN:First category'), findsNothing);
    expect(find.text('zh-CN:Second category'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'language changes cancel old results and request current language',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final service = _TranslationService();
      await tester.pumpWidget(
        fixture.build(
          _scope(),
          overrides: [
            textTranslationServiceProvider.overrideWithValue(service),
          ],
        ),
      );
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      final first = service.calls.single;
      await fixture.languageProvider.setLanguage(AppLanguage.ja);
      await _batch(tester);
      expect(first.request.cancelled, isTrue);
      expect(service.calls.last.target, 'ja');
      first.complete();
      service.calls.last.complete();
      await _batch(tester);
      expect(find.text('ja:Original title'), findsOneWidget);
      expect(find.text('zh-CN:Original title'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scrolling registers new visible text without duplicate in-flight requests',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final service = _TranslationService();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        fixture.build(
          _scope(
            child: Expanded(
              child: ListView.builder(
                controller: scroll,
                itemExtent: 80,
                itemCount: 80,
                itemBuilder: (_, index) =>
                    WorkPageTranslationText('Track $index'),
              ),
            ),
          ),
          overrides: [
            textTranslationServiceProvider.overrideWithValue(service),
          ],
        ),
      );
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      final first = service.calls.single;
      expect(first.texts, contains('Track 0'));
      expect(first.texts, isNot(contains('Track 79')));
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await _batch(tester);
      expect(service.calls, hasLength(1));
      first.complete();
      await _batch(tester);
      expect(service.calls, hasLength(2));
      expect(service.calls.last.texts, contains('Track 79'));
      expect(
        service.calls.last.texts.toSet().intersection(first.texts.toSet()),
        isEmpty,
      );
      service.calls.last.complete();
      await _batch(tester);
      expect(find.text('zh-CN:Track 79'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('covered route and background cancel then resume missing text', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final service = _TranslationService();
    await tester.pumpWidget(
      fixture.build(
        _scope(),
        overrides: [textTranslationServiceProvider.overrideWithValue(service)],
      ),
    );
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    final navigator = Navigator.of(tester.element(find.byKey(_button)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.calls.first.request.cancelled, isTrue);
    service.calls.first.complete();
    await _batch(tester);
    expect(service.calls, hasLength(1));
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _batch(tester);
    final resumed = service.calls.last;
    expect(service.calls, hasLength(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(resumed.request.cancelled, isTrue);
    resumed.complete();
    await _batch(tester);
    expect(service.calls, hasLength(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _batch(tester);
    expect(service.calls, hasLength(3));
    service.calls.last.complete();
    await _batch(tester);
    expect(find.text('zh-CN:Original title'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'failed translations preserve original and require explicit retry',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final service = _TranslationService();
      await tester.pumpWidget(
        fixture.build(
          _scope(),
          overrides: [
            textTranslationServiceProvider.overrideWithValue(service),
          ],
        ),
      );
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      service.calls.single.complete(
        failure: TextTranslationFailure.unavailable,
      );
      await _batch(tester);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Original title'), findsOneWidget);
      expect(service.calls, hasLength(1));
      await tester.tap(find.byKey(_button));
      await tester.pump();
      await tester.tap(find.byKey(_button));
      await _batch(tester);
      expect(service.calls, hasLength(2));
      service.calls.last.complete();
      await _batch(tester);
      expect(find.text('zh-CN:Original title'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
