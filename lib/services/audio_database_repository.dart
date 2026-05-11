import 'package:sqflite/sqflite.dart';

import '../models/audio_detail.dart';
import '../models/music_track.dart';
import 'app_database.dart';

class AudioDatabaseRepository {
  AudioDatabaseRepository({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  Future<Database> get database => _database.database;

  Future<List<MusicTrack>> loadAllTracks() => _database.loadAllTracks();

  Future<void> saveAllTracks(List<MusicTrack> tracks) {
    return _database.saveAllTracks(tracks);
  }

  Future<void> upsertTracks(List<MusicTrack> tracks) {
    return _database.upsertTracks(tracks);
  }

  Future<void> insertTracks(List<MusicTrack> tracks) {
    return _database.insertTracks(tracks);
  }

  Future<void> deleteTracks(List<String> paths) =>
      _database.deleteTracks(paths);

  Future<int> nextScanGeneration() => _database.nextScanGeneration();

  Future<void> markTracksScanned(
    List<MusicTrack> tracks, {
    required int generation,
  }) {
    return _database.markTracksScanned(tracks, generation: generation);
  }

  Future<void> deleteTracksMissingFromGeneration(int generation) {
    return _database.deleteTracksMissingFromGeneration(generation);
  }

  Future<List<PersistedSession>> loadAllSessions() =>
      _database.loadAllSessions();

  Future<void> saveAllSessions(List<PersistedSession> sessions) {
    return _database.saveAllSessions(sessions);
  }

  Future<AudioDetail?> loadAudioDetail(AudioDetailTarget target) {
    return _database.loadAudioDetail(target);
  }

  Future<void> upsertAudioDetail(AudioDetail detail) {
    return _database.upsertAudioDetail(detail);
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) {
    return _database.deleteAudioDetail(target);
  }
}
