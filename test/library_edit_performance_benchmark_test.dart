import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:nameless_audio/features/library/application/library_entry_editor_service.dart';
import 'package:nameless_audio/features/library/presentation/library_tab.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

final class _FixedSnapshotService extends LibraryEntryEditorService {
  _FixedSnapshotService(this.snapshot);

  final LibraryEntryDiskSnapshot snapshot;

  @override
  Future<LibraryEntryDiskSnapshot> loadDiskSnapshot(String libraryPath) async {
    return snapshot;
  }
}

Duration _p95(List<Duration> samples) {
  final sorted = [...samples]..sort((a, b) => a.compareTo(b));
  return sorted[(sorted.length * 95 / 100).ceil() - 1];
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;

  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));

  testWidgets('library edit 10k-item profile benchmark', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const libraryPath = '/benchmark-library';
    final tracks = List<MusicTrack>.generate(
      10000,
      (index) => testMusicTrack(
        name: 'Track $index',
        path: '$libraryPath/Disc${index % 20}/track-$index.mp3',
        groupKey: '$libraryPath/Disc${index % 20}',
        groupTitle: 'Disc ${index % 20}',
      ),
    );
    fixture.runtimeGraph.library.addWatchedFolder(libraryPath, notify: false);
    fixture.runtimeGraph.library.addTracks(
      tracks,
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    final service = _FixedSnapshotService(
      LibraryEntryDiskSnapshot(
        audioFilePaths: tracks
            .map((track) => track.path)
            .toList(growable: false),
        scannedFolderPaths: const <String>{},
        authoritative: true,
      ),
    );
    await tester.pumpWidget(
      fixture.build(
        LibraryEditPage(libraryPath: libraryPath, entryEditorService: service),
      ),
    );
    await tester.pump();

    final rebuildSamples = <Duration>[];
    for (var index = 0; index < 20; index++) {
      final stopwatch = Stopwatch()..start();
      await tester.pump();
      stopwatch.stop();
      rebuildSamples.add(stopwatch.elapsed);
    }

    final searchSamples = <Duration>[];
    final searchField = find.byType(TextField);
    for (var index = 0; index < 10; index++) {
      await tester.enterText(searchField, 'track ${index + 1}');
      final stopwatch = Stopwatch()..start();
      await tester.pump();
      stopwatch.stop();
      searchSamples.add(stopwatch.elapsed);
      await tester.pump(const Duration(milliseconds: 250));
    }

    final interaction = Object();
    final interactionCoordinator = UiInteractionCoordinator.instance;
    interactionCoordinator.beginInteraction(interaction);
    final interactionStopwatch = Stopwatch()..start();
    await tester.pump();
    interactionStopwatch.stop();
    interactionCoordinator.endInteraction(interaction);
    await tester.pump(const Duration(milliseconds: 200));

    // Acceptance thresholds: p95 build <= 16 ms, p95 search input <= 100 ms.
    // Keep this benchmark observational so coverage instrumentation does not
    // turn its slower timings into a product-test failure.
    final p95Build = _p95(rebuildSamples);
    final p95Search = _p95(searchSamples);
    final longSearchFrames = searchSamples
        .where((value) => value > const Duration(milliseconds: 100))
        .length;
    debugPrint(
      'library_edit_benchmark '
      'p95Build=${p95Build.inMicroseconds / 1000}ms '
      'p95Search=${p95Search.inMicroseconds / 1000}ms '
      'interaction=${interactionStopwatch.elapsedMicroseconds / 1000}ms '
      'searchSamples=${searchSamples.map((value) => value.inMicroseconds / 1000).toList()} '
      'searchLongFrames=$longSearchFrames',
    );
  });
}
