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

  final LibraryEntryDiskSnapshot snapshot;

  @override
  Future<LibraryEntryDiskSnapshot> loadDiskSnapshot(String libraryPath) async =>
      snapshot;
}

void main() {
  AppRuntimeTestFixture.initialize();

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
