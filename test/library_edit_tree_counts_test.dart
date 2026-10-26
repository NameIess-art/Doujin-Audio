import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/features/library/application/library_entry_editor_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_state_models.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_projection.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_tiles.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'support/app_runtime_test_fixture.dart';

class _CountingLibraryService extends LibraryService {
  int trackExclusionReads = 0;
  int exclusionSnapshots = 0;

  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) {
    exclusionSnapshots++;
    return super.libraryExclusionMatcherForLibrary(libraryPath);
  }

  @override
  bool isLibraryPathExcluded(String libraryPath, String entityPath) {
    if (entityPath.endsWith('.mp3')) trackExclusionReads++;
    return super.isLibraryPathExcluded(libraryPath, entityPath);
  }
}

class _LoadedSnapshotEditorService extends LibraryEntryEditorService {
  _LoadedSnapshotEditorService(this.snapshot);

  LibraryEntryDiskSnapshot snapshot;

  @override
  Future<LibraryEntryDiskSnapshot> loadDiskSnapshot(String libraryPath) async =>
      snapshot;
}

void main() {
  AppRuntimeTestFixture.initialize();

  testWidgets(
    'failed current projection exposes retry without an automatic loop',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const root = '/library';
      final service = _LoadedSnapshotEditorService(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const ['$root/Work/01.mp3'],
          scannedFolderPaths: const {'$root/Work'},
          authoritative: true,
        ),
      );
      final requests = <LibraryEditTreeRequest>[];
      final results = <Completer<LibraryEditTreeSnapshot>>[];
      await tester.pumpWidget(
        fixture.build(
          Scaffold(
            body: LibraryEditTree(
              libraryPath: root,
              headerBuilder: (_, search) => search,
              entryEditorService: service,
              projectTree: (request) {
                requests.add(request);
                final result = Completer<LibraryEditTreeSnapshot>();
                results.add(result);
                return result.future;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      results.single.completeError(StateError('projection failed'));
      await tester.pumpAndSettle();
      final retry = find.widgetWithText(
        FilledButton,
        fixture.languageProvider.tr('retry'),
      );
      expect(retry, findsOneWidget);
      expect(requests, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      expect(requests, hasLength(1));
      await tester.tap(retry);
      await tester.pump();
      await tester.pump();
      expect(requests, hasLength(2));
      results.last.complete(await requests.last.project());
      await tester.pumpAndSettle();
      expect(find.text('Work', findRichText: true), findsOneWidget);
      expect(retry, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final staleFailure in [false, true]) {
    testWidgets(
      'editor discards a projection after a disk refresh (error=$staleFailure)',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        const root = '/library';
        final service = _LoadedSnapshotEditorService(
          LibraryEntryDiskSnapshot(
            audioFilePaths: const ['$root/Old/01.mp3'],
            scannedFolderPaths: const {'$root/Old'},
            authoritative: true,
          ),
        );
        final requests = <LibraryEditTreeRequest>[];
        final results = <Completer<LibraryEditTreeSnapshot>>[];
        await tester.pumpWidget(
          fixture.build(
            Scaffold(
              body: LibraryEditTree(
                libraryPath: root,
                headerBuilder: (_, search) => search,
                entryEditorService: service,
                projectTree: (request) {
                  requests.add(request);
                  final result = Completer<LibraryEditTreeSnapshot>();
                  results.add(result);
                  return result.future;
                },
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(requests, hasLength(1));
        expect(
          find.byKey(const ValueKey('library_edit_entries_skeleton')),
          findsOneWidget,
        );
        service.snapshot = LibraryEntryDiskSnapshot(
          audioFilePaths: const ['$root/New/02.mp3'],
          scannedFolderPaths: const {'$root/New'},
          authoritative: true,
        );
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();
        if (staleFailure) {
          results.first.completeError(StateError('stale projection'));
        } else {
          results.first.complete(await requests.first.project());
        }
        await tester.pump();
        expect(find.text('Old', findRichText: true), findsNothing);
        expect(requests, hasLength(2));
        expect(requests.last.diskTrackPaths, ['$root/New/02.mp3']);
        expect(
          find.byKey(const ValueKey('library_edit_entries_skeleton')),
          findsOneWidget,
        );
        results.last.complete(await requests.last.project());
        await tester.pumpAndSettle();
        expect(find.text('Old', findRichText: true), findsNothing);
        expect(find.text('New', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'editor removes active empty work roots left after media deletion',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final library = fixture.runtimeGraph.library;
      const root = '/library';
      const deleted = '$root/Deleted';
      const kept = '$root/Kept';
      const excluded = '$root/Excluded';
      library.addWatchedLibrary(root, notify: false);
      for (final folder in [deleted, kept, excluded]) {
        library.addWatchedFolder(folder, notify: false);
      }
      library.recordLibraryEntriesForTracks(
        root,
        [],
        folderPaths: [deleted, '$deleted/Disc', kept, excluded],
        persist: false,
      );
      library.setLibraryFolderExcluded(root, excluded, true);
      final service = _LoadedSnapshotEditorService(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const ['$kept/01.mp3'],
          scannedFolderPaths: const {deleted, '$deleted/Disc', kept, excluded},
          authoritative: true,
        ),
      );
      await tester.pumpWidget(
        fixture.build(
          Scaffold(
            body: LibraryEditTree(
              libraryPath: root,
              headerBuilder: (_, search) => search,
              entryEditorService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Deleted', findRichText: true), findsNothing);
      expect(find.text('Kept', findRichText: true), findsOneWidget);
      expect(find.text('Excluded', findRichText: true), findsOneWidget);
      expect(library.childFoldersForLibrary(root), isNot(contains(deleted)));
      expect(
        library
            .libraryEntriesForLibrary(root)
            .any((entry) => PathMatcher.isWithinOrEqual(entry.path, deleted)),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reopening editor prunes a work directory deleted from disk', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final library = fixture.runtimeGraph.library;
    late Directory root;
    late Directory deleted;
    late Directory kept;
    final snapshot = await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('edit_deleted_work_');
      deleted = await Directory(path.join(root.path, 'Deleted')).create();
      kept = await Directory(path.join(root.path, 'Kept')).create();
      await File(path.join(kept.path, '01.mp3')).writeAsBytes([1]);
      library.addWatchedLibrary(root.path, notify: false);
      library.addWatchedFolder(deleted.path, notify: false);
      library.addWatchedFolder(kept.path, notify: false);
      library.recordLibraryEntriesForTracks(
        root.path,
        [],
        folderPaths: [deleted.path, kept.path],
        persist: false,
      );
      await deleted.delete();
      return LibraryEntryEditorService(
        isAndroid: () => false,
      ).loadDiskSnapshot(root.path);
    });
    addTearDown(() => root.delete(recursive: true));
    await tester.pumpWidget(
      fixture.build(
        Scaffold(
          body: LibraryEditTree(
            libraryPath: root.path,
            headerBuilder: (_, search) => search,
            entryEditorService: _LoadedSnapshotEditorService(snapshot!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Deleted', findRichText: true), findsNothing);
    expect(find.text('Kept', findRichText: true), findsOneWidget);
    expect(
      library
          .libraryEntriesForLibrary(root.path)
          .any(
            (entry) => PathMatcher.equalsNormalized(entry.path, deleted.path),
          ),
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'open editor refreshes deleted work after a library scan releases its lease',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final library = fixture.runtimeGraph.library;
      const root = '/library';
      const deleted = '$root/Deleted';
      library.addWatchedLibrary(root, notify: false);
      library.addWatchedFolder(deleted, notify: false);
      library.recordLibraryEntriesForTracks(
        root,
        [],
        folderPaths: [deleted],
        persist: false,
      );
      final service = _LoadedSnapshotEditorService(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const ['$deleted/01.mp3'],
          scannedFolderPaths: const {deleted},
          authoritative: true,
        ),
      );
      await tester.pumpWidget(
        fixture.build(
          Scaffold(
            body: LibraryEditTree(
              libraryPath: root,
              headerBuilder: (_, search) => search,
              entryEditorService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Deleted', findRichText: true), findsOneWidget);
      final generation = library.tryBeginScan(source: root);
      await tester.pumpAndSettle();
      service.snapshot = LibraryEntryDiskSnapshot(
        audioFilePaths: const [],
        scannedFolderPaths: const {},
        authoritative: true,
      );
      library.cancelScan();
      await tester.pumpAndSettle();
      expect(find.text('Deleted', findRichText: true), findsOneWidget);
      library.finishScan(generation);
      await tester.pumpAndSettle();
      expect(find.text('Deleted', findRichText: true), findsNothing);
      expect(library.libraryEntriesForLibrary(root), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'editor removes deleted folders retained in exclusion snapshots',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final library = fixture.runtimeGraph.library;
      const root = '/library';
      const work = '$root/Work';
      const deleted = '$work/Deleted';
      library.addWatchedLibrary(root, notify: false);
      library.addWatchedFolder(work, notify: false);
      library.recordLibraryEntriesForTracks(
        root,
        [],
        folderPaths: [work, deleted],
        persist: false,
      );
      final service = _LoadedSnapshotEditorService(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const ['$deleted/01.mp3'],
          scannedFolderPaths: const {work, deleted},
          authoritative: true,
        ),
      );
      await tester.pumpWidget(
        fixture.build(
          Scaffold(
            body: LibraryEditTree(
              libraryPath: root,
              headerBuilder: (_, search) => search,
              entryEditorService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .widgetWithText(TextButton, fixture.languageProvider.tr('exclude'))
            .first,
      );
      await tester.pumpAndSettle();
      service.snapshot = LibraryEntryDiskSnapshot(
        audioFilePaths: const [],
        scannedFolderPaths: const {work},
        authoritative: true,
      );
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('Deleted', findRichText: true), findsNothing);
      expect(find.text('01', findRichText: true), findsNothing);
      expect(find.text('Work', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('opening editor preserves excluded empty folders', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final library = LibraryFacade.create(
      databaseRepository: fixture.persistenceRepository,
    )..configurePersistence(enabled: false);
    addTearDown(library.dispose);
    late Directory root;
    late Directory empty;
    final snapshot = await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('library_edit_empty_');
      empty = await Directory(path.join(root.path, 'Excluded')).create();
      return LibraryEntryEditorService(
        isAndroid: () => false,
      ).loadDiskSnapshot(root.path);
    });
    addTearDown(() => root.delete(recursive: true));
    library.setLibraryFolderExcluded(root.path, empty.path, true);

    await tester.pumpWidget(
      fixture.build(
        Scaffold(
          body: LibraryEditTree(
            libraryPath: root.path,
            headerBuilder: (_, search) => search,
            entryEditorService: _LoadedSnapshotEditorService(snapshot!),
          ),
        ),
        overrides: [libraryFacadeProvider.overrideWithValue(library)],
      ),
    );
    await tester.pumpAndSettle();

    expect(library.excludedFoldersForLibrary(root.path), [
      PathMatcher.normalize(empty.path),
    ]);
    expect(find.text('Excluded'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'folder counts survive row rebuilds and refresh on input changes',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final service = _CountingLibraryService();
      final library = LibraryFacade.create(
        databaseRepository: fixture.persistenceRepository,
        service: service,
      )..configurePersistence(enabled: false);
      addTearDown(library.dispose);
      const projection = LibraryEditTreeProjection('/library');
      var nodes = projection.buildEditTree(
        ['/library/Work/Disc/01.mp3', '/library/Work/Disc/02.mp3'],
        [],
        [],
      );
      late StateSetter update;
      await tester.pumpWidget(
        fixture.build(
          Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LibraryEditTreeList(
                  libraryPath: '/library',
                  nodes: nodes,
                  initiallyExpanded: false,
                  onRememberFolder: (_, _) {},
                );
              },
            ),
          ),
          overrides: [libraryFacadeProvider.overrideWithValue(library)],
        ),
      );
      await tester.pumpAndSettle();
      expect(service.trackExclusionReads, 0);
      expect(service.exclusionSnapshots, 1);
      expect(
        tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
        fixture.languageProvider.tr('audio_count', {'count': 2}),
      );

      service.trackExclusionReads = 0;
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(find.text('Disc'), findsOneWidget);
      expect(service.trackExclusionReads, 0);
      expect(service.exclusionSnapshots, 1);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      update(() {});
      await tester.pumpAndSettle();
      expect(service.trackExclusionReads, 0);
      expect(service.exclusionSnapshots, 1);

      library.setLibraryTrackExcluded(
        '/library',
        '/library/Work/Disc/01.mp3',
        true,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
        fixture.languageProvider.tr('audio_count', {'count': 1}),
      );
      library.setLibraryFolderExcluded('/library', '/library/Work/Disc', true);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
        fixture.languageProvider.tr('audio_count', {'count': 0}),
      );
      library.setLibraryFolderExcluded('/library', '/library/Work/Disc', false);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
        fixture.languageProvider.tr('audio_count', {'count': 2}),
      );

      update(() {
        nodes = projection.filterEditTree(
          nodes,
          '02',
          (track, query) => track.contains(query),
        );
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
        fixture.languageProvider.tr('audio_count', {'count': 1}),
      );
      update(() {
        nodes = projection.buildEditTree(
          [
            '/library/Work/Disc/01.mp3',
            '/library/Work/Disc/02.mp3',
            '/library/Work/Disc/03.mp3',
          ],
          [],
          [],
        );
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
        fixture.languageProvider.tr('audio_count', {'count': 3}),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
