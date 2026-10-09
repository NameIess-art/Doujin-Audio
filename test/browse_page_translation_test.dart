import 'dart:async';

import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/page_translation_scope.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'support/test_playback_commands.dart';

class _TranslationCall {
  _TranslationCall(this.texts, this.target, this.request);
  final List<String> texts;
  final String target;
  final TextTranslationRequest request;
  final result = Completer<TextTranslationResult>();

  void complete({TextTranslationFailure? failure}) => result.complete(
    TextTranslationResult(
      translations: failure == null
          ? {for (final text in texts) text: '$target:$text'}
          : const {},
      failure: failure,
    ),
  );
}

class _Translations extends TextTranslationService {
  bool hold = false;
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
    if (!hold) call.complete();
    return call.result.future;
  }
}

class _AsmrController extends AsmrLibraryController {
  _AsmrController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  AppLanguage _language = AppLanguage.zh;
  @override
  bool get initialized => true;
  @override
  AppLanguage get pageLanguage => _language;
  @override
  bool setPageLanguage(AppLanguage language) {
    _language = language;
    return false;
  }

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: const [
      AsmrCategoryType.collected,
      AsmrCategoryType.recommendation,
    ],
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: 0,
  );

  @override
  bool hasLoadedCategory(AsmrCategoryType category) => true;
  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {}
  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}
  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => AsmrCategoryViewState(
    category: category,
    works: [
      AsmrWork.fromJson({
        'id': category == AsmrCategoryType.collected ? 123456 : 654321,
        'title': category == AsmrCategoryType.collected
            ? 'Online title'
            : 'Recommendation title',
        'circle': const {'name': 'Online circle'},
        'vas': const [
          {'name': 'Online voice'},
        ],
        'tags': const [
          {'name': 'Online tag'},
        ],
      }),
    ],
    isLoading: false,
    isLoadingMore: false,
    isRefreshing: false,
    isStale: false,
    hasAttemptedLoad: true,
    hasMore: false,
    needsLoadMoreRetry: false,
    totalCount: 1,
    activeQuery: searchQuery,
    lastError: null,
    operationError: null,
    revision: 0,
  );
}

Future<void> _batch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

