import 'dart:async';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_models.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/domain/audio_detail_store.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/domain/library_persistence_repository.dart';
import 'package:doujin_audio/features/library/presentation/folder_cover_selector.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_removal_feedback.dart';
import 'package:doujin_audio/features/library/presentation/library_scan_feedback.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_empty_scan.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_ui_helpers.dart';
import 'package:doujin_audio/features/library/presentation/library_view_models.dart';
import 'package:doujin_audio/features/library/presentation/work_image_viewer_page.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _InMemoryLibraryRepo repo;
  late AppLanguageProvider i18n;
  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    repo = _InMemoryLibraryRepo();
    i18n = AppLanguageProvider();
    await i18n.initialized;
    settings = SettingsRepository();
  });

  tearDown(() {
    i18n.dispose();
  });

  testWidgets(
    '#52 FolderCoverSelector handles null storedCoverPath without calling onCoverSelected and guards folder switch across await',
    (tester) async {
      final firstCommit = Completer<String?>();
      final service = LibraryService();
      final fakeCovers = _FakeCoverArtworkCacheService(
        libraryService: service,
        onDiscover: (folder) async => ['$folder/a.jpg', '$folder/b.jpg'],
        onSetManualCover: (folder, image) => firstCommit.future,
      );
      final library = LibraryFacade.create(
        databaseRepository: repo,
        service: service,
        coverArtworkCacheService: fakeCovers,
      );
      addTearDown(library.dispose);

      final selectedCallbacks = <String>[];
      var currentFolder = 'C:/Covers/FolderA';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(library),
          ],
          child: StatefulBuilder(
            builder: (context, setState) {
              return MaterialApp(
                theme: ThemeData(extensions: const [AppDesignTokens.light]),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        SizedBox(
                          width: 400,
                          child: FolderCoverSelector(
                            folderPath: currentFolder,
                            initialCoverPath: '$currentFolder/a.jpg',
                            compactNavigation: true,
                            onCoverSelected: selectedCallbacks.add,
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('switch_folder'),
                          onPressed: () => setState(() {
                            currentFolder = 'C:/Covers/FolderB';
                          }),
                          child: const Text('Switch'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Advance to the second candidate image and tap save.
      await tester.tap(
        find.byKey(const ValueKey<String>('audio_detail_cover_next_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('audio_detail_cover_action_capsule')),
      );
      await tester.pump();

      // Returning null must show failure snackbar and not call onCoverSelected.
      firstCommit.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(selectedCallbacks, isEmpty);
      expect(find.text(i18n.tr('audio_detail_save_failed')), findsOneWidget);

      // Now start a second save, switch folder before it completes, and complete with a path.
      final secondCommit = Completer<String?>();
      fakeCovers.onSetManualCover = (_, _) => secondCommit.future;
      await tester.tap(
        find.byKey(const ValueKey<String>('audio_detail_cover_action_capsule')),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('switch_folder')));
      await tester.pump();

      secondCommit.complete('C:/Covers/FolderA/b.jpg');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(selectedCallbacks, isEmpty);
    },
  );

  testWidgets(
    '#54 LibraryFolderNodeWidget disposes cleanly on unmount without leaking ExpansibleController',
    (tester) async {
      final library = LibraryFacade.create(databaseRepository: repo)
        ..configureCoverArtworkRuntime(
          isActiveCoverKey: (_) => false,
          onActiveCoverChanged: () {},
        );
      addTearDown(library.dispose);

      final folder = FolderNode('WorkA', 'C:/Tree/WorkA');
      var showNode = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(library),
            settingsRepositoryProvider.overrideWithValue(settings),
          ],
          child: StatefulBuilder(
            builder: (context, setState) {
              return MaterialApp(
                theme: ThemeData(extensions: const [AppDesignTokens.light]),
                home: Scaffold(
                  body: Column(
                    children: [
                      if (showNode)
                        LibraryFolderNodeWidget(
                          folder: folder,
                          initiallyExpanded: false,
                          searchQuery: '',
                        ),
                      TextButton(
                        key: const ValueKey('unmount_node'),
                        onPressed: () => setState(() => showNode = false),
                        child: const Text('Unmount'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('unmount_node')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(LibraryFolderNodeWidget), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '#72 removeLibraryBatchSelections stops cleanly when unmounted mid-loop',
    (tester) async {
      final library = LibraryFacade.create(databaseRepository: repo)
        ..configureCoverArtworkRuntime(
          isActiveCoverKey: (_) => false,
          onActiveCoverChanged: () {},
        );
      addTearDown(library.dispose);

      final removalService = UndoableRemovalService();
      addTearDown(removalService.dispose);

      var mountedChild = true;
      BuildContext? capturedContext;
      WidgetRef? capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(library),
            undoableRemovalServiceProvider.overrideWithValue(removalService),
          ],
          child: StatefulBuilder(
            builder: (context, setState) {
              return MaterialApp(
                theme: ThemeData(extensions: const [AppDesignTokens.light]),
                home: Scaffold(
                  body: Column(
                    children: [
                      if (mountedChild)
                        Consumer(
                          builder: (childContext, ref, _) {
                            capturedContext = childContext;
                            capturedRef = ref;
                            return const SizedBox.shrink();
                          },
                        ),
                      TextButton(
                        key: const ValueKey('unmount_child'),
                        onPressed: () => setState(() => mountedChild = false),
                        child: const Text('Unmount'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      expect(capturedContext, isNotNull);
      expect(capturedRef, isNotNull);

      // Unmount the child widget so its BuildContext is no longer mounted.
      await tester.tap(find.byKey(const ValueKey('unmount_child')));
      await tester.pump();
      expect(capturedContext!.mounted, isFalse);

      await removeLibraryBatchSelections(
        context: capturedContext!,
        ref: capturedRef!,
        selections: [
          LibraryBatchSelection(
            path: 'C:/Batch/A',
            firstTrack: MusicTrack(
              path: 'C:/Batch/A/01.mp3',
              displayName: '01',
              groupKey: 'C:/Batch/A',
              groupTitle: 'A',
              groupSubtitle: 'C:/Batch/A',
              isSingle: false,
            ),
            target: AudioDetailTarget.libraryRootFolder('C:/Batch/A'),
            removalTarget: LibraryRemovalTarget.folder,
          ),
          LibraryBatchSelection(
            path: 'C:/Batch/B',
            firstTrack: MusicTrack(
              path: 'C:/Batch/B/01.mp3',
              displayName: '01',
              groupKey: 'C:/Batch/B',
              groupTitle: 'B',
              groupSubtitle: 'C:/Batch/B',
              isSingle: false,
            ),
            target: AudioDetailTarget.libraryRootFolder('C:/Batch/B'),
            removalTarget: LibraryRemovalTarget.folder,
          ),
        ],
        exitSelectionMode: () {},
      );
      await tester.pump();

      expect(removalService.state.pendingCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'LibraryScanPresentationMapper uses info tone for non-error outcomes and preserves primary message with detail import failures',
    () {
      for (final code in [
        LibraryScanOutcomeCode.noAudio,
        LibraryScanOutcomeCode.folderExists,
        LibraryScanOutcomeCode.libraryExists,
        LibraryScanOutcomeCode.fileExists,
      ]) {
        final fb = LibraryScanPresentationMapper.feedback(
          LibraryScanOutcome(code: code, source: 'WorkA'),
          i18n,
        );
        expect(fb, isNotNull);
        expect(fb!.tone, AppFeedbackTone.info);
        expect(fb.icon, Icons.info_outline_rounded);
      }

      final combined = LibraryScanPresentationMapper.feedback(
        LibraryScanOutcome(
          code: LibraryScanOutcomeCode.importAdded,
          source: 'WorkA',
          details: const {'count': 4, 'detailImportFailureCount': 2},
        ),
        i18n,
      );
      expect(combined, isNotNull);
      expect(combined!.tone, AppFeedbackTone.warning);
      expect(
        combined.message,
        contains(i18n.tr('import_done_added', {'count': 4})),
      );
      expect(
        combined.message,
        contains(i18n.tr('detail_backup_import_failed', {'count': 2})),
      );
    },
  );

  testWidgets(
    'LibraryScanProgressCard disables cancel immediately and mutes zero failure count',
    (tester) async {
      var cancelCalls = 0;
      const state = LibraryScanUiState(
        isScanning: true,
        isBackgroundScanning: false,
        source: 'WorkA',
        stage: FolderScanStage.enumerating,
        processed: 2,
        total: 10,
        foundCount: 2,
        duplicateCount: 0,
        failureCount: 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [AppDesignTokens.light]),
          home: Scaffold(
            body: LibraryScanProgressCard(
              i18n: i18n,
              scanState: state,
              onCancel: () => cancelCalls++,
            ),
          ),
        ),
      );

      final failureText = tester.widget<Text>(
        find.text('${i18n.tr('scan_failure')}: 0'),
      );
      final cs = Theme.of(
        tester.element(find.byType(LibraryScanProgressCard)),
      ).colorScheme;
      expect(failureText.style?.color, cs.onSurfaceVariant);

      await tester.tap(
        find.byKey(const ValueKey('library_scan_cancel_button')),
      );
      await tester.pump();
      expect(cancelCalls, 1);

      // Second tap while cancelling must be ignored.
      await tester.tap(
        find.byKey(const ValueKey('library_scan_cancel_button')),
      );
      await tester.pump();
      expect(cancelCalls, 1);
    },
  );

  testWidgets(
    'LibraryBatchSelectionHeader exposes select-all toggle and single-item edit info action',
    (tester) async {
      var toggleSelectAllCalls = 0;
      var editInfoCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [AppDesignTokens.light]),
          home: Scaffold(
            body: LibraryBatchSelectionHeader(
              keyPrefix: 'library',
              i18n: i18n,
              selectedCount: 1,
              onToggleSelectAll: () => toggleSelectAllCalls++,
              onEditInfo: () => editInfoCalls++,
              onAddToPlaylist: () {},
              onCompleteMetadata: () {},
              onTogglePin: () {},
              onRemove: () {},
              onExit: () {},
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('library_batch_select_all_button')),
      );
      await tester.tap(
        find.byKey(const ValueKey('library_batch_edit_info_button')),
      );
      await tester.pump();

      expect(toggleSelectAllCalls, 1);
      expect(editInfoCalls, 1);
    },
  );

  testWidgets(
    'WorkImageViewerPage handles keyboard navigation, Escape pop, and local error retry view',
    (tester) async {
      var popped = false;
      const images = [
        WorkImageItem(name: 'a.jpg', path: '/nonexistent/a.jpg'),
        WorkImageItem(name: 'b.jpg', path: '/nonexistent/b.jpg'),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [AppDesignTokens.light]),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  Navigator.of(context)
                      .push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              const WorkImageViewerPage(images: images),
                        ),
                      )
                      .then((_) => popped = true);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('2 / 2'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('1 / 2'), findsOneWidget);

      // Missing local image displays error view with retry button instead of spinner.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('work_image_load_error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('image_viewer_retry_button')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(popped, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

final class _FakeCoverArtworkCacheService extends CoverArtworkCacheService {
  _FakeCoverArtworkCacheService({
    required super.libraryService,
    required this.onDiscover,
    required this.onSetManualCover,
  }) : super(
         isActiveCoverKey: (_) => false,
         onActiveCoverChanged: () {},
       );

  final Future<List<String>> Function(String folderPath) onDiscover;
  Future<String?> Function(String folderPath, String imagePath)
  onSetManualCover;

  @override
  Future<String?> futureForFolder(String folderPath) async =>
      '$folderPath/a.jpg';

  @override
  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
    bool Function()? isCancelled,
  }) => onDiscover(folderPath);

  @override
  Future<String?> setFolderCoverSelection(
    String folderPath,
    String coverPath, {
    bool newlySaved = false,
    String? sourcePath,
  }) => onSetManualCover(folderPath, coverPath);
}

final class _InMemoryLibraryRepo
    implements LibraryPersistenceRepository, AudioDetailStore {
  @override
  Future<String?> loadAppSetting(String key) async => null;

  @override
  Future<void> saveAppSetting(String key, String? value) async {}

  @override
  Future<AudioDetail?> load(AudioDetailTarget target) async => null;

  @override
  Future<void> delete(AudioDetailTarget target) async {}

  @override
  Future<List<AudioDetail>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
