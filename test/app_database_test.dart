import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_effects.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/models/library_entry.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/playback_queue.dart';
import 'package:nameless_audio/models/time_segment_label.dart';
import 'package:nameless_audio/services/app_database.dart';
import 'package:nameless_audio/services/path_matcher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AppDatabase appDatabase;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    appDatabase = AppDatabase.test(db);
  });

  tearDown(() => db.close());

  test(
    'saveAllTracks and loadAllTracks round-trip the music library',
    () async {
      final tracks = <MusicTrack>[
        MusicTrack(
          path: '/library/a.mp3',
          displayName: 'A',
          groupKey: '/library',
          groupTitle: 'Library',
          groupSubtitle: '2 tracks',
          isSingle: false,
          scannedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          fileSizeBytes: 1024,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(2000),
          lastPlayedPosition: const Duration(seconds: 12),
          lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(3000),
          isFavorite: true,
          tags: <String>['asmr', 'sleep'],
          coverCachePath: '/cache/cover.jpg',
          lyricsPath: '/lyrics/a.lrc',
          remoteCoverUrl: 'https://example.com/a-cover.jpg',
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: const <String, Object?>{
            'trackRelativePath': 'disc1/a.mp3',
            'playbackUrls': <String>['https://example.com/a.mp3'],
          },
        ),
        const MusicTrack(
          path: 'content://media/external/audio/media/42',
          displayName: 'Content Track',
          groupKey: 'content://media',
          groupTitle: 'Imported',
          groupSubtitle: '1 track',
          isSingle: true,
          isVideo: true,
        ),
      ];

      await appDatabase.saveAllTracks(tracks);

      final loaded = await appDatabase.loadAllTracks();
      expect(loaded.map((track) => track.toJson()), [
        tracks[0].toJson(),
        tracks[1].toJson(),
      ]);
    },
  );

  test('track metadata columns persist scan and library metadata', () async {
    final track = MusicTrack(
      path: '/library/meta.flac',
      displayName: 'Meta',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
      isVideo: true,
      scannedAt: DateTime.fromMillisecondsSinceEpoch(4000),
      fileSizeBytes: 4096,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(5000),
      lastPlayedPosition: const Duration(minutes: 5),
      lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(6000),
      isFavorite: true,
      tags: const <String>['focus'],
      coverCachePath: '/cache/meta.png',
      lyricsPath: '/lyrics/meta.srt',
      remoteCoverUrl: 'https://example.com/meta-cover.jpg',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: const <String, Object?>{
        'workId': 123,
        'trackRelativePath': 'meta.flac',
      },
    );

    await appDatabase.insertTracks([track]);

    final loaded = await appDatabase.loadAllTracks();
    expect(loaded.single.toJson(), track.toJson());
  });

  test(
    'insertTracks replaces existing rows and deleteTracks removes by path',
    () async {
      const original = MusicTrack(
        path: '/library/a.mp3',
        displayName: 'A',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'old',
        isSingle: false,
      );
      const replacement = MusicTrack(
        path: '/library/a.mp3',
        displayName: 'A renamed',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'new',
        isSingle: false,
      );

      await appDatabase.insertTracks([original]);
      await appDatabase.insertTracks([replacement]);

      var loaded = await appDatabase.loadAllTracks();
      expect(loaded, hasLength(1));
      expect(loaded.single.displayName, 'A renamed');
      expect(loaded.single.groupSubtitle, 'new');

      await appDatabase.deleteTracks(['/library/a.mp3']);

      loaded = await appDatabase.loadAllTracks();
      expect(loaded, isEmpty);
    },
  );

  test('tryMigrateFromJson handles legacy SharedPreferences payloads', () {
    final raw = jsonEncode([
      const MusicTrack(
        path: '/legacy/a.mp3',
        displayName: 'Legacy A',
        groupKey: '/legacy',
        groupTitle: 'Legacy',
        groupSubtitle: '1 track',
        isSingle: false,
      ).toJson(),
    ]);

    final migrated = AppDatabase.tryMigrateFromJson(raw);

    expect(migrated, isNotNull);
    expect(migrated!.single.path, '/legacy/a.mp3');
    expect(AppDatabase.tryMigrateFromJson('{bad json'), isNull);
  });

  test('scan generation helpers keep only the current scan snapshot', () async {
    const first = MusicTrack(
      path: '/library/first.mp3',
      displayName: 'First',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
    );
    const second = MusicTrack(
      path: '/library/second.mp3',
      displayName: 'Second',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
    );

    final generationOne = await appDatabase.nextScanGeneration();
    await appDatabase.markTracksScanned([first], generation: generationOne);

    final generationTwo = await appDatabase.nextScanGeneration();
    await appDatabase.markTracksScanned([second], generation: generationTwo);
    await appDatabase.deleteTracksMissingFromGeneration(generationTwo);

    final loaded = await appDatabase.loadAllTracks();
    expect(loaded, hasLength(1));
    expect(loaded.single.path, second.path);
  });

  test('schema creates track indexes for query-heavy columns', () async {
    final indexes = await db.rawQuery('PRAGMA index_list(tracks)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(indexNames, contains('idx_tracks_group_key'));
    expect(indexNames, contains('idx_tracks_display_name'));
    expect(indexNames, contains('idx_tracks_last_played_at'));
    expect(indexNames, contains('idx_tracks_favorite'));
    expect(indexNames, contains('idx_tracks_scan_generation'));

    final columns = await db.rawQuery('PRAGMA table_info(tracks)');
    final columnNames = columns
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(columnNames, contains('remote_cover_url'));
    expect(columnNames, contains('remote_metadata_kind'));
    expect(columnNames, contains('remote_metadata_json'));
  });

  test('sessions persist custom queue tracks', () async {
    const queueTrack = MusicTrack(
      path: 'https://example.com/track.mp3',
      displayName: 'Track',
      groupKey: 'asmr-work-1',
      groupTitle: 'ASMR Work',
      groupSubtitle: 'RJ000001',
      isSingle: false,
      remoteCoverUrl: 'https://example.com/cover.jpg',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{
        'trackRelativePath': '01_mp3/track.mp3',
        'subtitleUrl': 'https://example.com/track.vtt',
      },
    );

    await appDatabase.saveAllSessions(<PersistedSession>[
      const PersistedSession(
        id: 'session_1',
        trackPath: 'https://example.com/track.mp3',
        loopModeIndex: 1,
        volume: 0.8,
        speed: 1.5,
        positionMs: 1200,
        durationMs: 3200,
        customQueueTracks: <MusicTrack>[queueTrack],
        channelSwapEnabled: false,
        audioEffects: AudioEffectsState(
          skipSilenceEnabled: true,
          noiseReductionEnabled: true,
          eqEnabled: true,
          eqPresetId: 'voice_clear',
          eqBandLevels: <int, double>{1000: 2.5},
        ),
        sortOrder: 0,
      ),
    ]);

    final loaded = await appDatabase.loadAllSessions();
    expect(loaded, hasLength(1));
    expect(loaded.single.trackPath, 'https://example.com/track.mp3');
    expect(loaded.single.speed, closeTo(1.5, 0.001));
    expect(loaded.single.audioEffects.skipSilenceEnabled, isTrue);
    expect(loaded.single.audioEffects.noiseReductionEnabled, isTrue);
    expect(loaded.single.audioEffects.eqPresetId, 'voice_clear');
    expect(loaded.single.audioEffects.eqBandLevels[1000], 2.5);
    expect(loaded.single.customQueueTracks, hasLength(1));
    expect(
      loaded.single.customQueueTracks!.single.toJson(),
      queueTrack.toJson(),
    );
  });

  test(
    'sessions persist playback queue definition and duplicate index',
    () async {
      const track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      const queue = PlaybackQueueDefinition(
        name: 'Night queue',
        colorValue: 0xFF336699,
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'entry_1',
            kind: PlaybackQueueEntryKind.track,
            title: '01',
            tracks: <MusicTrack>[track],
          ),
          PlaybackQueueEntry(
            id: 'entry_2',
            kind: PlaybackQueueEntryKind.work,
            title: 'Work',
            workRootPath: '/library/work',
            tracks: <MusicTrack>[track],
          ),
        ],
      );

      await appDatabase.saveAllSessions(<PersistedSession>[
        PersistedSession(
          id: 'queue_1',
          trackPath: track.path,
          loopModeIndex: 1,
          volume: 1,
          positionMs: 1500,
          durationMs: 3000,
          customQueueTracks: <MusicTrack>[track, track],
          playbackQueue: queue,
          currentQueueIndex: 1,
          channelSwapEnabled: false,
          sortOrder: 0,
        ),
      ]);

      final loaded = (await appDatabase.loadAllSessions()).single;
      expect(loaded.playbackQueue?.name, 'Night queue');
      expect(loaded.playbackQueue?.colorValue, 0xFF336699);
      expect(loaded.playbackQueue?.entries, hasLength(2));
      expect(loaded.playbackQueue?.entries.last.workRootPath, '/library/work');
      expect(loaded.playbackQueue?.expandedTracks, hasLength(2));
      expect(loaded.currentQueueIndex, 1);
    },
  );

  test('audio details round-trip and delete by target', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/root');
    final detail = AudioDetail(
      target: target,
      rjCode: 'RJ123456',
      workTitle: 'Work',
      circleName: 'Circle',
      voiceActors: const <String>['A', 'B'],
      tags: const <String>['tag'],
      releaseDate: DateTime(2024, 5, 6),
      salesCount: 1234,
      rating: 4.5,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    );

    await appDatabase.upsertAudioDetail(detail);

    final loaded = await appDatabase.loadAudioDetail(target);
    expect(loaded?.rjCode, 'RJ123456');
    expect(loaded?.voiceActors, const <String>['A', 'B']);
    expect(loaded?.tags, const <String>['tag']);
    expect(loaded?.releaseDate, DateTime(2024, 5, 6));
    expect(loaded?.salesCount, 1234);
    expect(loaded?.rating, 4.5);

    await appDatabase.deleteAudioDetail(target);

    expect(await appDatabase.loadAudioDetail(target), isNull);
  });

  test(
    'audio detail backup json keeps optional extended fields compatible',
    () {
      final target = AudioDetailTarget.libraryRootFolder('/library/root');
      final detail = AudioDetail.empty(target).copyWith(
        releaseDate: DateTime(2024, 5, 6),
        salesCount: 1234,
        rating: 4.5,
      );

      final restored = AudioDetail.fromBackupJson(
        target,
        detail.toBackupJson(),
      );
      expect(restored, isNotNull);
      expect(restored.releaseDate, DateTime(2024, 5, 6));
      expect(restored.salesCount, 1234);
      expect(restored.rating, 4.5);

      final oldRestored = AudioDetail.fromBackupJson(target, {
        'schemaVersion': 1,
        'type': 'audio-detail',
      });
      expect(oldRestored, isNotNull);
      expect(oldRestored.releaseDate, isNull);
      expect(oldRestored.salesCount, isNull);
      expect(oldRestored.rating, isNull);
    },
  );

  test('schema creates audio detail target index', () async {
    final indexes = await db.rawQuery('PRAGMA index_list(audio_details)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(indexNames, contains('idx_audio_details_target'));
  });

  test('time segment labels round-trip sort and delete by id', () async {
    final first = TimeSegmentLabel(
      id: 'segment_1',
      trackKey: '/library/a.mp3',
      name: 'Opening',
      start: const Duration(seconds: 5),
      end: const Duration(seconds: 12),
      colorValue: 0xFFE57373,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final second = TimeSegmentLabel(
      id: 'segment_2',
      trackKey: '/library/a.mp3',
      name: 'Earlier',
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 3),
      colorValue: 0xFF64B5F6,
      createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    );

    await appDatabase.upsertTimeSegmentLabel(first);
    await appDatabase.upsertTimeSegmentLabel(second);

    var labels = await appDatabase.loadTimeSegmentLabels('/library/a.mp3');
    expect(labels.map((label) => label.id), ['segment_2', 'segment_1']);
    expect(labels.last.name, 'Opening');
    expect(labels.last.start, const Duration(seconds: 5));

    await appDatabase.deleteTimeSegmentLabel('segment_2');

    labels = await appDatabase.loadTimeSegmentLabels('/library/a.mp3');
    expect(labels.map((label) => label.id), ['segment_1']);
  });

  test('time segment labels retarget track keys after rename', () async {
    final label = TimeSegmentLabel(
      id: 'segment_1',
      trackKey: PathMatcher.normalize('/library/old/01.mp3'),
      name: 'Part',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 8),
      colorValue: 0xFFE57373,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await appDatabase.upsertTimeSegmentLabel(label);

    await appDatabase.retargetTimeSegmentLabelsWithinPath(
      oldRoot: '/library/old',
      newRoot: '/library/new',
    );

    expect(
      await appDatabase.loadTimeSegmentLabels(
        PathMatcher.normalize('/library/old/01.mp3'),
      ),
      isEmpty,
    );
    final moved = await appDatabase.loadTimeSegmentLabels(
      PathMatcher.normalize('/library/new/01.mp3'),
    );
    expect(moved.single.id, 'segment_1');

    await appDatabase.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize('/library/new/01.mp3'),
      newTrackKey: PathMatcher.normalize('/library/new/renamed.mp3'),
    );

    expect(
      await appDatabase.loadTimeSegmentLabels(
        PathMatcher.normalize('/library/new/01.mp3'),
      ),
      isEmpty,
    );
    final renamed = await appDatabase.loadTimeSegmentLabels(
      PathMatcher.normalize('/library/new/renamed.mp3'),
    );
    expect(renamed.single.name, 'Part');
  });

  test('schema creates time segment label track index', () async {
    final indexes = await db.rawQuery('PRAGMA index_list(time_segment_labels)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(indexNames, contains('idx_time_segment_labels_track'));
  });

  test('library entries persist full tree rows and state updates', () async {
    final folder = LibraryEntry.folder(
      libraryPath: '/library',
      path: '/library/work',
      parentPath: '/library',
      state: LibraryEntryState.active,
      displayName: 'work',
    );
    final track = LibraryEntry.track(
      libraryPath: '/library',
      track: MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'work',
        groupSubtitle: '/library/work',
        isSingle: false,
        isVideo: true,
        scannedAt: DateTime.fromMillisecondsSinceEpoch(7000),
        fileSizeBytes: 128,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(8000),
      ),
      parentPath: '/library/work',
      state: LibraryEntryState.active,
    );

    await appDatabase.upsertLibraryEntries([folder, track]);
    await appDatabase.setLibraryEntriesState('/library', [
      '/library/work',
      '/library/work/01.mp3',
    ], LibraryEntryState.excluded);

    final loaded = await appDatabase.loadLibraryEntries('/library');
    expect(loaded, hasLength(2));
    expect(
      loaded.where((entry) => entry.isExcluded).map((entry) => entry.path),
      containsAll([
        PathMatcher.normalize('/library/work'),
        PathMatcher.normalize('/library/work/01.mp3'),
      ]),
    );
    expect(
      loaded.singleWhere((entry) => entry.isTrack).toTrack().isVideo,
      true,
    );

    final indexes = await db.rawQuery('PRAGMA index_list(library_entries)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
    expect(indexNames, contains('idx_library_entries_library'));
    expect(indexNames, contains('idx_library_entries_state'));
  });
}
