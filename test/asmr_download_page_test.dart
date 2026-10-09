import 'dart:async';

import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
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
