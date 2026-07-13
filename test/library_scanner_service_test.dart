import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/library/application/library_catalog.dart';
import 'package:nameless_audio/features/library/application/library_scan_data_source.dart';
import 'package:nameless_audio/features/library/application/library_scanner_service.dart';

void main() {
  const labels = LibraryScanLabels(
    chooseMusicFolder: 'Choose folder',
    chooseLibraryFolder: 'Choose library',
    chooseAudioFiles: 'Choose files',
    importedFiles: 'Imported files',
    manuallySelectedFiles: 'Selected files',
  );

  test(
    'file import always finishes scan when batch finalization fails',
    () async {
      final catalog = _FailingBatchCatalog();
      final scanner = LibraryScannerService(
        dataSource: _PickedFilesDataSource(),
      );

      await expectLater(
        scanner.addFiles(provider: catalog, labels: labels),
        throwsA(isA<StateError>()),
      );

      expect(catalog.isScanning, isFalse);
      expect(catalog.finishCount, 1);
    },
  );
}

class _PickedFilesDataSource implements LibraryScanDataSource {
  @override
  Future<List<PickedAudioFile>?> pickAudioFiles({required String dialogTitle}) {
    return Future<List<PickedAudioFile>?>.value(const <PickedAudioFile>[
      PickedAudioFile(uri: 'content://audio/track.mp3', name: 'track.mp3'),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingBatchCatalog implements LibraryCatalog {
  @override
  final List<MusicTrack> library = <MusicTrack>[];

  @override
  final List<String> watchedFolders = <String>[];

  @override
  final List<String> watchedLibraries = <String>[];

  @override
  bool isScanning = false;

  int finishCount = 0;
  int _generation = 0;

  @override
  int tryBeginScan({required String source, bool background = false}) {
    isScanning = true;
    return _generation = 1;
  }

  @override
  bool isScanGenerationActive(int generation) {
    return isScanning && generation == _generation;
  }

  @override
  void beginLibraryBatch() {}

  @override
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    library.addAll(tracks);
  }

  @override
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) {
    return Future<void>.error(StateError('persistence failed'));
  }

  @override
  void finishScan(int generation) {
    if (generation != _generation) return;
    finishCount++;
    isScanning = false;
    _generation = 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
