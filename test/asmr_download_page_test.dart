import 'dart:async';

import 'package:doujin_audio/app/application/app_runtime_lifecycle.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_selection_tree.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'ready download keeps rows across route motion and updates live inputs on $platform',
      (tester) async {
        await _openReadyDownload(tester);
        final navigator = Navigator.of(
          tester.element(find.byType(AsmrDownloadPage)),
        );
        var rowBuilds = 0;
        final previousCallback = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousCallback?.call(element, builtOnce);
          if (element.widget is AsmrDownloadSelectionList ||
              element.widget is AsmrDownloadNodeTile) {
            rowBuilds++;
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previousCallback);
        for (var visit = 0; visit < 2; visit++) {
          unawaited(
            navigator.push(
              buildAppPageRoute<void>(
                context: navigator.context,
                child: const Scaffold(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
          expect(rowBuilds, 0);
        }
        final file = find.byType(AsmrDownloadNodeTile).last;
        final tile = tester.widget<AsmrDownloadNodeTile>(file);
        expect(
          tile.selection.stateForPath(tile.node.track.relativePath),
          isTrue,
        );
        await tester.tap(find.text('Track.mp3'));
        await tester.pumpAndSettle();
        expect(rowBuilds, greaterThan(0));
        expect(
          tile.selection.stateForPath(tile.node.track.relativePath),
          isFalse,
        );

        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(file)).brightness, Brightness.dark);
        final originalWidth = tester.getSize(file).width;
        await tester.binding.setSurfaceSize(const Size(600, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpAndSettle();
        expect(tester.getSize(file).width, isNot(originalWidth));

        rowBuilds = 0;
        navigator.pop();
        await tester.pumpAndSettle();
        expect(rowBuilds, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.resetForTest();
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'download responds immediately and checks the destination once on $platform',
      (tester) async {
        final manager = await _openReadyDownload(tester);
        final button = _downloadStartButton();
        await tester.tap(button);
        await tester.tap(button);
        await tester.pump();
        expect(manager.destinationChecks, 1);
        expect(_downloadStartProgress(), findsOneWidget);
        expect(tester.widget<InkWell>(button).onTap, isNull);
        await tester.tap(button);
        await tester.pump();
        expect(manager.destinationChecks, 1);
        manager.destinationCheck.complete(true);
        await tester.pumpAndSettle();
        expect(manager.starts, 1);
        expect(find.byType(AsmrDownloadPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.resetForTest();
      },
      variant: TargetPlatformVariant({platform}),
    );

    for (final outcome in [
      'cancelled picker',
      'failed check',
      'failed start',
    ]) {
      testWidgets(
        'download button recovers after $outcome on $platform',
        (tester) async {
          final manager = await _openReadyDownload(tester);
          final button = _downloadStartButton();
          if (outcome == 'failed start') manager.failStart = true;
          if (outcome == 'cancelled picker') {
            manager.destinationPicker = Completer<String?>();
          }
          await tester.tap(button);
          await tester.pump();
          expect(_downloadStartProgress(), findsOneWidget);
          if (outcome == 'failed check') {
            manager.destinationCheck.completeError(StateError('unavailable'));
          } else {
            manager.destinationCheck.complete(outcome == 'failed start');
          }
          if (outcome == 'cancelled picker') {
            await tester.pump();
            expect(manager.pickerCalls, 1);
            expect(_downloadStartProgress(), findsOneWidget);
            await tester.tap(button);
            await tester.pump();
            expect(manager.pickerCalls, 1);
            manager.destinationPicker!.complete(null);
          }
          await tester.pumpAndSettle();
          expect(tester.widget<InkWell>(button).onTap, isNotNull);
          expect(_downloadStartProgress(), findsNothing);
          expect(manager.pickerCalls, outcome == 'cancelled picker' ? 1 : 0);
          expect(manager.starts, outcome == 'failed start' ? 1 : 0);
          expect(tester.takeException(), isNull);
          // Another attempt must acquire the guard after cancellation or failure.
          manager.destinationCheck = Completer<bool>();
          manager.failStart = false;
          if (outcome == 'cancelled picker') {
            manager.destinationPicker = Completer<String?>();
          }
          await tester.tap(button);
          await tester.pump();
          if (outcome == 'cancelled picker') {
            expect(manager.pickerCalls, 2);
            manager.destinationPicker!.complete(null);
            await tester.pumpAndSettle();
          } else {
            expect(manager.destinationChecks, 2);
            expect(_downloadStartProgress(), findsOneWidget);
            manager.destinationCheck.complete(true);
            await tester.pumpAndSettle();
            expect(manager.starts, outcome == 'failed start' ? 2 : 1);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          interaction.resetForTest();
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      'download preparation stops safely after disposal on $platform',
      (tester) async {
        final manager = await _openReadyDownload(tester);
        await tester.tap(_downloadStartButton());
        await tester.pump();
        expect(manager.destinationChecks, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        manager.destinationCheck.complete(true);
        await tester.pumpAndSettle();
        expect(manager.starts, 0);
        expect(tester.takeException(), isNull);
        interaction.resetForTest();
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'download preparation completed while hidden survives return on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _DelayedTreeController(createTestAsmrServices());
        final manager = AsmrDownloadManager(persistTasks: false);
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        addTearDown(manager.dispose);
        final work = AsmrWork.fromJson(const {'id': 1, 'title': 'Pending work'});
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    buildAppPageRoute<void>(
                      context: context,
                      child: AsmrDownloadPage(work: work),
                    ),
                  ),
                  child: const Text('Open download'),
                ),
              ),
            ),
            navigatorObservers: [UiInteractionNavigatorObserver()],
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              asmrDownloadManagerProvider.overrideWithValue(manager),
            ],
          ),
        );
        await tester.tap(find.text('Open download'));
        await tester.pump();
        expect(find.text('Pending work', skipOffstage: false), findsOneWidget);
        expect(find.byType(AsmrDownloadSelectionList), findsNothing);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(AsmrDownloadSelectionList), findsNothing);
        expect(
          find.byType(FileTreeSkeleton, skipOffstage: false),
          findsOneWidget,
        );
        final navigator = Navigator.of(
          tester.element(find.byType(AsmrDownloadPage)),
        );
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        controller.tree.complete([
          AsmrTrackFile(
            hash: 'track',
            title: 'Track.mp3',
            type: 'audio',
            streamUrl: 'https://example.invalid/Track.mp3',
            downloadUrl: 'https://example.invalid/Track.mp3',
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 1024,
            children: const [],
            workId: work.id,
            workTitle: work.title,
            sourceId: work.sourceId,
            relativePath: 'Track.mp3',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(AsmrDownloadSelectionList, skipOffstage: false),
          findsNothing,
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.text('Track.mp3'), findsOneWidget);
        final listState = tester.state(find.byType(AsmrDownloadSelectionList));
        await tester.tap(find.text('Track.mp3'));
        await tester.pumpAndSettle();
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pump();
        expect(
          tester.state(find.byType(AsmrDownloadSelectionList)),
          same(listState),
        );
        await tester.pumpAndSettle();
        expect(controller.loads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.resetForTest();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}

Finder _downloadStartButton() => find.descendant(
  of: find.byKey(const ValueKey('asmr_download_start_button')),
  matching: find.byType(InkWell),
);

Finder _downloadStartProgress() => find.descendant(
  of: find.byKey(const ValueKey('asmr_download_start_button')),
  matching: find.byType(CircularProgressIndicator),
);

Future<_StartDownloadManager> _openReadyDownload(WidgetTester tester) async {
  final fixture = AppRuntimeWidgetTestFixture(
    configureSettingsRepository: (settings) =>
        settings.asmrDownloadDestinationRoot = 'destination',
  );
  final controller = _DelayedTreeController(createTestAsmrServices());
  final manager = _StartDownloadManager();
  addTearDown(fixture.dispose);
  addTearDown(controller.dispose);
  addTearDown(manager.dispose);
  final work = AsmrWork.fromJson(const {'id': 1, 'title': 'Download work'});
  controller.tree.complete([
    AsmrTrackFile(
      hash: 'track',
      title: 'Track.mp3',
      type: 'audio',
      streamUrl: null,
      downloadUrl: 'https://example.invalid/Track.mp3',
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 1024,
      children: const [],
      workId: work.id,
      workTitle: work.title,
      sourceId: work.sourceId,
      relativePath: 'Track.mp3',
    ),
  ]);
  await tester.pumpWidget(
    fixture.build(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              buildAppPageRoute<void>(
                context: context,
                child: AsmrDownloadPage(work: work),
              ),
            ),
            child: const Text('Open download'),
          ),
        ),
      ),
      navigatorObservers: [UiInteractionNavigatorObserver()],
      overrides: [
        asmrLibraryControllerProvider.overrideWithValue(controller),
        asmrDownloadManagerProvider.overrideWithValue(manager),
        audioRuntimeCoordinatorProvider.overrideWithValue(_DownloadRuntime()),
      ],
    ),
  );
  await tester.tap(find.text('Open download'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Track.mp3'));
  await tester.pumpAndSettle();
  manager.holdDestinationCheck = true;
  return manager;
}

class _DownloadRuntime extends Fake implements AppRuntimeLifecycle {
  @override
  Future<void> start() async {}
}

class _StartDownloadManager extends AsmrDownloadManager {
  _StartDownloadManager() : super(persistTasks: false);

  bool holdDestinationCheck = false;
  bool failStart = false;
  Completer<bool> destinationCheck = Completer<bool>();
  Completer<String?>? destinationPicker;
  int destinationChecks = 0;
  int pickerCalls = 0;
  int starts = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> destinationExists(String folderPath) async {
    if (!holdDestinationCheck) return true;
    destinationChecks++;
    return destinationCheck.future;
  }

  @override
  Future<String?> pickDestinationFolder({String? dialogTitle}) async {
    pickerCalls++;
    return destinationPicker?.future;
  }

  @override
  Future<void> startDownload({
    required AsmrWork work,
    required List<AsmrTrackFile> selectedRoots,
    required String destinationRoot,
    required AsmrDownloadConflictPolicy conflictPolicy,
    bool saveMetadata = true,
    bool saveCover = true,
    int automaticFileRetryCount = kDefaultAsmrDownloadRetryCount,
    Iterable<AsmrDownloadFolderNameField> folderNameFields =
        kDefaultAsmrDownloadFolderNameFields,
    String? customWorkFolderName,
  }) async {
    starts++;
    if (failStart) throw StateError('start failed');
  }
}

class _DelayedTreeController extends AsmrLibraryController {
  _DelayedTreeController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  final tree = Completer<List<AsmrTrackFile>>();
  int loads = 0;

  @override
  Future<List<AsmrTrackFile>> ensureTrackTree(
    AsmrWork work, {
    bool forceRefresh = false,
  }) {
    loads++;
    return tree.future;
  }
}
