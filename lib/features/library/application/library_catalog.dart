import '../domain/library_entry.dart';
import '../../../core/media/music_track.dart';
import '../../player/application/audio_state_services.dart';
import 'library_scan_models.dart';

abstract interface class LibraryCatalogReader {
  List<MusicTrack> get library;
  List<String> get watchedFolders;
  List<String> get watchedLibraries;
  bool get isScanning;
  int get scanFoundCount;
  int get scanDuplicateCount;
  int get scanFailureCount;

  MusicTrack? trackByPath(String trackPath);
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath);
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath);
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(String libraryPath);
  bool hasLibraryExclusions(String libraryPath);
  bool isLibraryPathExcluded(String libraryPath, String entityPath);
  bool isScanGenerationActive(int generation);
}

abstract interface class LibraryCatalogWriter {
  int tryBeginScan({required String source, bool background = false});
  void cancelScan();
  void finishScan(int generation);
  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
    int? generation,
    FolderScanStage? stage,
    int? processed,
    int? total,
  });
  void beginLibraryBatch();
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  });
  void beginStagedLibraryRefresh();
  Future<void> finishStagedLibraryRefresh({bool waitForPersistence = false});
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
  });
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  });
  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  });
  void removeTracksByPath(Iterable<String> trackPaths);
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  );
  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  );
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  );
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  });
  void addWatchedFolder(String folderPath, {bool notify = true});
  void addWatchedLibrary(String folderPath, {bool notify = true});
  void removeWatchedFolder(String folderPath, {bool notify = true});
  void clearLibraryExclusions(String libraryPath);
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  );
}

abstract interface class LibraryCatalog
    implements LibraryCatalogReader, LibraryCatalogWriter {}
