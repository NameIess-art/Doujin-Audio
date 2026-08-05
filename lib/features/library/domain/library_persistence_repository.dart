import '../../../core/media/music_track.dart';
import 'library_entry.dart';

abstract interface class LibraryPersistenceRepository {
  Future<List<MusicTrack>> loadAllTracks();
  Future<List<MusicTrack>> loadTrackSummaries();
  Future<List<MusicTrack>> loadStartupTracks();
  Future<MusicTrack?> loadTrackDetail(String path);
  Future<void> saveAllTracks(List<MusicTrack> tracks);
  Future<void> upsertTracks(List<MusicTrack> tracks);
  Future<void> replaceTrackPaths(Map<String, MusicTrack> replacements);
  Future<void> insertTracks(List<MusicTrack> tracks);
  Future<void> deleteTracks(List<String> paths);
  Future<int> nextScanGeneration();
  Future<void> markTracksScanned(
    List<MusicTrack> tracks, {
    required int generation,
  });
  Future<void> deleteTracksMissingFromGeneration(int generation);

  Future<String?> loadAppSetting(String key);
  Future<void> saveAppSetting(String key, String? value);
  Future<List<LibraryEntry>> loadAllLibraryEntries();
  Future<List<LibraryEntry>> loadLibraryEntries(String libraryPath);
  Future<void> upsertLibraryEntries(
    List<LibraryEntry> entries, {
    int? scanGeneration,
  });
  Future<int> nextLibraryEntryScanGeneration(String libraryPath);
  Future<void> deleteLibraryEntriesForLibrary(String libraryPath);
  Future<void> deleteLibraryEntries(String libraryPath, Iterable<String> paths);
  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    LibraryEntryState state,
  );

  Future<void> retargetTimeSegmentLabels({
    required String oldTrackKey,
    required String newTrackKey,
  });
  Future<void> retargetTimeSegmentLabelsWithinPath({
    required String oldRoot,
    required String newRoot,
  });
}
