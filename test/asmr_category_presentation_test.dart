import 'dart:async';

import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_coordinator.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'support/test_playback_commands.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  Widget pageStack(ValueNotifier<int> activeTab) =>
      AppFadeThroughIndexedStack.lazy(
        indexListenable: activeTab,
        duration: Duration.zero,
        itemCount: 2,
        itemBuilder: (_, i) => [
          AsmrTab(activeTabIndexListenable: activeTab),
          const SizedBox.shrink(),
        ][i],
      );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'online library retains separate cards for equal source IDs on $platform',
      (tester) async {
        final one = AsmrWork.fromJson(const {
          'id': 7,
          'title': 'ASMR ONE work',
        });
        final japanese = AsmrWork.fromJson(const {
          'id': 7,
          'title': 'Japanese work',
          'resources': [
            {
              'source': 'japaneseAsmr',
              'id': 7,
              'code': '',
              'pageUrl': 'https://example.invalid/work/7',
            },
          ],
        });
        final controller = _PresentationController(createTestAsmrServices())
          ..publishedWorks = [one, japanese]
          ..combinedTotalCount = 123456;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        final oneCard = find.byKey(ValueKey('asmr-work-${one.workKey}'));
        final japaneseCard = find.byKey(
          ValueKey('asmr-work-${japanese.workKey}'),
        );
        await pumpUntilFound(tester, japaneseCard);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TopPageHeader>(find.byType(TopPageHeader))
              .topCapsuleData,
          fixture.languageProvider.tr('asmr_header_stats_combined', {
            'count': '123456',
          }),
        );
        final oneElement = tester.element(oneCard);
        final japaneseElement = tester.element(japaneseCard);
        controller
          ..publishedWorks = [japanese, one]
          ..publish('Reordered sources');
        await tester.pumpAndSettle();
        expect(tester.element(oneCard), same(oneElement));
        expect(tester.element(japaneseCard), same(japaneseElement));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'online library keeps available cards and retries a partial failure on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..catalogError = AsmrPartialCatalogException([
            AsmrCatalogSource.japaneseAsmr,
          ]);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        final notice = find.byKey(
          const ValueKey<String>('online_library_partial_failure'),
        );
        await pumpUntilFound(tester, notice);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TopPageHeader>(find.byType(TopPageHeader))
              .topCapsuleData,
          fixture.languageProvider.tr('asmr_header_stats_loaded', {
            'count': '1',
          }),
        );
        expect(find.text('Published work'), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('online_audio_library')),
          findsWidgets,
        );
        expect(
          find.text(
            fixture.languageProvider.tr('online_library_partial_failure'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: notice, matching: find.byType(IconButton)),
        );
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(controller.refreshCount, 1);
        expect(find.text('Published work'), findsOneWidget);
        expect(notice, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR empty filtered page allows explicit paging on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 0
          ..hasMore = true;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        final button = find.byKey(const ValueKey('asmr_empty_load_more'));
        await pumpUntilFound(tester, button);
        await tester.pumpAndSettle();
        expect(controller.loadMoreCount, 0);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(controller.loadMoreCount, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR route transitions retain cards while data theme and width stay reactive on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(450, 650);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 30;
        final fixture = AppRuntimeWidgetTestFixture();
        final dark = ValueNotifier(false);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(dark.dispose);
        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: dark,
              builder: (context, value, child) => Theme(
                data: Theme.of(context).copyWith(
                  brightness: value ? Brightness.dark : Brightness.light,
                  colorScheme: value
                      ? ThemeData.dark().colorScheme
                      : ThemeData.light().colorScheme,
                ),
                child: child!,
              ),
              child: const AsmrTab(),
            ),
            navigatorObservers: [UiInteractionNavigatorObserver()],
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        final cards = find.byType(LibraryLikeMetadataWorkCardContent);
        expect(cards, findsWidgets);
        final width = tester.getSize(cards.first).width;
        var cardBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is LibraryLikeMetadataWorkCardContent) {
            cardBuilds++;
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        for (var round = 0; round < 2; round++) {
          final context = tester.element(find.byType(AsmrTab));
          final navigator = Navigator.of(context);
          unawaited(
            navigator.push<void>(
              buildAppPageRoute(
                context: context,
                child: const Scaffold(body: Text('Cover ASMR')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
        }
        expect(cardBuilds, 0);

        final context = tester.element(find.byType(AsmrTab));
        final navigator = Navigator.of(context);
        unawaited(
          navigator.push<void>(
            buildAppPageRoute(
              context: context,
              child: const Scaffold(body: Text('Cover changed ASMR')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        controller.publish('Updated while covered');
        await tester.pumpAndSettle();
        expect(
          find.text('Updated while covered', skipOffstage: false),
          findsNothing,
        );
        navigator.pop();
        await pumpUntilFound(tester, find.text('Updated while covered'));
        await tester.pumpAndSettle();

        dark.value = true;
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(cards.first)).brightness,
          Brightness.dark,
        );
        expect(
          tester
              .widget<SwipeRevealCard>(find.byType(SwipeRevealCard).first)
              .closedColor,
          ThemeData.dark().colorScheme.surface,
        );
        tester.view.physicalSize = const Size(1280, 650);
        await tester.pumpAndSettle();
        expect(tester.getSize(cards.first).width, isNot(width));
        controller.publish('Updated work');
        await pumpUntilFound(tester, find.text('Updated work'));
        expect(find.text('Published work'), findsNothing);
        expect(cardBuilds, greaterThan(0));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR cached category opens in its preparation frame on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        controller.setPageLanguage(fixture.languageProvider.language);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        final navigation = Object();
        interaction.beginNavigation(navigation);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        expect(find.text('Published work'), findsOneWidget);
        expect(controller.initializations, 0);
        expect(controller.categoryLoads, 0);
        interaction.cancelNavigation(navigation);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR activation completion waits for a subsequent navigation on $platform',
      (tester) async {
        final activation = Completer<void>();
        final controller = _PresentationController(createTestAsmrServices())
          ..cacheValid = false
          ..pendingInitialization = activation;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pump();
        expect(controller.initializations, 1);
        final navigation = Object();
        interaction.beginNavigation(navigation);
        activation.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(controller.categoryLoads, 0);
        expect(find.text('Published work'), findsNothing);
        interaction.cancelNavigation(navigation);
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        expect(controller.initializations, 1);
        expect(controller.categoryLoads, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    for (final hidden in [true, false]) {
      testWidgets(
        'ASMR stale activation failure can recover (${hidden ? 'hidden' : 'new navigation'}) on $platform',
        (tester) async {
          final activation = Completer<void>();
          final controller = _PresentationController(createTestAsmrServices())
            ..cacheValid = false
            ..pendingInitialization = activation;
          final fixture = AppRuntimeWidgetTestFixture();
          final active = ValueNotifier<int>(0);
          addTearDown(controller.dispose);
          addTearDown(fixture.dispose);
          addTearDown(active.dispose);
          await tester.pumpWidget(
            fixture.build(
              pageStack(active),
              overrides: [
                asmrLibraryControllerProvider.overrideWithValue(controller),
              ],
            ),
          );
          await tester.pump();
          expect(controller.initializations, 1);
          final navigation = Object();
          if (hidden) {
            active.value = 1;
          } else {
            interaction.beginGeneration();
            interaction.beginNavigation(navigation);
          }
          await tester.pump();
          controller.pendingInitialization = null;
          activation.completeError(StateError('obsolete activation failed'));
          await tester.pump();
          expect(
            find.byTooltip(fixture.languageProvider.tr('retry')),
            findsNothing,
          );
          if (hidden) {
            active.value = 0;
          } else {
            interaction.cancelNavigation(navigation);
          }
          await pumpUntilFound(tester, find.text('Published work'));
          await tester.pumpAndSettle();
          expect(controller.initializations, 2);
          expect(controller.categoryLoads, 1);
          expect(
            find.byTooltip(fixture.languageProvider.tr('retry')),
            findsNothing,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      'ASMR visible initialization failure offers a scoped retry on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..cacheValid = false
          ..initializationError = StateError('preferences unavailable');
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        final retry = find.byTooltip(fixture.languageProvider.tr('retry'));
        expect(retry, findsOneWidget);
        expect(controller.categoryLoads, 0);
        controller.initializationError = null;
        await tester.tap(retry);
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        expect(controller.initializations, 2);
        expect(controller.categoryLoads, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR card play uses a temporary session and add creates a playlist on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          notificationsChannel,
          (_) async => {'ok': true, 'value': null},
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(notificationsChannel, null),
        );
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              asmrPlaybackCoordinatorProvider.overrideWithValue(
                AsmrPlaybackCoordinator(
                  source: controller,
                  launcher: PlaybackFacadeSessionLauncher(fixture.playback),
                ),
              ),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
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
                session.currentTrackPath = nextPath;
                return true;
              },
          pauseSession: (_) async {},
          startSession: (_, {required shouldStartTriggerCountdown}) async =>
              true,
          resolveAdvance: (_, {required forward}) => null,
          hasAdjacent: (_, {required forward}) => false,
        );
        final actions = find.byType(LibraryLikeCardActions);
        final buttons = find.descendant(
          of: actions,
          matching: find.byType(IconButton),
        );
        await tester.tap(buttons.at(1));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 350));
        final temporary = fixture.playback.activeSessions.single;
        expect(temporary.isTemporary, isTrue);
        expect(temporary.customQueueTracks?.map((track) => track.path), [
          'one',
          'two',
        ]);
        expect(controller.historyCount, 1);
        expect(find.byType(WorkDetailPage), findsNothing);
        await tester.tap(buttons.at(1));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.playback.activeSessions.single, same(temporary));
        await tester.tap(buttons.first);
        await tester.pumpAndSettle();
        expect(
          fixture.playback.activeSessions.where(
            (session) => !session.isTemporary,
          ),
          hasLength(1),
        );
        expect(
          fixture.playback.activeSessions
              .where((session) => session.isTemporary)
              .single,
          same(temporary),
        );
        expect(find.byType(WorkDetailPage), findsNothing);
        await tester.longPress(find.text('Published work'));
        await tester.pump();
        final disabled = tester.widget<LibraryLikeCardActions>(actions);
        expect(disabled.onAdd, isNull);
        expect(disabled.onPlay, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR card exposes compact add and play buttons and retains its menu on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();

        final contentFinder = find.byType(LibraryLikeMetadataWorkCardContent);
        final contentRect = tester.getRect(contentFinder.first);
        final actions = find.descendant(
          of: contentFinder.first,
          matching: find.byType(LibraryLikeCardActions),
        );
        expect(actions, findsOneWidget);
        expect(
          find.descendant(of: actions, matching: find.byType(IconButton)),
          findsNWidgets(2),
        );
        expect(contentRect.height, LibraryLikeCardMetrics.coverHeight);
        final titleRect = tester.getRect(find.text('Published work'));
        expect(
          titleRect.left,
          contentRect.left +
              LibraryLikeCardMetrics.coverHeight *
                  LibraryLikeCardMetrics.coverAspectRatio +
              10,
        );
        expect(titleRect.top, contentRect.top);
        final before = contentRect;

        final swipe = find.ancestor(
          of: contentFinder.first,
          matching: find.byType(SwipeRevealCard),
        );
        expect(swipe, findsOneWidget);
        final shell = tester.widget<SwipeRevealCard>(swipe);
        expect(shell.primaryActionIcon, Icons.favorite_border_rounded);
        expect(shell.secondaryActionIcon, Icons.download_rounded);
        expect(shell.onSecondaryAction, isNotNull);
        final favoriteLabel = fixture.languageProvider.tr(
          'asmr_favorite_action',
        );
        final downloadLabel = fixture.languageProvider.tr('download');
        if (platform == TargetPlatform.android) {
          await tester.drag(swipe, const Offset(-150, 0));
        } else {
          await tester.tap(
            find.text('Published work'),
            buttons: kSecondaryMouseButton,
            kind: PointerDeviceKind.mouse,
          );
        }
        await tester.pumpAndSettle();
        if (platform == TargetPlatform.windows) {
          expect(find.text(favoriteLabel), findsOneWidget);
          expect(find.text(downloadLabel), findsOneWidget);
        } else {
          expect(find.byTooltip(favoriteLabel), findsWidgets);
          expect(find.byTooltip(downloadLabel), findsWidgets);
          expect(
            tester.getRect(contentFinder.first).left,
            lessThan(before.left),
          );
        }
        await tester.tap(
          platform == TargetPlatform.windows
              ? find.text(favoriteLabel)
              : find.byTooltip(favoriteLabel).last,
        );
        await tester.pumpAndSettle();
        expect(controller.favoriteToggles, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('ASMR rebuilds keep published cards during interaction', (
    tester,
  ) async {
    final controller = _PresentationController(createTestAsmrServices());
    final fixture = AppRuntimeWidgetTestFixture();
    final padding = ValueNotifier<double>(0);
    final activeTab = ValueNotifier<int>(0);
    addTearDown(() {
      padding.dispose();
      activeTab.dispose();
      controller.dispose();
      fixture.dispose();
    });
    final motion = Object();
    interaction.beginInteraction(motion);
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<double>(
          valueListenable: padding,
          builder: (context, value, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              padding: EdgeInsets.only(right: value),
            ),
            child: pageStack(activeTab),
          ),
        ),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.categoryReads, 0);
    expect(find.text('Published work'), findsNothing);

    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Published work'));
    final readsBeforeMotion = controller.categoryReads;
    interaction.beginInteraction(motion);
    controller.publish('Deferred work');
    controller.publish('Newest work');
    padding.value = 1;
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.categoryReads, readsBeforeMotion);
    expect(find.text('Published work'), findsOneWidget);
    expect(find.text('Deferred work'), findsNothing);
    expect(find.text('Newest work'), findsNothing);

    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Newest work'));
    expect(find.text('Published work'), findsNothing);

    activeTab.value = 1;
    await tester.pump();
    await tester.pump();
    final readsWhileHidden = controller.categoryReads;
    controller.publish('Return work');
    await tester.pump();
    expect(controller.categoryReads, readsWhileHidden);
    interaction.beginInteraction(motion);
    activeTab.value = 0;
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Newest work'), findsOneWidget);
    expect(find.text('Return work'), findsNothing);
    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Return work'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'ASMR loads on demand after its entrance on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..cacheValid = false;
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        final completed = <int>[];
        addTearDown(activeTab.dispose);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            AppFadeThroughIndexedStack.lazy(
              indexListenable: activeTab,
              separateHeader: true,
              itemCount: 2,
              onTransitionCompleted: completed.add,
              itemBuilder: (_, index) => index == 0
                  ? const Center(child: Text('Local page'))
                  : AsmrTab(
                      key: const ValueKey('prepared_asmr'),
                      tabIndex: 1,
                      activeTabIndexListenable: activeTab,
                    ),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        expect(find.byType(AsmrTab, skipOffstage: false), findsNothing);
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(find.byType(AsmrTab, skipOffstage: false), findsNothing);
        expect(find.text('Local page'), findsOneWidget);
        expect(activeTab.value, 0);
        expect(completed, isEmpty);
        expect(controller.initializations, 0);
        expect(controller.categoryLoads, 0);
        expect(controller.accountRestores, 0);

        controller.publish('Activated work');
        await tester.pumpAndSettle();
        expect(controller.categoryReads, 0);
        expect(controller.initializations, 0);
        expect(controller.categoryLoads, 0);
        expect(controller.accountRestores, 0);

        activeTab.value = 1;
        await tester.pump();
        expect(find.byType(AsmrTab), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.initializations, 0);
        expect(controller.categoryLoads, 0);
        expect(controller.accountRestores, 0);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(activeTab.value, 1);
        expect(completed, [1]);
        expect(controller.initializations, 1);
        expect(controller.categoryLoads, 1);
        expect(controller.accountRestores, 1);
        expect(controller.categoryReads, greaterThan(0));
        expect(find.text('Activated work'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR search starts with suggestions and only confirms nonempty drafts on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const {'app_language': 'zh'});
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        fixture.settings.asmrSearchHistory = const ['Voice Actor, Sleep'];
        fixture.settings.syncSlice();
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final loads = controller.categoryLoads;
        final reads = controller.categoryReads;
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        AppSearchPageScaffold<AsmrCategoryType> search() =>
            tester.widget(find.byType(AppSearchPageScaffold<AsmrCategoryType>));
        expect(
          find.byKey(const ValueKey('asmr_search_collected')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('asmr_search_history')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('asmr_search_voice_actors')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('asmr_search_tags')), findsOneWidget);
        expect(search().categories, isNotEmpty);
        expect(search().onConfirm, isNull);
        expect(controller.categoryReads, reads);
        expect(controller.categoryLoads, loads);
        expect(controller.suggestionLoads, 1);
        final history = tester.widget<AppSearchSuggestionSection>(
          find.byKey(const ValueKey('asmr_search_history')),
        );
        history.onToggle('Voice Actor, Sleep');
        await tester.pumpAndSettle();
        expect(search().controller.text, 'Voice Actor, Sleep');
        expect(controller.categoryLoads, loads);
        expect(search().onConfirm, isNotNull);
        expect(
          tester
              .widget<AppSearchSuggestionSection>(
                find.byKey(const ValueKey('asmr_search_tags')),
              )
              .isSelected('Sleep'),
          isTrue,
        );
        tester
            .widget<AppSearchSuggestionSection>(
              find.byKey(const ValueKey('asmr_search_tags')),
            )
            .onToggle('Sleep');
        await tester.pumpAndSettle();
        expect(search().controller.text, 'Voice Actor');
        search().onConfirm!();
        await tester.pumpAndSettle();
        expect(controller.lastSearchQuery, 'Voice Actor');
        expect(
          find.byKey(const ValueKey('asmr_search_collected')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('asmr_search_suggestions')),
          findsNothing,
        );
        await tester.enterText(find.byType(TextField), 'Unconfirmed');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('asmr_search_collected')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('asmr_search_suggestions')),
          findsOneWidget,
        );
        expect(
          fixture.settings.slice.state.asmrSearchHistory,
          isNot(contains('Unconfirmed')),
        );
        final loadsBeforeClear = controller.categoryLoads;
        final historyBeforeClear =
            fixture.settings.slice.state.asmrSearchHistory;
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('asmr_search_history')),
            matching: find.byTooltip('清空'),
          ),
        );
        await tester.pumpAndSettle();
        expect(fixture.settings.slice.state.asmrSearchHistory, isEmpty);
        expect(search().controller.text, 'Unconfirmed');
        expect(find.text('搜索历史已清空'), findsOneWidget);
        await tester.tap(find.text('撤销'));
        await tester.pumpAndSettle();
        expect(
          fixture.settings.slice.state.asmrSearchHistory,
          historyBeforeClear,
        );
        expect(search().controller.text, 'Unconfirmed');
        expect(controller.categoryLoads, loadsBeforeClear);
        search().onCloseOrClear();
        await tester.pumpAndSettle();
        expect(search().controller.text, isEmpty);
        expect(search().onConfirm, isNull);
        expect(controller.suggestionLoads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR drafts isolate suggestion and page rebuilds on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        AppSearchSuggestionSection tags() =>
            tester.widget(find.byKey(const ValueKey('asmr_search_tags')));
        AppSearchPageScaffold<AsmrCategoryType> search() =>
            tester.widget(find.byType(AppSearchPageScaffold<AsmrCategoryType>));
        final initialTags = tags();
        controller.publish('Unrelated work update');
        await tester.pumpAndSettle();
        expect(identical(tags(), initialTags), isTrue);
        fixture.settings.autoCheckUpdates = true;
        fixture.settings.syncSlice();
        await tester.pumpAndSettle();
        expect(identical(tags(), initialTags), isTrue);

        await tester.enterText(find.byType(TextField), 'S');
        await tester.pumpAndSettle();
        final draftPage = search();
        final queryChanges = controller.searchQueryChanges;
        await tester.enterText(find.byType(TextField), 'Sleep');
        await tester.pumpAndSettle();
        expect(identical(search(), draftPage), isTrue);
        expect(tags().isSelected('Sleep'), isTrue);
        expect(
          tester
              .widget<InputChip>(find.widgetWithText(InputChip, 'Sleep'))
              .selected,
          isTrue,
        );
        expect(controller.searchQueryChanges, queryChanges);

        controller.suggestionsError = StateError('Offline refresh');
        controller.publish('Suggestion error');
        await tester.pumpAndSettle();
        expect(tags().errorText, isNotNull);
        controller.suggestionsError = null;

        controller.publishSuggestions(
          AsmrSearchSuggestions(voiceActors: ['New Voice'], tags: ['New Tag']),
        );
        await tester.pumpAndSettle();
        expect(tags().items, ['New Tag']);
        expect(tags().errorText, isNull);
        fixture.settings.asmrSearchHistory = const ['New history'];
        fixture.settings.syncSlice();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AppSearchSuggestionSection>(
                find.byKey(const ValueKey('asmr_search_history')),
              )
              .items,
          ['New history'],
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR search suggestion failures offer shared retry without blocking submission on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const {'app_language': 'zh'});
        final controller = _PresentationController(createTestAsmrServices())
          ..suggestionsError = StateError('Offline suggestions');
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        final voices = tester.widget<AppSearchSuggestionSection>(
          find.byKey(const ValueKey('asmr_search_voice_actors')),
        );
        final tags = tester.widget<AppSearchSuggestionSection>(
          find.byKey(const ValueKey('asmr_search_tags')),
        );
        expect(voices.errorText, isNotNull);
        expect(tags.errorText, isNotNull);
        expect(voices.items, ['Voice Actor']);
        expect(tags.items, ['Sleep']);
        voices.onRetry!();
        expect(controller.suggestionLoads, 2);
        expect(controller.forcedSuggestionLoads, 1);
        await tester.enterText(find.byType(TextField), 'Manual search');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(controller.lastSearchQuery, 'Manual search');
        expect(
          find.byKey(const ValueKey('asmr_search_collected')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR search shows initial hot suggestions while refresh is pending and preserves selection on $platform',
      (tester) async {
        final refresh = Completer<void>();
        final controller = _PresentationController(createTestAsmrServices())
          ..pendingSuggestionsLoad = refresh;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await pumpUntilFound(
          tester,
          find.byKey(const ValueKey('asmr_search_voice_actors')),
        );
        AppSearchSuggestionSection section(String key) =>
            tester.widget(find.byKey(ValueKey(key)));
        expect(section('asmr_search_voice_actors').items, ['Voice Actor']);
        expect(section('asmr_search_tags').items, ['Sleep']);
        expect(section('asmr_search_voice_actors').isLoading, isFalse);
        expect(section('asmr_search_tags').isLoading, isFalse);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(controller.suggestionLoads, 1);
        await tester.pumpAndSettle();
        section('asmr_search_tags').onToggle('Sleep');
        await tester.pumpAndSettle();
        refresh.complete();
        controller.publishSuggestions(
          AsmrSearchSuggestions(
            voiceActors: ['Refreshed Voice'],
            tags: ['Sleep', 'Refreshed Tag'],
          ),
        );
        await tester.pumpAndSettle();
        expect(section('asmr_search_voice_actors').items, ['Refreshed Voice']);
        expect(section('asmr_search_tags').items, ['Sleep', 'Refreshed Tag']);
        expect(section('asmr_search_tags').isSelected('Sleep'), isTrue);
        expect(section('asmr_search_tags').maxExpandedItems, 30);
        expect(section('asmr_search_voice_actors').maxExpandedItems, 30);
        expect(
          tester
              .widget<AppSearchPageScaffold<AsmrCategoryType>>(
                find.byType(AppSearchPageScaffold<AsmrCategoryType>),
              )
              .controller
              .text,
          'Sleep',
        );
        expect(controller.suggestionLoads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR submitted search keeps loading until data and hides it when editing on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const {'app_language': 'zh'});
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        final load = Completer<void>();
        controller
          ..cacheValid = false
          ..pendingCategoryLoad = load;
        final search = tester.widget<AppSearchPageScaffold<AsmrCategoryType>>(
          find.byType(AppSearchPageScaffold<AsmrCategoryType>),
        );
        search.onSubmitted('Pending query');
        await tester.pump();
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        final results = find.byKey(const ValueKey('asmr_search_collected'));
        expect(
          find.descendant(
            of: results,
            matching: find.byKey(const ValueKey('loading')),
          ),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField), 'New draft');
        await tester.pumpAndSettle();
        expect(results, findsNothing);
        load.complete();
        controller.publish('Old result finished');
        await tester.pumpAndSettle();
        expect(results, findsNothing);
        expect(
          find.byKey(const ValueKey('asmr_search_suggestions')),
          findsOneWidget,
        );
        expect(find.text('Old result finished'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR drafts stay unsubmitted across language route and sorting changes on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const {'app_language': 'zh'});
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        AppSearchPageScaffold<AsmrCategoryType> search() =>
            tester.widget(find.byType(AppSearchPageScaffold<AsmrCategoryType>));
        controller.searchQueries.clear();
        controller.categoryRequestQueries.clear();
        await tester.enterText(find.byType(TextField), 'Sleep');
        await fixture.languageProvider.setLanguage(AppLanguage.en);
        search().onCategorySelected!(AsmrCategoryType.favorites);
        await tester.pumpAndSettle();
        final navigator = Navigator.of(tester.element(find.byType(TextField)));
        unawaited(
          navigator.push(
            PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => const SizedBox.shrink(),
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
            ),
          ),
        );
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        expect(controller.searchQueries, isEmpty);
        expect(controller.categoryRequestQueries, isEmpty);
        search().onConfirm!();
        await tester.pumpAndSettle();
        expect(controller.lastSearchQuery, 'Sleep');
        await tester.enterText(find.byType(TextField), 'Disposed pending');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.searchQueries, isNot(contains('Disposed pending')));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR category switches retain widgets and publish hidden updates on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        void select(AsmrCategoryType category) => tester
            .widget<HeaderSegmentedCategoryBar<AsmrCategoryType>>(
              find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>),
            )
            .onSelected(category);
        Future<void> settleCategory() async {
          await tester.pumpAndSettle();
          await tester.pump(interaction.idleDelay);
          await tester.pumpAndSettle();
        }

        final collected = find.byKey(
          const ValueKey(AsmrCategoryType.collected),
          skipOffstage: false,
        );
        final initialWidget = tester.widget(collected);
        final initialState = tester.state(collected);
        select(AsmrCategoryType.recommendation);
        await settleCategory();
        select(AsmrCategoryType.collected);
        await settleCategory();
        final initialReads = controller.categoryReads;
        for (var i = 0; i < 3; i++) {
          select(AsmrCategoryType.recommendation);
          await settleCategory();
          select(AsmrCategoryType.collected);
          await settleCategory();
        }
        expect(tester.widget(collected), same(initialWidget));
        expect(tester.state(collected), same(initialState));
        expect(controller.categoryReads, initialReads);

        select(AsmrCategoryType.recommendation);
        await settleCategory();
        controller.publish('Newest work');
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: collected,
            matching: find.text('Published work', skipOffstage: false),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        select(AsmrCategoryType.collected);
        await settleCategory();
        expect(find.text('Newest work'), findsOneWidget);
        expect(tester.state(collected), same(initialState));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR cards retain state across column changes on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 12;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final card = find.byKey(
          const ValueKey<String>('asmr-work-source:asmrOne:3'),
        );
        Finder statefulCard() => find
            .descendant(
              of: card,
              matching: find.byWidgetPredicate(
                (widget) => widget is ConsumerStatefulWidget,
              ),
            )
            .first;
        final originalElement = tester.element(card);
        final originalState = tester.state(statefulCard());
        for (final width in [640.0, 1280.0, 1800.0, 640.0]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pump();
          expect(tester.element(card), same(originalElement));
          expect(tester.state(statefulCard()), same(originalState));
          expect(tester.widget<FadeTransition>(card).opacity.value, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    for (final count in [100, 1000]) {
      for (final retryFooter in [false, true]) {
        testWidgets(
          'ASMR bottom column resize settles with $count works and retry footer=$retryFooter on $platform',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(1280, 800);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            final controller = _PresentationController(createTestAsmrServices())
              ..workCount = count
              ..hasMore = retryFooter
              ..needsRetry = retryFooter;
            final fixture = AppRuntimeWidgetTestFixture();
            addTearDown(controller.dispose);
            addTearDown(fixture.dispose);
            await tester.pumpWidget(
              fixture.build(
                const AsmrTab(),
                overrides: [
                  asmrLibraryControllerProvider.overrideWithValue(controller),
                ],
              ),
            );
            await pumpUntilFound(tester, find.text('Published work'));
            await tester.pumpAndSettle();
            ScrollPosition position() => tester
                .stateList<ScrollableState>(find.byType(Scrollable))
                .singleWhere(
                  (state) =>
                      state.position.axis == Axis.vertical &&
                      state.position.hasContentDimensions &&
                      state.position.maxScrollExtent > 1000,
                )
                .position;
            Future<void> scrollToBottom() async {
              for (var attempt = 0; attempt < 5; attempt++) {
                final scroll = position();
                scroll.jumpTo(scroll.maxScrollExtent);
                await tester.pumpAndSettle(
                  const Duration(milliseconds: 20),
                  EnginePhase.sendSemanticsUpdate,
                  const Duration(seconds: 5),
                );
                if (position().extentAfter <= 0.5) break;
              }
              expect(position().extentAfter, lessThanOrEqualTo(0.5));
              expect(
                find.byKey(const ValueKey('asmr_load_more_footer')),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
            }

            expect(responsiveLibraryCardColumnCount(1280), greaterThan(1));
            expect(responsiveLibraryCardColumnCount(640), 1);
            final workSliver = tester.widget<SliverFixedExtentList>(
              find.byType(SliverFixedExtentList),
            );
            expect(
              workSliver.itemExtent,
              LibraryLikeCardMetrics.rootTileHeight,
            );
            expect(
              (workSliver.delegate as SliverChildBuilderDelegate).childCount,
              (count / responsiveLibraryCardColumnCount(1280)).ceil(),
            );
            await scrollToBottom();
            for (final width in [640.0, 1280.0, 640.0, 1280.0]) {
              tester.view.physicalSize = Size(width, 800);
              await tester.pumpAndSettle(
                const Duration(milliseconds: 20),
                EnginePhase.sendSemanticsUpdate,
                const Duration(seconds: 5),
              );
              expect(tester.takeException(), isNull);
              await scrollToBottom();
              expect(find.byType(SliverFixedExtentList), findsOneWidget);
              expect(
                find
                    .byType(LibraryLikeMetadataWorkCardContent)
                    .evaluate()
                    .length,
                lessThan(60),
                reason: 'Jumping to the end must retain only nearby cards.',
              );
              expect(interaction.navigationAllowed.value, isTrue);
            }
            expect(controller.loadMoreCount, 0);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant({platform}),
        );
      }
    }

    testWidgets(
      'ASMR large library scroll keeps card work within the viewport on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(
          platform == TargetPlatform.windows ? 1280 : 450,
          800,
        );
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = _PresentationController(createTestAsmrServices())
          ..publishedWorks = [
            for (var index = 0; index < 1000; index++)
              AsmrWork.fromJson({
                'id': index + 1,
                'title': 'Published work $index with a long descriptive title',
                'circle': const {
                  'name': 'A circle with a long descriptive name',
                },
                'vas': const [
                  {'name': 'Voice actor one'},
                  {'name': 'Voice actor two'},
                ],
                'tags': const [
                  {'name': 'Relaxation'},
                  {'name': 'Sleep aid'},
                ],
              }),
          ];
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        final cards = find.byType(LibraryLikeMetadataWorkCardContent);
        await pumpUntilFound(tester, cards);
        await tester.pumpAndSettle();
        final categoryReads = controller.categoryReads;
        final existingCards = cards.evaluate().toSet();
        var existingCardBuilds = 0;
        var newCardBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is! LibraryLikeMetadataWorkCardContent) return;
          if (existingCards.contains(element)) {
            existingCardBuilds++;
          } else {
            newCardBuilds++;
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        final list = find.byKey(
          const PageStorageKey(AsmrCategoryType.collected),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(list) + const Offset(0, 100),
        );
        for (final direction in [-1, 1]) {
          for (var frame = 0; frame < 16; frame++) {
            await gesture.moveBy(Offset(0, direction * 30));
            await tester.pump(const Duration(milliseconds: 16));
            expect(cards.evaluate().length, lessThan(60));
          }
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(controller.categoryReads, categoryReads);
        expect(existingCardBuilds, 0);
        expect(newCardBuilds, greaterThan(0));
        expect(newCardBuilds, lessThan(60));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR offscreen load-more progress stays idle until visible on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 1000
          ..hasMore = true;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final progress = find.byKey(
          const ValueKey<String>('asmr_load_more_progress'),
        );
        for (final element in progress.evaluate()) {
          expect(TickerMode.valuesOf(element).enabled, isFalse);
        }
        expect(tester.binding.hasScheduledFrame, isFalse);
        final list = tester.widget<ScrollView>(
          find.byKey(const PageStorageKey(AsmrCategoryType.collected)),
        );
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pump();
        expect(TickerMode.valuesOf(tester.element(progress)).enabled, isTrue);
        expect(tester.binding.hasScheduledFrame, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR search builds only nearby cards and retains them during keyboard resize on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 1000;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final browseCards = find.byType(
          LibraryLikeMetadataWorkCardContent,
          skipOffstage: false,
        );
        final browseCardCount = browseCards.evaluate().length;
        final loads = controller.categoryLoads;

        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pump();
        await tester.pumpAndSettle();
        tester
            .widget<AppSearchPageScaffold<AsmrCategoryType>>(
              find.byType(AppSearchPageScaffold<AsmrCategoryType>),
            )
            .onSubmitted('Published');
        await tester.pumpAndSettle();
        final results = find.byKey(const ValueKey('asmr_search_collected'));
        final searchCards = find.descendant(
          of: results,
          matching: find.byType(
            LibraryLikeMetadataWorkCardContent,
            skipOffstage: false,
          ),
          skipOffstage: false,
        );
        final columnCount = responsiveLibraryCardColumnCount(1280);
        expect(searchCards, findsWidgets);
        expect(
          searchCards.evaluate().length,
          lessThan(browseCardCount - columnCount),
          reason: 'Search entrance should build fewer offscreen card rows.',
        );
        expect(
          find.descendant(
            of: results,
            matching: find.text('Published work', findRichText: true),
          ),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
        final originalCard = tester.widget(searchCards.first);
        final originalWidth = tester.getSize(searchCards.first).width;
        for (final bottom in [60.0, 120.0, 180.0, 240.0, 300.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: bottom);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.widget(searchCards.first), same(originalCard));
        }
        await tester.pumpAndSettle();
        expect(controller.categoryLoads, loads);
        tester.view.physicalSize = const Size(640, 800);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(searchCards.first).width,
          greaterThan(originalWidth),
        );
        controller.publish('Updated after resize');
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: results,
            matching: find.text('Updated after resize', findRichText: true),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR search categories retain content and adopt changed queries on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        AppSearchPageScaffold<AsmrCategoryType> search() =>
            tester.widget(find.byType(AppSearchPageScaffold<AsmrCategoryType>));
        search().onSubmitted('Published');
        await tester.pumpAndSettle();
        final collected = find.byKey(
          const ValueKey('asmr_search_collected'),
          skipOffstage: false,
        );
        final initialWidget = tester.widget(collected);
        final initialState = tester.state(collected);
        for (var i = 0; i < 3; i++) {
          search().onCategorySelected!(AsmrCategoryType.recommendation);
          await tester.pumpAndSettle();
          search().onCategorySelected!(AsmrCategoryType.collected);
          await tester.pumpAndSettle();
        }
        expect(tester.widget(collected), same(initialWidget));
        expect(tester.state(collected), same(initialState));

        search().onCategorySelected!(AsmrCategoryType.recommendation);
        await tester.pumpAndSettle();
        search().onSubmitted('Newest');
        controller.publish('Newest work');
        await tester.pumpAndSettle();
        final readsBeforeReturn = controller.categoryReads;
        search().onCategorySelected!(AsmrCategoryType.collected);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(controller.lastSearchQuery, 'Newest');
        expect(controller.categoryReads, greaterThan(readsBeforeReturn));
        expect(tester.state(collected), same(initialState));
        expect(tester.widget(collected), isNot(same(initialWidget)));
        expect(find.text('Published work'), findsNothing);
        expect(
          find.descendant(
            of: collected,
            matching: find.textContaining('Newest work', findRichText: true),
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR single-column favorites retain cards through reorder append and collapse on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final works = [
          for (var id = 1; id <= 4; id++)
            AsmrWork.fromJson({'id': id, 'title': 'Work $id'}),
        ];
        final controller = _PresentationController(createTestAsmrServices())
          ..publishedWorks = works.take(3).toList();
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Work 1'));
        await tester.pumpAndSettle();
        tester
            .widget<HeaderSegmentedCategoryBar<AsmrCategoryType>>(
              find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>),
            )
            .onSelected(AsmrCategoryType.favorites);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        Finder card(int id) =>
            find.byKey(ValueKey<String>('asmr-work-source:asmrOne:$id'));
        final retainedCard = tester.element(card(2));
        final favoriteList = find.byKey(
          const PageStorageKey(AsmrCategoryType.favorites),
        );
        Finder favoriteSliver(Type type) =>
            find.descendant(of: favoriteList, matching: find.byType(type));
        expect(favoriteSliver(SliverFixedExtentList), findsOneWidget);

        controller
          ..publishedWorks = [works[2], works[0], works[1], works[3]]
          ..publish('Reordered');
        await tester.pumpAndSettle();
        expect(tester.element(card(2)), same(retainedCard));
        expect(find.text('Work 4'), findsOneWidget);

        controller
          ..publishedWorks = [works[2], works[1], works[3]]
          ..publish('Removed');
        await tester.pump();
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        expect(card(1), findsOneWidget);
        expect(tester.element(card(2)), same(retainedCard));
        expect(favoriteSliver(SliverList), findsOneWidget);
        expect(favoriteSliver(SliverFixedExtentList), findsNothing);
        final nextTop = tester.getTopLeft(card(2)).dy;
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(card(2)).dy, lessThan(nextTop));
        expect(card(1), findsOneWidget);
        await tester.pumpAndSettle();
        expect(card(1), findsNothing);
        expect(tester.element(card(2)), same(retainedCard));
        expect(favoriteSliver(SliverFixedExtentList), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR visible removals keep their neighbors when earlier offscreen works are removed on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final works = [
          for (var id = 1; id <= 40; id++)
            AsmrWork.fromJson({'id': id, 'title': 'Work $id'}),
        ];
        final controller = _PresentationController(createTestAsmrServices())
          ..publishedWorks = works;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Work 1'));
        await tester.pumpAndSettle();
        tester
            .widget<HeaderSegmentedCategoryBar<AsmrCategoryType>>(
              find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>),
            )
            .onSelected(AsmrCategoryType.favorites);
        await tester.pumpAndSettle();
        final list = find.byKey(
          const PageStorageKey(AsmrCategoryType.favorites),
        );
        tester.widget<ScrollView>(list).controller!.jumpTo(1800);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();

        Finder card(int id) =>
            find.byKey(ValueKey<String>('asmr-work-source:asmrOne:$id'));
        expect(card(1), findsNothing);
        final viewport = tester.getRect(list);
        final retiring = works.firstWhere((work) {
          final candidate = card(work.id);
          if (candidate.evaluate().isEmpty) return false;
          final center = tester.getCenter(candidate).dy;
          return center > viewport.center.dy && center < viewport.bottom - 100;
        });
        final previous = card(retiring.id - 1);
        final next = card(retiring.id + 1);
        final retiringCard = card(retiring.id);
        expect(previous, findsOneWidget);
        expect(next, findsOneWidget);

        controller
          ..publishedWorks = works
              .where((work) => work.id != 1 && work.id != retiring.id)
              .toList()
          ..publish('Removed offscreen and visible works');
        await tester.pump();
        await tester.pump(interaction.idleDelay);
        await tester.pump();

        expect(
          tester.getTopLeft(retiringCard).dy,
          greaterThan(tester.getTopLeft(previous).dy),
        );
        expect(
          tester.getTopLeft(retiringCard).dy,
          lessThan(tester.getTopLeft(next).dy),
          reason: 'The visible retiring work must stay before its next work.',
        );
        final collapse = tester.widget<SizeTransition>(
          find.ancestor(
            of: retiringCard,
            matching: find.byType(SizeTransition),
          ),
        );
        expect(collapse.sizeFactor.value, greaterThan(0));
        await tester.pumpAndSettle();
        expect(retiringCard, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR repeat switches retain category projections on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(activeTab.dispose);
        await tester.pumpWidget(
          fixture.build(
            pageStack(activeTab),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final initialReads = controller.categoryReads;
        final originalCard = tester.element(
          find.byKey(const ValueKey<String>('asmr-work-source:asmrOne:1')),
        );
        for (var i = 0; i < 3; i++) {
          activeTab.value = 1;
          await tester.pumpAndSettle();
          activeTab.value = 0;
          await tester.pumpAndSettle();
        }
        expect(controller.categoryReads, initialReads);
        expect(
          tester.element(
            find.byKey(const ValueKey<String>('asmr-work-source:asmrOne:1')),
          ),
          same(originalCard),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR hidden page cancels queued pagination on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 30
          ..hasMore = true;
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(activeTab.dispose);
        await tester.pumpWidget(
          fixture.build(
            pageStack(activeTab),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        expect(controller.loadMoreCount, 0);
        final motion = Object();
        interaction.beginInteraction(motion);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 10000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('asmr_load_more_progress')),
          findsOneWidget,
        );
        activeTab.value = 1;
        await tester.pump();
        interaction.cancelInteraction(motion);
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        expect(controller.loadMoreCount, 0);
        activeTab.value = 0;
        await tester.pump();
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        expect(controller.loadMoreCount, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR appended card animation pauses while hidden on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..hasMore = true
          ..needsRetry = true;
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(activeTab.dispose);
        await tester.pumpWidget(
          fixture.build(
            pageStack(activeTab),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        controller.workCount = 2;
        controller.publish('Published work');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final card = find.byKey(
          const ValueKey<String>('asmr-work-source:asmrOne:2'),
          skipOffstage: false,
        );
        final animation = tester.widget<FadeTransition>(card).opacity;
        final beforeHide = animation.value;
        expect(beforeHide, inExclusiveRange(0, 1));
        activeTab.value = 1;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(animation.value, beforeHide);
        activeTab.value = 0;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(animation.value, greaterThan(beforeHide));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('ASMR category and tree providers defer initial projections', (
    tester,
  ) async {
    final controller = _PresentationController(createTestAsmrServices())
      ..cacheValid = false;
    final container = ProviderContainer(
      overrides: [asmrLibraryControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    final motion = Object();
    interaction.beginInteraction(motion);
    final category = asmrCategoryStateProvider((
      category: AsmrCategoryType.collected,
      searchQuery: '',
      searchSession: false,
    ));
    final tree = asmrTrackTreeStateProvider('source:asmrOne:1');
    final categorySubscription = container.listen(category, (_, _) {});
    final treeSubscription = container.listen(tree, (_, _) {});
    controller.publish('Latest work');
    await tester.pump();
    expect(controller.categoryReads, 0);
    expect(controller.treeReads, 0);
    expect(container.read(category).isLoading, isTrue);
    expect(container.read(tree).isLoading, isTrue);

    controller.cacheValid = true;
    interaction.cancelInteraction(motion);
    await tester.pump();
    final state = await container.read(category.future);
    await tester.pump();
    await container.read(tree.future);
    expect(state!.works.single.title, 'Latest work');
    expect(controller.categoryReads, 1);
    expect(controller.treeReads, 1);
    categorySubscription.close();
    treeSubscription.close();
    await tester.pump(const Duration(milliseconds: 1));
  });
}

class _PresentationController extends AsmrLibraryController {
  _PresentationController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  Object? suggestionsError;
  @override
  Object? get searchSuggestionsError => suggestionsError;
  int suggestionLoads = 0;
  int forcedSuggestionLoads = 0;
  Completer<void>? pendingSuggestionsLoad;
  @override
  bool get isLoadingSearchSuggestions => pendingSuggestionsLoad != null;
  @override
  Future<void> ensureSearchSuggestions({bool force = false}) async {
    suggestionLoads++;
    if (force) forcedSuggestionLoads++;
    await pendingSuggestionsLoad?.future;
  }

  AsmrSearchSuggestions suggestions = AsmrSearchSuggestions(
    voiceActors: ['Voice Actor'],
    tags: ['Sleep'],
  );
  @override
  AsmrSearchSuggestions get searchSuggestions => suggestions;

  void publishSuggestions(AsmrSearchSuggestions value) {
    suggestions = value;
    notifyListeners();
  }

  String title = 'Published work';
  int revision = 0;
  int categoryReads = 0;
  int treeReads = 0;
  bool hasMore = false;
  bool needsRetry = false;
  int workCount = 1;
  int? combinedTotalCount;
  List<AsmrWork>? publishedWorks;
  int loadMoreCount = 0;
  int refreshCount = 0;
  Object? catalogError;
  String lastSearchQuery = '';
  int searchQueryChanges = 0;
  final searchQueries = <String>[];
  int initializations = 0;
  int categoryLoads = 0;
  final categoryRequestQueries = <String>[];
  final categoryRequestLanguages = <AppLanguage>[];
  int accountRestores = 0;
  int favoriteToggles = 0;
  bool cacheValid = true;
  Completer<void>? pendingInitialization;
  Object? initializationError;
  Completer<void>? pendingCategoryLoad;
  AppLanguage _presentationLanguage = AppLanguage.zh;

  int historyCount = 0;

  @override
  void setSearchQuery(String query, AsmrCategoryType category) {
    searchQueryChanges++;
    super.setSearchQuery(query, category);
  }

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async => [
    for (final path in ['one', 'two'])
      MusicTrack(
        path: path,
        displayName: path,
        groupKey: 'work-${work.id}',
        groupTitle: work.title,
        groupSubtitle: '',
        isSingle: false,
      ),
  ];

  @override
  Future<void> recordHistory(AsmrWork work) async {
    historyCount++;
  }

  void publish(String value) {
    title = value;
    revision++;
    notifyListeners();
  }

  @override
  bool get initialized => true;

  @override
  bool hasLoadedCategory(AsmrCategoryType category) => cacheValid;

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: 0,
  );

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) {
    categoryReads++;
    if (searchSession) {
      lastSearchQuery = searchQuery;
      if (searchQuery.isNotEmpty) searchQueries.add(searchQuery);
    }
    return AsmrCategoryViewState(
      category: category,
      works:
          publishedWorks ??
          [
            for (var i = 0; cacheValid && i < workCount; i++)
              AsmrWork.fromJson({
                'id': i + 1,
                'title': i == 0 ? title : '$title $i',
              }),
          ],
      isLoading: false,
      isLoadingMore: false,
      isRefreshing: false,
      isStale: false,
      hasAttemptedLoad: cacheValid,
      hasMore: hasMore,
      needsLoadMoreRetry: needsRetry,
      totalCount: combinedTotalCount ?? publishedWorks?.length ?? workCount,
      hasCombinedTotalCount: combinedTotalCount != null,
      activeQuery: searchQuery,
      lastError: catalogError,
      operationError: catalogError,
      revision: revision,
    );
  }

  @override
  AsmrTrackTreeViewState trackTreeViewState(String workId) {
    treeReads++;
    return super.trackTreeViewState(workId);
  }

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {
    initializations++;
    if (pendingInitialization case final pending?) await pending.future;
    if (initializationError case final error?) throw error;
  }

  @override
  AppLanguage get pageLanguage => _presentationLanguage;

  @override
  bool setPageLanguage(AppLanguage language) {
    _presentationLanguage = language;
    return false;
  }

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    categoryLoads++;
    categoryRequestQueries.add(searchQuery);
    categoryRequestLanguages.add(pageLanguage);
    final pending = pendingCategoryLoad;
    if (pending != null) await pending.future;
    if (!cacheValid) {
      cacheValid = true;
      notifyListeners();
    }
  }

  @override
  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    loadMoreCount++;
    hasMore = false;
    revision++;
    notifyListeners();
  }

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    refreshCount++;
    catalogError = null;
    revision++;
    notifyListeners();
  }

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {
    accountRestores++;
  }

  @override
  Future<void> syncAsmrAccount({bool force = false}) async {}

  @override
  Future<void> toggleFavorite(AsmrWork work) async {
    favoriteToggles++;
  }

  @override
  Future<void> setFavorites(
    List<AsmrWork> works, {
    required bool favorite,
  }) async {
    favoriteToggles++;
  }
}