void _screen(WidgetTester tester, TargetPlatform platform) {
  tester.view.physicalSize = platform == TargetPlatform.android
      ? const Size(320, 800)
      : const Size(960, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _expectHeader(WidgetTester tester, String page) {
  Rect surface(String key) => tester.getRect(
    find.ancestor(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(HeaderFloatingButton),
    ),
  );
  final search = surface('${page}_search_button');
  final translation = surface('${page}_translation');
  expect(translation.left - search.right, 8);
  expect(translation.size, const Size(38, 38));
  expect(translation.center.dy, search.center.dy);
  expect(translation.right, lessThanOrEqualTo(tester.view.physicalSize.width));
  final left = page == 'asmr'
      ? find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>)
      : find.byType(HeaderActionPill);
  final leftRect = tester.getRect(left);
  expect(leftRect.center.dy, search.center.dy);
  expect(leftRect.right, lessThanOrEqualTo(search.left - 8));
  if (page == 'library' &&
      tester.view.physicalSize.height > tester.view.physicalSize.width) {
    final capsule = tester.getRect(
      find.descendant(of: left, matching: find.byType(HeaderFloatingSurface)),
    );
    final sort = surface('library_sort_button');
    expect(sort.right, tester.view.physicalSize.width - 16);
    expect(sort.left - translation.right, 8);
    expect(search.left, tester.view.physicalSize.width - 146);
    expect(search.left - capsule.right, greaterThanOrEqualTo(8));
    expect(capsule.left, 16);
  }
  if (page == 'asmr') {
    final labels = find.descendant(of: left, matching: find.byType(Text));
    expect(
      tester.getRect(labels.at(1)).left - tester.getRect(labels.at(0)).right,
      26,
    );
  } else {
    final edit = tester.getRect(
      find.byKey(const ValueKey('library_edit_button')),
    );
    final metadata = tester.getRect(
      find.byKey(const ValueKey('library_batch_metadata_button')),
    );
    expect(
      metadata.center.dx - edit.center.dx,
      tester.view.physicalSize.width >= 390 ? 48 : 28,
    );
    expect(metadata.right, lessThanOrEqualTo(search.left - 12));
    expect(find.byIcon(Icons.video_library_rounded), findsNothing);
  }
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(
    () async => database = await AppRuntimeTestFixture.installSharedDatabase(),
  );
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'browse headers translate metadata, retain independent switches and play original paths on $platform',
      (tester) async {
        _screen(tester, platform);
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _AsmrController(createTestAsmrServices());
        final translations = _Translations();
        final active = ValueNotifier(0);
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        addTearDown(active.dispose);
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
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notificationsChannel,
          (_) async => {'ok': true, 'value': null},
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            notificationsChannel,
            null,
          ),
        );
        const folder = 'C:/translation/library';
        final track = testMusicTrack(
          name: 'Original audio.mp3',
          path: '$folder/Original audio.mp3',
          groupKey: folder,
          groupTitle: 'Library title',
        );
        fixture.library.addWatchedFolder(folder, notify: false);
        fixture.library.addTracks([track], notify: false, persist: false);
        await tester.runAsync(
          () => fixture.library.saveAudioDetail(
            AudioDetail.empty(
              AudioDetailTarget.libraryRootFolder(folder),
            ).copyWith(
              workTitle: 'Library title',
              circleName: 'Library circle',
              voiceActors: ['Library voice'],
              tags: ['Library tag'],
            ),
          ),
        );
        fixture.libraryService.syncSlice(
          isInitialized: true,
          detailRevision: 0,
        );
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: AppFadeThroughIndexedStack.lazy(
                  indexListenable: active,
                  duration: Duration.zero,
                  itemCount: 2,
                  itemBuilder: (_, index) => index == 0
                      ? AsmrTab(activeTabIndexListenable: active)
                      : LibraryTab(activeTabIndexListenable: active),
                ),
              ),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              textTranslationServiceProvider.overrideWithValue(translations),
            ],
          ),
        );
        await pumpUntilFound(
          tester,
          find.text('Online title', findRichText: true),
        );
        _expectHeader(tester, 'asmr');
        expect(translations.calls, isEmpty);
        await tester.tap(find.byKey(const ValueKey('asmr_translation')));
        await _batch(tester);
        expect(
          translations.calls.expand((call) => call.texts),
          containsAll(['Online title', 'Online tag']),
        );
        for (final text in ['Online title', 'Online tag']) {
          expect(
            find.textContaining('zh-CN:$text', findRichText: true),
            findsWidgets,
          );
        }
        for (final name in ['Online circle', 'Online voice']) {
          expect(
            translations.calls.expand((call) => call.texts),
            isNot(contains(name)),
          );
          expect(find.textContaining(name, findRichText: true), findsWidgets);
          expect(
            find.textContaining('zh-CN:$name', findRichText: true),
            findsNothing,
          );
        }
        tester
            .widget<HeaderSegmentedCategoryBar<AsmrCategoryType>>(
              find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>),
            )
            .onSelected(AsmrCategoryType.recommendation);
        await _batch(tester);
        await pumpUntilFound(
          tester,
          find.text('zh-CN:Recommendation title', findRichText: true),
        );
        active.value = 1;
        await _batch(tester);
        await pumpUntilFound(
          tester,
          find.text('Library title', findRichText: true),
        );
        _expectHeader(tester, 'library');
        if (platform == TargetPlatform.android) {
          for (final size in [
            const Size(390, 800),
            const Size(440, 900),
            const Size(640, 480),
            const Size(320, 800),
          ]) {
            tester.view.physicalSize = size;
            await _batch(tester);
            _expectHeader(tester, 'library');
            expect(
              tester
                  .getTopLeft(find.byType(LibraryLikeMetadataWorkCardContent))
                  .dy,
              greaterThanOrEqualTo(
                tester.getBottomLeft(find.byType(TopPageHeader)).dy,
              ),
            );
          }
        }
        expect(
          find.text('zh-CN:Library title', findRichText: true),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('library_translation')));
        await _batch(tester);
        for (final text in ['Library title', 'Library tag']) {
          expect(
            find.textContaining('zh-CN:$text', findRichText: true),
            findsWidgets,
          );
        }
        for (final name in ['Library circle', 'Library voice']) {
          expect(
            translations.calls.expand((call) => call.texts),
            isNot(contains(name)),
          );
          expect(find.textContaining(name, findRichText: true), findsWidgets);
          expect(
            find.textContaining('zh-CN:$name', findRichText: true),
            findsNothing,
          );
        }
        final actions = find.byType(LibraryLikeCardActions).first;
        await tester.tap(
          find.descendant(of: actions, matching: find.byType(IconButton)).last,
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await _batch(tester);
        expect(played, [track.path]);
        expect(
          fixture.library.library.single.displayName,
          'Original audio.mp3',
        );
        await tester.tap(find.byKey(const ValueKey('library_translation')));
        await tester.pump();
        expect(find.text('Library title', findRichText: true), findsOneWidget);
        active.value = 0;
        await _batch(tester);
        expect(
          find.text('zh-CN:Recommendation title', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('asmr_translation')));
        await tester.pump();
        expect(
          find.text('Recommendation title', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'single audio translation preserves voice actor and circle names on $platform',
      (tester) async {
        _screen(tester, platform);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final translations = _Translations();
        const audioPath = 'C:/translation/single.mp3';
        final detail =
            AudioDetail.empty(
              AudioDetailTarget.singleAudioFile(audioPath),
            ).copyWith(
              circleName: 'みみの庭',
              voiceActors: ['日向こはね'],
              tags: ['Single tag'],
            );
        await tester.pumpWidget(
          fixture.build(
            WorkPageTranslationHost(
              child: Column(
                children: [
                  const WorkPageTranslationButton(
                    buttonKey: 'single_translation',
                  ),
                  SizedBox(
                    width: 300,
                    child: SingleAudioFileCardContent(
                      title: 'Original single.mp3',
                      path: audioPath,
                      detail: detail,
                      detailLoading: false,
                    ),
                  ),
                ],
              ),
            ),
            overrides: [
              textTranslationServiceProvider.overrideWithValue(translations),
            ],
          ),
        );
        await tester.tap(find.byKey(const ValueKey('single_translation')));
        await _batch(tester);
        expect(translations.calls.single.texts.toSet(), {
          'Original single',
          'Single tag',
        });
        expect(find.text('zh-CN:Original single.mp3'), findsOneWidget);
        expect(
          find.textContaining('zh-CN:Single tag', findRichText: true),
          findsOneWidget,
        );
        for (final name in ['みみの庭', '日向こはね']) {
          expect(find.textContaining(name, findRichText: true), findsOneWidget);
          expect(
            find.textContaining('zh-CN:$name', findRichText: true),
            findsNothing,
          );
        }
        await tester.tap(find.byKey(const ValueKey('single_translation')));
        await tester.pump();
        expect(find.text('Original single.mp3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'library expansion translates new file names while preserving extensions on $platform',
      (tester) async {
        _screen(tester, platform);
        final track = testMusicTrack(
          name: 'Original audio.mp3',
          path: 'C:/translation/Original directory/Original audio.mp3',
          groupKey: 'C:/translation',
          groupTitle: 'Library',
        );
        final folder = FolderNode(
          'Original directory',
          'C:/translation/Original directory',
          depth: 1,
        )..addChild(TrackNode(track));
        final fixture = AppRuntimeWidgetTestFixture(
          libraryCardSnapshotBuilder: (_) async =>
              LibraryTreeSnapshot(tree: [folder], leafFolderCount: 1),
        );
        addTearDown(fixture.dispose);
        final translations = _Translations();
        fixture.library.addTracks([track], notify: false, persist: false);
        fixture.libraryService.syncSlice(
          isInitialized: true,
          detailRevision: 0,
        );
        await tester.pumpWidget(
          fixture.build(
            const LibraryTab(),
            overrides: [
              textTranslationServiceProvider.overrideWithValue(translations),
            ],
          ),
        );
        await pumpUntilFound(
          tester,
          find.text('Original directory', findRichText: true),
        );
        await tester.tap(find.byKey(const ValueKey('library_translation')));
        await _batch(tester);
        expect(
          find.text('zh-CN:Original directory', findRichText: true),
          findsOneWidget,
        );
        expect(
          translations.calls.expand((call) => call.texts),
          isNot(contains('Original audio')),
        );
        await tester.tap(
          find.text('zh-CN:Original directory', findRichText: true),
        );
        await _batch(tester);
        await pumpUntilFound(
          tester,
          find.text('zh-CN:Original audio.mp3', findRichText: true),
        );
        expect(
          translations.calls.expand((call) => call.texts),
          contains('Original audio'),
        );
        expect(
          translations.calls.expand((call) => call.texts),
          isNot(contains('Original audio.mp3')),
        );
        expect(track.displayName, 'Original audio.mp3');
        expect(
          track.path,
          'C:/translation/Original directory/Original audio.mp3',
        );
        await tester.tap(find.byKey(const ValueKey('library_translation')));
        await tester.pump();
        expect(
          find.text('Original audio.mp3', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'hidden ASMR pauses requests and a failed resumed request preserves original text',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final controller = _AsmrController(createTestAsmrServices());
      final translations = _Translations()..hold = true;
      final active = ValueNotifier(0);
      addTearDown(fixture.dispose);
      addTearDown(controller.dispose);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        fixture.build(
          AppFadeThroughIndexedStack.lazy(
            indexListenable: active,
            itemCount: 2,
            duration: Duration.zero,
            itemBuilder: (_, index) => index == 0
                ? AsmrTab(activeTabIndexListenable: active)
                : const SizedBox.shrink(),
          ),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
            textTranslationServiceProvider.overrideWithValue(translations),
          ],
        ),
      );
      await pumpUntilFound(
        tester,
        find.text('Online title', findRichText: true),
      );
      await tester.tap(find.byKey(const ValueKey('asmr_translation')));
      await _batch(tester);
      final hidden = translations.calls.single;
      active.value = 1;
      await _batch(tester);
      expect(hidden.request.cancelled, isTrue);
      hidden.complete();
      await _batch(tester);
      expect(translations.calls, hasLength(1));
      active.value = 0;
      await _batch(tester);
      expect(translations.calls, hasLength(2));
      translations.calls.last.complete(
        failure: TextTranslationFailure.unavailable,
      );
      await _batch(tester);
      expect(find.text('Online title', findRichText: true), findsOneWidget);
      expect(find.text('zh-CN:Online title', findRichText: true), findsNothing);
      expect(
        find.text(fixture.languageProvider.tr('work_translation_unavailable')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 400));
      expect(translations.calls, hasLength(2));
      translations.hold = false;
      await tester.tap(find.byKey(const ValueKey('asmr_translation')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('asmr_translation')));
      await _batch(tester);
      expect(
        find.text('zh-CN:Online title', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ASMR cancellation ignores late results and uses the current app language',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final controller = _AsmrController(createTestAsmrServices());
      final translations = _Translations()..hold = true;
      addTearDown(fixture.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
            textTranslationServiceProvider.overrideWithValue(translations),
          ],
        ),
      );
      await pumpUntilFound(
        tester,
        find.text('Online title', findRichText: true),
      );
      await tester.tap(find.byKey(const ValueKey('asmr_translation')));
      await _batch(tester);
      final cancelled = translations.calls.single;
      await tester.tap(find.byKey(const ValueKey('asmr_translation')));
      await tester.pump();
      expect(cancelled.request.cancelled, isTrue);
      cancelled.complete();
      await _batch(tester);
      expect(find.text('Online title', findRichText: true), findsOneWidget);
      expect(find.text('zh-CN:Online title', findRichText: true), findsNothing);
      await fixture.languageProvider.setLanguage(AppLanguage.ja);
      translations.hold = false;
      await tester.tap(find.byKey(const ValueKey('asmr_translation')));
      await _batch(tester);
      expect(translations.calls.last.target, 'ja');
      expect(find.text('ja:Online title', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
