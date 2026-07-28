import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/persistence/app_database.dart';
import '../../core/persistence/persistence_records.dart';
import '../../features/library/domain/library_entry.dart';
import '../../features/library/domain/library_persistence_repository.dart';

class SqliteLibraryRepository implements LibraryPersistenceRepository {
  SqliteLibraryRepository({required AppDatabase database})
    : _database = database;

  final AppDatabase _database;

  @override
  Future<List<MusicTrack>> loadAllTracks() => _database.loadAllTracks();
  @override
  Future<List<MusicTrack>> loadTrackSummaries() =>
      _database.loadTrackSummaries();
  @override
  Future<List<MusicTrack>> loadStartupTracks() => _database.loadStartupTracks();
  @override
  Future<MusicTrack?> loadTrackDetail(String path) =>
      _database.loadTrackDetail(path);
  @override
  Future<void> saveAllTracks(List<MusicTrack> tracks) =>
      _database.saveAllTracks(tracks);
  @override
  Future<void> upsertTracks(List<MusicTrack> tracks) =>
      _database.upsertTracks(tracks);
  @override
  Future<void> replaceTrackPaths(Map<String, MusicTrack> replacements) =>
      _database.replaceTrackPaths(replacements);
  @override
  Future<void> insertTracks(List<MusicTrack> tracks) =>
      _database.insertTracks(tracks);
  @override
  Future<void> deleteTracks(List<String> paths) =>
      _database.deleteTracks(paths);
  @override
  Future<int> nextScanGeneration() => _database.nextScanGeneration();
  @override
  Future<void> markTracksScanned(
    List<MusicTrack> tracks, {
    required int generation,
  }) => _database.markTracksScanned(tracks, generation: generation);
  @override
  Future<void> deleteTracksMissingFromGeneration(int generation) =>
      _database.deleteTracksMissingFromGeneration(generation);

  @override
  Future<AudioDetail?> loadAudioDetail(AudioDetailTarget target) =>
      _database.loadAudioDetail(target);
  @override
  Future<List<AudioDetail>> loadAudioDetails(
    Iterable<AudioDetailTarget> targets,
  ) => _database.loadAudioDetails(targets);
  @override
  Future<void> upsertAudioDetail(AudioDetail detail) =>
      _database.upsertAudioDetail(detail);
  @override
  Future<AudioDetailBackupSyncTask> upsertAudioDetailAndEnqueueBackupSync(
    AudioDetail detail,
  ) async => _backupTaskFromRecord(
    await _database.upsertAudioDetailAndEnqueueBackupSync(detail),
  );
  @override
  Future<AudioDetailBackupSyncTask> enqueueAudioDetailBackupSync(
    AudioDetailTarget target,
  ) async => _backupTaskFromRecord(
    await _database.enqueueAudioDetailBackupSync(target),
  );
  @override
  Future<List<AudioDetailBackupSyncTask>> loadDueAudioDetailBackupSyncTasks({
    required int nowMs,
    int limit = 100,
  }) async => (await _database.loadDueAudioDetailBackupSyncTasks(
    nowMs: nowMs,
    limit: limit,
  )).map(_backupTaskFromRecord).toList(growable: false);
  @override
  Future<int?> loadNextAudioDetailBackupSyncAtMs() =>
      _database.loadNextAudioDetailBackupSyncAtMs();
  @override
  Future<bool> deleteAudioDetailBackupSyncTask(
    AudioDetailTarget target, {
    required int generation,
  }) =>
      _database.deleteAudioDetailBackupSyncTask(target, generation: generation);
  @override
  Future<bool> recordAudioDetailBackupSyncFailure(
    AudioDetailBackupSyncTask task, {
    required int nextAttemptAtMs,
    required String error,
  }) => _database.recordAudioDetailBackupSyncFailure(
    _backupTaskToRecord(task),
    nextAttemptAtMs: nextAttemptAtMs,
    error: error,
  );
  @override
  Future<void> upsertAudioDetails(Iterable<AudioDetail> details) =>
      _database.upsertAudioDetails(details);
  @override
  Future<void> deleteAudioDetail(AudioDetailTarget target) =>
      _database.deleteAudioDetail(target);
  @override
  Future<void> deleteAudioDetails(Iterable<AudioDetailTarget> targets) =>
      _database.deleteAudioDetails(targets);
  @override
  Future<String?> loadAppSetting(String key) => _database.loadAppSetting(key);
  @override
  Future<void> saveAppSetting(String key, String? value) =>
      _database.saveAppSetting(key, value);

