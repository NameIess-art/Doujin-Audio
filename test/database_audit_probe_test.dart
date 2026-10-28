import 'dart:io';

import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'asmr_identity_test.dart' as identity;

void main() {
  test('audit: v11 restore silently recreates a missing durable EQ table', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('database_audit_');
    addTearDown(() => directory.delete(recursive: true));
    final candidatePath = '${directory.path}/v11.db';
    final candidate = await databaseFactoryFfi.openDatabase(candidatePath);
    await AppDatabase.createSchemaForTest(candidate);
    await identity.createLegacyAsmrTables(candidate);
    for (final table in ['listening_days', 'listening_work_days', 'listening_history', 'listening_imports']) {
      await candidate.execute('DROP TABLE $table');
    }
    await candidate.execute('DROP INDEX idx_time_segment_labels_match');
    await candidate.execute('ALTER TABLE time_segment_labels DROP COLUMN track_match_key');
    await candidate.insert('sessions', {'id': 'saved', 'track_path': '/audio.mp3', 'loop_mode': 0});
    await candidate.insert('session_eq_bands', {'session_id': 'saved', 'frequency_hz': 1000, 'gain_db': 8});
    await candidate.execute('DROP TABLE session_eq_bands');
    await candidate.setVersion(11);
    await candidate.close();

    final unused = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(unused.close);
    final sourceVersion = await AppDatabase.test(unused).validateAndMigrateRestoreCandidate(candidatePath);
    expect(sourceVersion, 11);
    final restored = await databaseFactoryFfi.openDatabase(candidatePath);
    addTearDown(restored.close);
    expect(await restored.query('sessions'), hasLength(1));
    expect(await restored.query('session_eq_bands'), isEmpty);
  });
}
