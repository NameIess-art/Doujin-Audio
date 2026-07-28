import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import 'library_entry.dart';

final class AudioDetailBackupSyncTask {
  const AudioDetailBackupSyncTask({
    required this.target,
    required this.generation,
    required this.attemptCount,
    required this.nextAttemptAtMs,
    this.lastError,
  });

  final AudioDetailTarget target;
  final int generation;
  final int attemptCount;
  final int nextAttemptAtMs;
  final String? lastError;
}

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

  Future<AudioDetail?> loadAudioDetail(AudioDetailTarget target);
  Future<List<AudioDetail>> loadAudioDetails(
    Iterable<AudioDetailTarget> targets,
  );
  Future<void> upsertAudioDetail(AudioDetail detail);
  Future<AudioDetailBackupSyncTask> upsertAudioDetailAndEnqueueBackupSync(
    AudioDetail detail,
  );
  Future<AudioDetailBackupSyncTask> enqueueAudioDetailBackupSync(
    AudioDetailTarget target,
  );
  Future<List<AudioDetailBackupSyncTask>> loadDueAudioDetailBackupSyncTasks({
    required int nowMs,
    int limit = 100,
  });
  Future<int?> loadNextAudioDetailBackupSyncAtMs();
  Future<bool> deleteAudioDetailBackupSyncTask(
    AudioDetailTarget target, {
    required int generation,
  });
  Future<bool> recordAudioDetailBackupSyncFailure(
    AudioDetailBackupSyncTask task, {
    required int nextAttemptAtMs,
    required String error,
  });
  Future<void> upsertAudioDetails(Iterable<AudioDetail> details);
  Future<void> deleteAudioDetail(AudioDetailTarget target);
  Future<void> deleteAudioDetails(Iterable<AudioDetailTarget> targets);

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