  @override
  Future<List<LibraryEntry>> loadAllLibraryEntries() async =>
      (await _database.loadAllLibraryEntries())
          .map(_entryFromRecord)
          .toList(growable: false);
  @override
  Future<List<LibraryEntry>> loadLibraryEntries(String libraryPath) async =>
      (await _database.loadLibraryEntries(
        libraryPath,
      )).map(_entryFromRecord).toList(growable: false);
  @override
  Future<void> upsertLibraryEntries(
    List<LibraryEntry> entries, {
    int? scanGeneration,
  }) => _database.upsertLibraryEntries(
    entries.map(_entryToRecord).toList(growable: false),
    scanGeneration: scanGeneration,
  );
  @override
  Future<int> nextLibraryEntryScanGeneration(String libraryPath) =>
      _database.nextLibraryEntryScanGeneration(libraryPath);
  @override
  Future<void> deleteLibraryEntriesForLibrary(String libraryPath) =>
      _database.deleteLibraryEntriesForLibrary(libraryPath);
  @override
  Future<void> deleteLibraryEntries(
    String libraryPath,
    Iterable<String> paths,
  ) => _database.deleteLibraryEntries(libraryPath, paths);
  @override
  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    LibraryEntryState state,
  ) => _database.setLibraryEntriesState(libraryPath, entryPaths, state.dbValue);
  @override
  Future<void> retargetTimeSegmentLabels({
    required String oldTrackKey,
    required String newTrackKey,
  }) => _database.retargetTimeSegmentLabels(
    oldTrackKey: oldTrackKey,
    newTrackKey: newTrackKey,
  );
  @override
  Future<void> retargetTimeSegmentLabelsWithinPath({
    required String oldRoot,
    required String newRoot,
  }) => _database.retargetTimeSegmentLabelsWithinPath(
    oldRoot: oldRoot,
    newRoot: newRoot,
  );
}

LibraryEntryRecord _entryToRecord(LibraryEntry entry) => LibraryEntryRecord(
  libraryPath: entry.libraryPath,
  path: entry.path,
  kind: entry.kind.dbValue,
  state: entry.state.dbValue,
  parentPath: entry.parentPath,
  displayName: entry.displayName,
  groupKey: entry.groupKey,
  groupTitle: entry.groupTitle,
  groupSubtitle: entry.groupSubtitle,
  isSingle: entry.isSingle,
  isVideo: entry.isVideo,
  scannedAt: entry.scannedAt,
  fileSizeBytes: entry.fileSizeBytes,
  modifiedAt: entry.modifiedAt,
);

LibraryEntry _entryFromRecord(LibraryEntryRecord record) => LibraryEntry(
  libraryPath: record.libraryPath,
  path: record.path,
  kind: LibraryEntryKind.fromDbValue(record.kind),
  state: LibraryEntryState.fromDbValue(record.state),
  parentPath: record.parentPath,
  displayName: record.displayName,
  groupKey: record.groupKey,
  groupTitle: record.groupTitle,
  groupSubtitle: record.groupSubtitle,
  isSingle: record.isSingle,
  isVideo: record.isVideo,
  scannedAt: record.scannedAt,
  fileSizeBytes: record.fileSizeBytes,
  modifiedAt: record.modifiedAt,
);

AudioDetailBackupSyncTask _backupTaskFromRecord(
  AudioDetailBackupSyncRecord record,
) => AudioDetailBackupSyncTask(
  target: AudioDetailTarget(
    targetType: AudioDetailTargetType.fromDbValue(record.targetType)!,
    targetPath: record.targetPath,
  ),
  generation: record.generation,
  attemptCount: record.attemptCount,
  nextAttemptAtMs: record.nextAttemptAtMs,
  lastError: record.lastError,
);

AudioDetailBackupSyncRecord _backupTaskToRecord(
  AudioDetailBackupSyncTask task,
) => AudioDetailBackupSyncRecord(
  targetType: task.target.targetType.dbValue,
  targetPath: task.target.targetPath,
  generation: task.generation,
  attemptCount: task.attemptCount,
  nextAttemptAtMs: task.nextAttemptAtMs,
  lastError: task.lastError,
);
