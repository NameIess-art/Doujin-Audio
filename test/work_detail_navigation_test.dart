import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/global_shortcuts.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/audio_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

final _main = find.byKey(const ValueKey('main_content_region'));
final _pane = find.byKey(const ValueKey('work_detail_pane'));
final _input = find.byKey(const ValueKey('detail_input'));

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(UiInteractionCoordinator.instance.idleDelay);
  await tester.pumpAndSettle();
}

Future<void> _finishRouteAnimation(WidgetTester tester) async {
  // Entry tests exercise routing while real detail file discovery is pending.
  await tester.pump();
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<WorkDetailNavigation> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  bool withSession = false,
  bool withNavigationLock = false,
  bool showAsmrOne = false,
  int libraryWorkCount = 0,
  Widget? home,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final fixture = AppRuntimeWidgetTestFixture(
    configureSettingsRepository: (settings) =>
        settings.showAsmrOne = showAsmrOne,
  );
  addTearDown(fixture.dispose);
  fixture.settings.syncSlice(isInitialized: true);
  fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
  if (libraryWorkCount > 0) {
    fixture.library.addTracks(
      List.generate(
        libraryWorkCount,
        (index) => testMusicTrack(
          name: 'Track $index',
          path: '/library/work-$index/track.mp3',
          groupKey: '/library/work-$index',
          groupTitle: 'Work $index',
        ),
      ),
      persist: false,
    );
    await tester.runAsync(() => fixture.library.ensureCardSnapshot());
  }
  final sessions = <PlaybackSessionSnapshot>[];
  if (withSession) {
    final session = PlaybackSession(
      id: 'pane_session',
      currentTrackPath: '/audio/pane.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.shutdown);
    fixture.playbackService.registerSession(session);
    sessions.add(PlaybackSessionSnapshot.fromRuntime(session));
  }
  fixture.playbackService.syncSlice(
    activeSessions: fixture.playbackService.activeSessions,
    playingSessionCount: 0,
    focusedSessionId: withSession ? 'pane_session' : null,
    coverGeneration: 0,
    isInitialized: true,
  );
  final root = GlobalKey<NavigatorState>();
  final navigation = WorkDetailNavigation(rootNavigatorKey: root);
  addTearDown(navigation.dispose);
  final rootObserver = UiInteractionNavigatorObserver();
  addTearDown(rootObserver.dispose);
  await tester.pumpWidget(
    fixture.build(
      WorkDetailNavigationScope(
        navigation: navigation,
        child: GlobalShortcuts(
          navigatorKey: root,
          child: MaterialApp(
            navigatorKey: root,
            navigatorObservers: [if (withNavigationLock) rootObserver],
            builder: (_, child) => withNavigationLock
                ? AppNavigationInputLock(
                    navigationAllowed:
                        UiInteractionCoordinator.instance.navigationAllowed,
                    child: child!,
                  )
                : child!,
            home: home ?? const MainScreen(),
          ),
        ),
      ),
      overrides: [
        settingsStateProvider.overrideWithValue(
          AsyncData(fixture.settings.slice.state),
        ),
        mainOverlayUiProvider.overrideWithValue(
          MainOverlayUiState(
            overlaySessions: sessions,
            playingSessionCount: 0,
            hasPlayingAudioSession: false,
            activeSessionCount: sessions.length,
            isInitialized: true,
            startupReady: true,
          ),
        ),
      ],
    ),
  );
  await _settle(tester);
  return navigation;
}

Future<void> _open(
  WidgetTester tester,
  WorkDetailNavigation navigation,
  String identity, {
  bool returnToMain = false,
}) async {
  unawaited(
    navigation.open(
      identity,
      (_) => MaterialPageRoute<void>(
        settings: const RouteSettings(name: workDetailRouteName),
        builder: (_) => _Detail(identity: identity),
      ),
      returnToMain: returnToMain,
    ),
  );
  await _settle(tester);
}

class _Detail extends StatefulWidget {
  const _Detail({required this.identity});
  final String identity;

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  final input = TextEditingController();
  String? result;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Work ${widget.identity}')),
    body: Column(
      children: [
        TextField(key: const ValueKey('detail_input'), controller: input),
        TextButton(
          onPressed: () async {
            final value = await Navigator.of(context).push<String>(
              MaterialPageRoute<String>(
                builder: (context) => Scaffold(
                  appBar: AppBar(title: const Text('Edit work')),
                  body: Column(
                    children: [
                      const TextField(key: ValueKey('child_input')),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop('saved'),
                        child: const Text('Save child'),
                      ),
                    ],
                  ),
                ),
              ),
            );
            if (mounted) setState(() => result = value);
          },
          child: const Text('Open child'),
        ),
        if (result != null) Text('Result $result'),
      ],
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets(
    'portrait secondary routes cover the main dock through entry and exit',
    (tester) async {
      final navigation = await _pumpApp(
        tester,
        size: const Size(390, 820),
        withSession: true,
      );
      final dock = find.byKey(const ValueKey('mobile_bottom_capsule_panel'));
      expect(dock, findsOneWidget);
      final content = navigation.contentNavigatorKey.currentState!;
      unawaited(
        content.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Portrait secondary')),
          ),
        ),
      );
      await _settle(tester);
      expect(dock, findsNothing);
      expect(navigation.isContentOpen, isTrue);
      content.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(dock, findsNothing);
      expect(navigation.isContentOpen, isTrue);
      await _settle(tester);
      expect(dock, findsOneWidget);
      expect(navigation.isContentOpen, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'portrait search retains input when rotated into the landscape content navigator',
    (tester) async {
      final navigation = await _pumpApp(tester, size: const Size(390, 820));
      await tester.tap(find.byKey(const ValueKey('library_search_button')));
      await _settle(tester);
      final field = find.byKey(const ValueKey('app_search_field'));
      await tester.enterText(field, 'retained query');
      await _settle(tester);
      expect(navigation.isContentOpen, isTrue);
      expect(navigation.canOpenInPane(tester.element(field)), isFalse);
      final searchState = tester.state(field);
      tester.view.physicalSize = const Size(1280, 800);
      await _settle(tester);
      expect(tester.state(field), same(searchState));
      expect(
        tester.widget<TextField>(field).controller!.text,
        'retained query',
      );
      expect(navigation.canOpenInPane(tester.element(field)), isTrue);
      expect(tester.getRect(_main).contains(tester.getCenter(field)), isTrue);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(navigation.isContentOpen, isFalse);
      expect(
        find.byKey(const ValueKey('library_refresh_button')),
        findsOneWidget,
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'portrait detail slides over the painted main page on entry and exit',
    (tester) async {
      final surface = GlobalKey();
      final navigation = await _pumpApp(
        tester,
        size: const Size(390, 820),
        home: RepaintBoundary(
          key: surface,
          child: const WorkDetailPane(
            isLandscape: false,
            sidebarWidth: 0,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      );
      final body = find.byKey(const ValueKey('sliding_detail_body'));
      final route = buildAppPageRoute<void>(
        context: navigation.navigatorKey.currentContext!,
        settings: const RouteSettings(name: workDetailRouteName),
        workDetailTransition: true,
        child: const Scaffold(
          backgroundColor: Colors.transparent,
          body: AppPageContentTransition(
            child: ColoredBox(
              key: ValueKey('sliding_detail_body'),
              color: Colors.blue,
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
      Future<void> expectMainBehindSlide() async {
        expect(tester.getRect(body).left, inExclusiveRange(8, 380));
        final colors = await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(surface))
              .toImage();
          final bytes = (await image.toByteData())!;
          Color pixel(int x) {
            final offset = (400 * image.width + x) * 4;
            return Color.fromARGB(
              bytes.getUint8(offset + 3),
              bytes.getUint8(offset),
              bytes.getUint8(offset + 1),
              bytes.getUint8(offset + 2),
            );
          }

          final result = (pixel(8), pixel(380));
          image.dispose();
          return result;
        });
        expect(colors, (const Color(0xfff44336), const Color(0xff2196f3)));
      }

      unawaited(navigation.open('slide', (_) => route));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      await expectMainBehindSlide();
      await _settle(tester);
      navigation.navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await expectMainBehindSlide();
      await _settle(tester);
      expect(navigation.isOpen, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final split in [false, true]) {
      testWidgets(
        'landscape playback details cover the window from every entry (split=$split) on $platform',
        (tester) async {
          final navigation = await _pumpApp(tester, withSession: true);
          if (split) {
            await _open(tester, navigation, 'A');
            await tester.enterText(_input, 'retained detail input');
          }
          // The runtime fixture wraps this app in its own MaterialApp.
          final root = Navigator.of(
            navigation.rootNavigatorKey.currentContext!,
            rootNavigator: true,
          );
          final content = navigation.contentNavigatorKey.currentState!;
          final sidebarCarousel = tester.widget<ActiveSessionCarousel>(
            find.descendant(
              of: find.byType(DesktopMainNavigation),
              matching: find.byType(ActiveSessionCarousel),
            ),
          );
          Future<void> expectFullscreenAndClose() async {
            await _settle(tester);
            final detail = find.byType(SessionDetailPage);
            expect(detail, findsOneWidget);
            expect(Navigator.of(tester.element(detail)), same(root));
            expect(tester.getRect(detail), Offset.zero & const Size(1280, 800));
            expect(
              find.byType(DesktopMainNavigation).hitTestable(),
              findsNothing,
            );
            root.pop();
            await _settle(tester);
            expect(detail, findsNothing);
            if (split) {
              expect(navigation.isOpen, isTrue);
              expect(
                tester.widget<TextField>(_input).controller!.text,
                'retained detail input',
              );
            }
          }

          await tester.tap(
            find.byKey(
              const ValueKey('active_session_ink_pane_session_expanded'),
            ),
          );
          await expectFullscreenAndClose();

          final rail = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          await tester.tap(find.byWidget(rail.destinations[1].label));
          await _settle(tester);
          tester.widget<SessionListCard>(find.byType(SessionListCard)).onOpen();
          await expectFullscreenAndClose();
          expect(content.canPop(), isFalse);

          unawaited(
            content.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  key: const ValueKey('content_carousel_page'),
                  body: Center(
                    child: SizedBox(
                      width: 300,
                      height: kActiveSessionCarouselDockHeight,
                      child: ActiveSessionCarousel(
                        sessions: sidebarCarousel.sessions,
                        i18n: sidebarCarousel.i18n,
                        presentation:
                            ActiveSessionCarouselPresentation.embedded,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await _settle(tester);
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(const ValueKey('content_carousel_page')),
                  matching: find.byKey(
                    const ValueKey('active_session_ink_pane_session_expanded'),
                  ),
                )
                .hitTestable(),
          );
          await expectFullscreenAndClose();
          expect(content.canPop(), isTrue);
          expect(
            find.byKey(const ValueKey('content_carousel_page')),
            findsOneWidget,
          );
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    for (final split in [false, true]) {
      testWidgets(
        'secondary pages stay in content and reset on tab switch (split=$split) on $platform',
        (tester) async {
          final navigation = await _pumpApp(tester, withNavigationLock: true);
          if (split) await _open(tester, navigation, 'A');
          final mainRect = tester.getRect(_main);
          final content = navigation.contentNavigatorKey.currentState!;
          var completed = false;
          unawaited(
            content
                .push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      key: const ValueKey('secondary_content_page'),
                      appBar: AppBar(title: const Text('Secondary content')),
                      body: TextButton(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const Scaffold(body: Text('Secondary child')),
                          ),
                        ),
                        child: const Text('Open content child'),
                      ),
                    ),
                  ),
                )
                .then((_) => completed = true),
          );
          await _settle(tester);
          expect(
            tester.getRect(
              find.byKey(const ValueKey('secondary_content_page')),
            ),
            mainRect,
          );
          expect(navigation.rootNavigatorKey.currentState!.canPop(), isFalse);
          expect(
            find.byType(DesktopMainNavigation).hitTestable(),
            findsOneWidget,
          );
          expect(navigation.isContentOpen, isTrue);
          expect(
            navigation.canOpenInPane(
              tester.element(find.text('Secondary content')),
            ),
            isTrue,
          );
          await tester.tap(find.text('Open content child'));
          await _settle(tester);
          if (platform == TargetPlatform.windows) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.binding.handlePopRoute();
          }
          await _settle(tester);
          // Back closes the right detail before the left content stack.
          if (split) {
            expect(navigation.isOpen, isFalse);
            expect(find.text('Secondary child'), findsOneWidget);
            content.pop();
            await _settle(tester);
          }
          expect(find.text('Secondary child'), findsNothing);
          await tester.tap(find.text('Open content child'));
          await _settle(tester);
          if (split) await _open(tester, navigation, 'A');
          final rail = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          await tester.tap(find.byWidget(rail.destinations[1].label));
          await _settle(tester);
          expect(completed, isTrue);
          expect(navigation.isContentOpen, isFalse);
          expect(find.text('Secondary content'), findsNothing);
          expect(find.text('Secondary child'), findsNothing);
          if (split) expect(find.text('Work A'), findsOneWidget);
          final nextRail = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          await tester.tap(find.byWidget(nextRail.destinations[0].label));
          await _settle(tester);
          expect(navigation.isContentOpen, isFalse);
          expect(
            find.byKey(const ValueKey('library_search_button')),
            findsOneWidget,
          );
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      'both library headers retain refresh actions in narrow split panes on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester, showAsmrOne: true);
        await _open(tester, navigation, 'A');
        expect(
          tester.getSize(_main).width,
          lessThan(tester.getSize(_main).height),
        );
        final library = find.byKey(const ValueKey('library_refresh_button'));
        expect(library, findsOneWidget);
        expect(
          tester.getRect(_main).contains(tester.getCenter(library)),
          isTrue,
        );
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        await tester.tap(find.byWidget(rail.destinations[0].label));
        await _settle(tester);
        final asmr = find.byKey(const ValueKey('asmr_refresh_button'));
        expect(asmr, findsOneWidget);
        expect(tester.getRect(_main).contains(tester.getCenter(asmr)), isTrue);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'library search stays beside the menu and opens details in the right pane on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester, withNavigationLock: true);
        await tester.tap(find.byKey(const ValueKey('library_search_button')));
        await _settle(tester);
        final search = find.byKey(const ValueKey('app_search_close'));
        expect(search, findsOneWidget);
        final searchContext = tester.element(search);
        expect(
          Navigator.of(searchContext),
          same(navigation.contentNavigatorKey.currentState),
        );
        expect(navigation.canOpenInPane(searchContext), isTrue);
        expect(navigation.rootNavigatorKey.currentState!.canPop(), isFalse);
        await _open(tester, navigation, 'A');
        expect(search, findsOneWidget);
        expect(
          tester.getRect(_main).contains(tester.getCenter(search)),
          isTrue,
        );
        expect(find.text('Work A'), findsOneWidget);
        navigation.navigatorKey.currentState!.pop();
        await _settle(tester);
        await tester.tap(search);
        await _settle(tester);
        expect(navigation.isContentOpen, isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );

    for (final asmr in [false, true]) {
      testWidgets(
        'search results open visible details and return with input unlocked (asmr=$asmr) on $platform',
        (tester) async {
          final navigation = await _pumpApp(tester, withNavigationLock: true);
          final root = navigation.rootNavigatorKey.currentState!;
          final controller = TextEditingController(text: 'Search work');
          final focus = FocusNode();
          addTearDown(controller.dispose);
          addTearDown(focus.dispose);
          final work = AsmrWork.fromJson(const {
            'id': 42,
            'title': 'Search work',
          });
          var finished = false;
          unawaited(
            root.push(
              buildAppPageRoute<void>(
                context: root.overlay!.context,
                duration: Duration.zero,
                child: Builder(
                  builder: (context) => AppSearchPageScaffold<int>(
                    controller: controller,
                    focusNode: focus,
                    hintText: 'Search',
                    categories: const [
                      AppSearchCategory(value: 0, label: 'All'),
                    ],
                    selectedCategory: 0,
                    onCategorySelected: (_) {},
                    onChanged: (_) {},
                    onSubmitted: (_) {},
                    onCloseOrClear: () => root.pop(),
                    body: Center(
                      child: TextButton(
                        onPressed: () => unawaited(
                          (asmr
                                  ? showAsmrWorkDetailSheet(context, work)
                                  : showAudioDetailSheet(
                                      context,
                                      AudioDetailTarget.libraryRootFolder(
                                        '/library/search-work',
                                      ),
                                    ))
                              .then((_) => finished = true),
                        ),
                        child: const Text('Open search result'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await _settle(tester);
          await tester.tap(find.text('Open search result'));
          await _finishRouteAnimation(tester);

          expect(
            UiInteractionCoordinator.instance.navigationAllowed.value,
            isTrue,
          );
          final detail = find.byType(WorkDetailPage);
          expect(detail, findsOneWidget);
          expect(navigation.isOpen, isFalse);
          expect(finished, isFalse);
          expect(Navigator.of(tester.element(detail)), same(root));
          root.pop();
          await _settle(tester);
          expect(finished, isTrue);
          expect(find.byType(AppSearchPageScaffold<int>), findsOneWidget);
          expect(controller.text, 'Search work');
          expect(
            UiInteractionCoordinator.instance.navigationAllowed.value,
            isTrue,
          );
          await tester.tap(find.byKey(const ValueKey('app_search_close')));
          await _settle(tester);
          expect(root.canPop(), isFalse);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      'local and ASMR public entrypoints share the detail pane on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester);
        final context = tester.element(find.byType(MainScreen));
        final target = AudioDetailTarget.libraryRootFolder('/library/entry');
        var localFinished = false;
        unawaited(
          showAudioDetailSheet(
            context,
            target,
          ).then((_) => localFinished = true),
        );
        await _finishRouteAnimation(tester);
        final local = tester.widget<WorkDetailPage>(
          find.byType(WorkDetailPage),
        );
        expect(local.localTarget, target);
        expect(navigation.rootNavigatorKey.currentState!.canPop(), isFalse);
        expect(tester.getSize(_pane).width, 509.5);
        final localState = tester.state(find.byType(WorkDetailPage));
        unawaited(showAudioDetailSheet(context, target));
        await _finishRouteAnimation(tester);
        expect(tester.state(find.byType(WorkDetailPage)), same(localState));
        final work = AsmrWork.fromJson(const {
          'id': 42,
          'title': 'Online entry',
        });
        var asmrFinished = false;
        unawaited(
          showAsmrWorkDetailSheet(
            context,
            work,
          ).then((_) => asmrFinished = true),
        );
        await _finishRouteAnimation(tester);
        expect(localFinished, isTrue);
        expect(
          tester.widget<WorkDetailPage>(find.byType(WorkDetailPage)).asmrWork,
          same(work),
        );
        final asmrState = tester.state(find.byType(WorkDetailPage));
        unawaited(
          showAsmrWorkDetailSheet(context, work.copyWith(isFavorite: true)),
        );
        await _finishRouteAnimation(tester);
        expect(tester.state(find.byType(WorkDetailPage)), same(asmrState));
        expect(asmrFinished, isFalse);
        navigation.navigatorKey.currentState!.pop();
        await _settle(tester);
        expect(asmrFinished, isTrue);
        expect(navigation.isOpen, isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'main stays interactive beside equal detail panes on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester);
        expect(tester.getSize(_main).width, 1020);
        await _open(tester, navigation, 'A');
        expect(tester.getSize(_main).width, 509.5);
        expect(tester.getSize(_pane).width, 509.5);
        expect(tester.getRect(_main).right + 1, tester.getRect(_pane).left);
        final mainState = tester.state(find.byType(MainScreen));
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        await tester.tap(find.byWidget(rail.destinations[1].label));
        await _settle(tester);
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          1,
        );
        expect(tester.state(find.byType(MainScreen)), same(mainState));
        expect(find.text('Work A'), findsOneWidget);
        await tester.tap(find.byTooltip('Back'));
        await _settle(tester);
        expect(navigation.isOpen, isFalse);
        expect(tester.getSize(_main).width, 1020);
        if (platform == TargetPlatform.windows) {
          tester.view.physicalSize = const Size(960, 600);
          await _settle(tester);
          await _open(tester, navigation, 'A');
          expect(tester.getSize(_main).width, 349.5);
          expect(tester.getSize(_pane).width, 349.5);
        }
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'bottom library reflow remains clickable after detail closes on $platform',
      (tester) async {
        final navigation = await _pumpApp(
          tester,
          libraryWorkCount: 40,
          withSession: true,
          withNavigationLock: true,
        );
        final list = find.descendant(
          of: _main,
          matching: find.byType(ListView),
        );
        expect(list, findsOneWidget);
        final controller = tester.widget<ListView>(list).controller!;
        controller.jumpTo(controller.position.maxScrollExtent);
        await _settle(tester);
        final wideExtent = controller.position.maxScrollExtent;
        for (var cycle = 0; cycle < 2; cycle++) {
          unawaited(
            showAudioDetailSheet(
              tester.element(list),
              AudioDetailTarget.libraryRootFolder('/library/work-39'),
            ),
          );
          await _finishRouteAnimation(tester);
          expect(controller.position.maxScrollExtent, greaterThan(wideExtent));
          if (cycle == 1) {
            controller.jumpTo(controller.position.maxScrollExtent);
            await _finishRouteAnimation(tester);
          }
          await tester.tap(
            find.byKey(const ValueKey('work_detail_back_button')),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(navigation.isOpen, isFalse);
          expect(
            UiInteractionCoordinator.instance.navigationAllowed.value,
            isTrue,
          );
          expect(
            controller.offset,
            lessThanOrEqualTo(controller.position.maxScrollExtent),
          );
          expect(
            controller.position.maxScrollExtent,
            closeTo(wideExtent, 0.01),
          );
        }
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        await tester.tap(find.byWidget(rail.destinations[1].label));
        await _settle(tester);
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          1,
        );
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'main scroll position survives detail navigation and tab switches on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester, size: const Size(1280, 480));
        Future<void> selectTab(int index) async {
          final rail = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          await tester.tap(find.byWidget(rail.destinations[index].label));
          await _settle(tester);
        }

        final settingsIndex =
            tester
                .widget<NavigationRail>(find.byType(NavigationRail))
                .destinations
                .length -
            1;
        await selectTab(settingsIndex);
        final settings = find.byType(SettingsTab);
        final scroll = find.descendant(
          of: settings,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        );
        final settingsState = tester.state(settings);
        final scrollState = tester.state<ScrollableState>(scroll);
        await tester.drag(scroll, const Offset(0, -160));
        await _settle(tester);
        final pixels = scrollState.position.pixels;
        expect(pixels, greaterThan(0));

        void expectPreserved() {
          expect(tester.state(settings), same(settingsState));
          expect(tester.state<ScrollableState>(scroll), same(scrollState));
          expect(scrollState.position.pixels, closeTo(pixels, 0.01));
        }

        await _open(tester, navigation, 'A');
        expectPreserved();
        await _open(tester, navigation, 'B');
        expectPreserved();
        navigation.navigatorKey.currentState!.pop();
        await _settle(tester);
        expectPreserved();
        await selectTab(0);
        await selectTab(settingsIndex);
        expectPreserved();
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'same work retains edits and another work discards them on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester);
        await _open(tester, navigation, 'A');
        await tester.enterText(_input, 'unsaved');
        final detailState = tester.state(find.byType(_Detail));
        await _open(tester, navigation, 'A');
        expect(tester.state(find.byType(_Detail)), same(detailState));
        expect(tester.widget<TextField>(_input).controller!.text, 'unsaved');
        await tester.tap(find.text('Open child'));
        await _settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('child_input')),
          'discard',
        );
        await _open(tester, navigation, 'B');
        expect(find.text('Work A'), findsNothing);
        expect(find.text('Edit work'), findsNothing);
        expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        navigation.navigatorKey.currentState!.pop();
        await _settle(tester);
        expect(navigation.isOpen, isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'child result returns to detail and main routes are cleared on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester);
        final root = navigation.rootNavigatorKey.currentState!;
        unawaited(
          root.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Playback detail')),
            ),
          ),
        );
        await _settle(tester);
        await _open(tester, navigation, 'A', returnToMain: true);
        expect(root.canPop(), isFalse);
        expect(find.text('Playback detail'), findsNothing);
        await tester.tap(find.text('Open child'));
        await _settle(tester);
        await tester.tap(find.text('Save child'));
        await _settle(tester);
        expect(find.text('Result saved'), findsOneWidget);
        expect(root.canPop(), isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'system back closes dialog, root route, child, then detail on $platform',
      (tester) async {
        final navigation = await _pumpApp(tester);
        await _open(tester, navigation, 'A');
        await tester.tap(find.text('Open child'));
        await _settle(tester);
        final root = navigation.rootNavigatorKey.currentState!;
        unawaited(
          root.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Root page')),
            ),
          ),
        );
        await _settle(tester);
        unawaited(
          showDialog<void>(
            context: root.overlay!.context,
            builder: (_) => const AlertDialog(title: Text('Dialog')),
          ),
        );
        await _settle(tester);
        Future<void> back() async {
          if (platform == TargetPlatform.windows) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.binding.handlePopRoute();
          }
          await _settle(tester);
        }

        await back();
        expect(find.text('Dialog'), findsNothing);
        expect(find.text('Root page'), findsOneWidget);
        await back();
        expect(find.text('Root page'), findsNothing);
        expect(find.text('Edit work'), findsOneWidget);
        await back();
        expect(find.text('Edit work'), findsNothing);
        expect(find.text('Work A'), findsOneWidget);
        await back();
        expect(navigation.isOpen, isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'renaming the current work retains its page and unsaved child input',
    (tester) async {
      final navigation = await _pumpApp(tester);
      await _open(tester, navigation, 'old-path');
      final detailState = tester.state(find.byType(_Detail));
      await tester.tap(find.text('Open child'));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('child_input')),
        'editing',
      );
      navigation.updateIdentity('old-path', 'renamed-path');
      await _open(tester, navigation, 'renamed-path');
      expect(find.text('Edit work'), findsOneWidget);
      expect(find.text('editing'), findsOneWidget);
      expect(
        tester.state(find.byType(_Detail, skipOffstage: false)),
        same(detailState),
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'narrow landscape temporarily collapses sidebar without saving preference',
    (tester) async {
      final navigation = await _pumpApp(tester, size: const Size(850, 480));
      expect(
        tester
            .widget<DesktopMainNavigation>(find.byType(DesktopMainNavigation))
            .isMenuCollapsed,
        isFalse,
      );
      await _open(tester, navigation, 'A');
      expect(
        tester
            .widget<DesktopMainNavigation>(find.byType(DesktopMainNavigation))
            .isMenuCollapsed,
        isTrue,
      );
      expect(tester.getSize(_main).width, 384.5);
      expect(tester.getSize(_pane).width, 384.5);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'desktop_menu_collapsed',
        ),
        isNull,
      );
      tester.view.physicalSize = const Size(1280, 800);
      await _settle(tester);
      expect(
        tester
            .widget<DesktopMainNavigation>(find.byType(DesktopMainNavigation))
            .isMenuCollapsed,
        isFalse,
      );
      expect(tester.getSize(_pane).width, 509.5);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'automatic sidebar collapse keeps panes equal while opening and closing',
    (tester) async {
      final navigation = await _pumpApp(tester, size: const Size(850, 480));
      Future<void> expectEqualFrames() async {
        for (final elapsed in [
          Duration.zero,
          const Duration(milliseconds: 100),
        ]) {
          await tester.pump(elapsed);
          expect(
            tester.getSize(_main).width,
            closeTo(tester.getSize(_pane).width, 0.01),
          );
          expect(
            tester.getRect(_pane).left - tester.getRect(_main).right,
            closeTo(1, 0.01),
          );
        }
      }

      unawaited(
        navigation.open(
          'A',
          (_) => MaterialPageRoute<void>(
            settings: const RouteSettings(name: workDetailRouteName),
            builder: (_) => const _Detail(identity: 'A'),
          ),
        ),
      );
      await expectEqualFrames();
      await _settle(tester);
      expect(tester.getSize(_main).width, 384.5);
      navigation.navigatorKey.currentState!.pop();
      await expectEqualFrames();
      await _settle(tester);
      expect(navigation.isOpen, isFalse);
      expect(tester.getSize(_main).width, 590);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'portrait to landscape keeps panes equal during sidebar animation',
    (tester) async {
      final navigation = await _pumpApp(tester, size: const Size(390, 820));
      await _open(tester, navigation, 'A');
      tester.view.physicalSize = const Size(820, 390);
      final frames = <(double, double, double)>[];
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 100),
      ]) {
        await tester.pump(elapsed);
        frames.add((
          tester.getSize(_main).width,
          tester.getSize(_pane).width,
          tester.getRect(_pane).left - tester.getRect(_main).right,
        ));
      }
      await _settle(tester);
      expect(
        frames.map((frame) => [frame.$1 - frame.$2, frame.$3]),
        [
          [closeTo(0, 0.01), closeTo(1, 0.01)],
          [closeTo(0, 0.01), closeTo(1, 0.01)],
        ],
        reason: 'Frames (main width, detail width, divider gap): $frames',
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'rotation without playback preserves the nested editing page',
    (tester) async {
      final navigation = await _pumpApp(tester, size: const Size(390, 820));
      await _open(tester, navigation, 'A');
      await tester.tap(find.text('Open child'));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('child_input')), 'edit');
      await _settle(tester);
      final state = tester.state(find.byType(EditableText));
      tester.view.physicalSize = const Size(820, 390);
      await _settle(tester);
      expect(tester.state(find.byType(EditableText)), same(state));
      expect(find.text('edit'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'portrait rotation preserves child input and changes dock ownership',
    (tester) async {
      final navigation = await _pumpApp(
        tester,
        size: const Size(390, 820),
        withSession: true,
      );
      await _open(tester, navigation, 'A');
      expect(tester.getSize(_pane).width, 390);
      expect(
        find.byKey(const ValueKey('routed_playback_dock')),
        findsOneWidget,
      );
      await tester.tap(find.text('Open child'));
      await _settle(tester);
      final input = find.byKey(const ValueKey('child_input'));
      await tester.enterText(input, 'rotation edit');
      await _settle(tester);
      final state = tester.state(find.byType(EditableText));
      tester.view.physicalSize = const Size(820, 390);
      await _settle(tester);
      expect(tester.state(find.byType(EditableText)), same(state));
      expect(find.text('rotation edit'), findsOneWidget);
      expect(tester.getSize(_main).width, 369.5);
      expect(tester.getSize(_pane).width, 369.5);
      expect(find.byKey(const ValueKey('routed_playback_dock')), findsNothing);
      expect(find.byType(ActiveSessionCarousel), findsOneWidget);
      tester.view.physicalSize = const Size(390, 820);
      await _settle(tester);
      expect(tester.state(find.byType(EditableText)), same(state));
      expect(find.text('rotation edit'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
