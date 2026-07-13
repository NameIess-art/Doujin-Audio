import '../../features/player/application/audio_state_services.dart';
import '../../features/library/application/library_catalog.dart';
import '../../features/library/application/library_scan_models.dart';
import 'audio_provider.dart';

class AudioProviderLibraryCatalog implements LibraryCatalog {
  const AudioProviderLibraryCatalog(this._provider);

  final AudioProvider _provider;

  @override
  List<MusicTrack> get library => _provider.library;
  @override
  List<String> get watchedFolders => _provider.watchedFolders;
  @override
  List<String> get watchedLibraries => _provider.watchedLibraries;
  @override
  bool get isScanning => _provider.isScanning;
  @override
  int get scanFoundCount => _provider.scanFoundCount;
  @override
  int get scanDuplicateCount => _provider.scanDuplicateCount;
  @override
  int get scanFailureCount => _provider.scanFailureCount;

  @override
  MusicTrack? trackByPath(String trackPath) => _provider.trackByPath(trackPath);
  @override
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      _provider.libraryEntriesForLibrary(libraryPath);
  @override
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) =>
      _provider.libraryEntrySnapshotForLibrary(libraryPath);
  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) => _provider.libraryExclusionMatcherForLibrary(libraryPath);
  @override
  bool hasLibraryExclusions(String libraryPath) =>
      _provider.hasLibraryExclusions(libraryPath);
  @override
  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      _provider.isLibraryPathExcluded(libraryPath, entityPath);
  @override
  bool isScanGenerationActive(int generation) =>
      _provider.isScanGenerationActive(generation);

  @override
  int tryBeginScan({required String source, bool background = false}) =>
      _provider.tryBeginScan(source: source, background: background);
  @override
  void cancelScan() => _provider.cancelScan();
  @override
  void finishScan(int generation) => _provider.finishScan(generation);
  @override
  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
    int? generation,
    FolderScanStage? stage,
    int? processed,
    int? total,
  }) => _provider.setScanProgress(
    currentFolder: currentFolder,
    foundCount: foundCount,
    duplicateCount: duplicateCount,
    failureCount: failureCount,
    generation: generation,
    stage: stage,
    processed: processed,
    total: total,
  );
  @override
  void beginLibraryBatch() => _provider.beginLibraryBatch();
  @override
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) => _provider.endLibraryBatch(
    notify: notify,
    waitForPersistence: waitForPersistence,
  );
  @override
  void beginStagedLibraryRefresh() => _provider.beginStagedLibraryRefresh();
  @override
  Future<void> finishStagedLibraryRefresh({bool waitForPersistence = false}) =>
      _provider.finishStagedLibraryRefresh(
        waitForPersistence: waitForPersistence,
      );
  @override
  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) => _provider.applyStagedLibraryRefreshChunk(
    sourceFolderPath: sourceFolderPath,
    libraryRoot: libraryRoot,
    tracks: tracks,
    folderPaths: folderPaths,
    removeWatchedFolders: removeWatchedFolders,
    addWatchedFolders: addWatchedFolders,
    removeTrackPaths: removeTrackPaths,
    removeEntryPaths: removeEntryPaths,
    persist: persist,
  );
  @override
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) => _provider.addTracks(tracks, notify: notify, persist: persist);
  @override
  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) => _provider.addOrReplaceTracks(tracks, notify: notify, persist: persist);
  @override
  void removeTracksByPath(Iterable<String> trackPaths) =>
      _provider.removeTracksByPath(trackPaths);
  @override
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) => _provider.removeTracksDeletedFromFolder(folderPath, scannedPaths);
  @override
  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) => _provider.removeLibraryEntriesByPaths(libraryPath, entryPaths);
  @override
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) => _provider.removeLibraryEntriesDeletedFromFolder(
    libraryPath,
    folderPath,
    retainedPaths,
  );
  @override
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) => _provider.recordLibraryEntriesForTracks(
    libraryPath,
    tracks,
    folderPaths: folderPaths,
    persist: persist,
    exclusionMatcher: exclusionMatcher,
    entrySnapshot: entrySnapshot,
  );
  @override
  void addWatchedFolder(String folderPath, {bool notify = true}) =>
      _provider.addWatchedFolder(folderPath, notify: notify);
  @override
  void addWatchedLibrary(String folderPath, {bool notify = true}) =>
      _provider.addWatchedLibrary(folderPath, notify: notify);
  @override
  void removeWatchedFolder(String folderPath, {bool notify = true}) =>
      _provider.removeWatchedFolder(folderPath, notify: notify);
  @override
  void clearLibraryExclusions(String libraryPath) =>
      _provider.clearLibraryExclusions(libraryPath);
  @override
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  ) async {
    await _provider.prefillAudioDetailRjCodeFromText(
      AudioDetailTarget.libraryRootFolder(folderPath),
      displayName,
    );
  }
}
