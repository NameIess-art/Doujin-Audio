import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/cross_platform_media_identity.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/time_segment_label.dart';
import 'package:doujin_audio/core/network/webdav_client.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/persistence/persistence_records.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_tag_interest.dart';
import 'package:doujin_audio/features/data_support/application/cross_platform_sync_service.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/data_support/domain/cross_platform_sync_models.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_cross_platform_sync_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, int> _daysMap(List<Map<String, Object?>> rows) => <String, int>{
  for (final row in rows)
    row['date']! as String: (row['milliseconds']! as num).toInt(),
};

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('doujin_cross_sync_test_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppPreferences.init();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('CrossPlatformMediaIdentity matches Windows filesystem paths and Android SAF content URIs', () {
    final windowsTrack = MusicTrack(
      path: r'E:\ASMR\[Circle] RJ123456 Title\SEなし\01_耳かき.wav',
      displayName: '01_耳かき.wav',
      groupKey: r'E:\ASMR\[Circle] RJ123456 Title',
      groupTitle: '[Circle] RJ123456 Title',
      groupSubtitle: r'E:\ASMR\[Circle] RJ123456 Title',
      isSingle: false,
    );
    final androidSafTrack = MusicTrack(
      path:
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/'
          'primary%3AASMR%2FRJ123456%2FSE%E3%81%AA%E3%81%97%2F01_%E8%80%B3%E3%81%8B%E3%81%8D.mp3',
      displayName: '01_耳かき.mp3',
      groupKey:
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/'
          'primary%3AASMR%2FRJ123456',
      groupTitle: 'RJ123456',
      groupSubtitle: 'primary:ASMR/RJ123456',
      isSingle: false,
    );

    final winId = CrossPlatformMediaIdentity.fromTrack(windowsTrack)!;
    final safId = CrossPlatformMediaIdentity.fromTrack(androidSafTrack)!;

    expect(winId.workKey, 'rj:RJ123456');
    expect(safId.workKey, 'rj:RJ123456');
    expect(winId.relativePath, 'SEなし/01_耳かき.wav');
    expect(safId.relativePath, 'SEなし/01_耳かき.mp3');
    // Stem sync keys match across container conversions (.wav <-> .mp3)!
    expect(winId.stemSyncKey, safId.stemSyncKey);
    expect(winId.stemSyncKey, 'rj:RJ123456::seなし/01_耳かき');
  });

  test('schema v20/v21 upgrades cleanly to v22 and pre-v22 backup DB remains valid', () async {
    final legacyDbPath = '${tempDir.path}/legacy_v20.db';
    final rawDb = await databaseFactoryFfi.openDatabase(legacyDbPath);
    await AppDatabase.createSchemaForTest(rawDb);
    for (final table in <String>[
      'sync_track_states',
      'sync_work_states',
      'sync_listening_day_ledger',
      'sync_listening_work_ledger',
      'sync_deleted_time_segments',
    ]) {
      await rawDb.execute('DROP TABLE IF EXISTS $table');
    }
    await rawDb.execute('PRAGMA user_version = 20');
    await rawDb.close();

    // Backup validator must still accept pre-v22 .dabackup SQLite files without sync_* tables,
    // and migrate them cleanly to v22.
    final inspectorDb = await databaseFactoryFfi.openDatabase(
      '${tempDir.path}/inspector.db',
    );
    await AppDatabase.createSchemaForTest(inspectorDb);
    final inspector = AppDatabase.test(inspectorDb);
    addTearDown(inspectorDb.close);
    final sourceVersion = await inspector.validateAndMigrateRestoreCandidate(
      legacyDbPath,
    );
    expect(sourceVersion, 20);

    // Verify upgraded DB now has all sync_* tables.
    final upgradedRaw = await databaseFactoryFfi.openDatabase(legacyDbPath);
    addTearDown(upgradedRaw.close);
    final tables = (await upgradedRaw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((r) => r['name'] as String).toSet();
    expect(
      tables,
      containsAll(<String>[
        'sync_track_states',
        'sync_work_states',
        'sync_listening_day_ledger',
        'sync_listening_work_ledger',
        'sync_deleted_time_segments',
      ]),
    );
  });

  test('merges progress, favorites, G-Counter listening duration idempotently, timeline tombstones, and interests', () async {
    final winRawDb = await databaseFactoryFfi.openDatabase('${tempDir.path}/windows.db');
    final andRawDb = await databaseFactoryFfi.openDatabase('${tempDir.path}/android.db');
    addTearDown(() async {
      await winRawDb.close();
      await andRawDb.close();
    });
    await AppDatabase.createSchemaForTest(winRawDb);
    await AppDatabase.createSchemaForTest(andRawDb);
    final winDb = AppDatabase.test(winRawDb);
    final andDb = AppDatabase.test(andRawDb);

    final winLibRepo = SqliteLibraryRepository(database: winDb);
    final andLibRepo = SqliteLibraryRepository(database: andDb);

    // Windows holds WAV files; Android holds MP3 files in SAF URI tree for the same RJ123456 work.
    final winTrack = MusicTrack(
      path: r'D:\Voice\[Circle] RJ123456 Sleep\SEなし\01.wav',
      displayName: '01.wav',
      groupKey: r'D:\Voice\[Circle] RJ123456 Sleep',
      groupTitle: '[Circle] RJ123456 Sleep',
      groupSubtitle: r'D:\Voice\[Circle] RJ123456 Sleep',
      isSingle: false,
      duration: const Duration(minutes: 40),
      isFavorite: true,
      lastPlayedPosition: const Duration(minutes: 5),
      lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(1000000),
    );
    const safGroup =
        'content://com.android.externalstorage.documents/tree/primary%3AVoice/document/primary%3AVoice%2FRJ123456';
    const safTrackPath = '$safGroup%2FSE%E3%81%AA%E3%81%97%2F01.mp3';
    final andTrack = MusicTrack(
      path: safTrackPath,
      displayName: '01.mp3',
      groupKey: safGroup,
      groupTitle: 'RJ123456',
      groupSubtitle: 'primary:Voice/RJ123456',
      isSingle: false,
      duration: const Duration(minutes: 40),
      lastPlayedPosition: const Duration(minutes: 18),
      lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(2000000),
    );

    await winLibRepo.saveAllTracks(<MusicTrack>[winTrack]);
    await andLibRepo.saveAllTracks(<MusicTrack>[andTrack]);

    // Listening durations: Windows = 30 min on 2026-11-24; Android = 45 min on 2026-11-24.
    await winDb.importListeningBatch('win-b1', <ListeningDayRecord>[
      ListeningDayRecord(
        date: '2026-11-24',
        totalMs: 1800000,
        works: <ListeningWorkRecord>[
          ListeningWorkRecord(
            workKey: 'rj:RJ123456',
            track: winTrack,
            milliseconds: 1800000,
            lastPlayedAtMs: 1000000,
          ),
        ],
      ),
    ]);
    await andDb.importListeningBatch('and-b1', <ListeningDayRecord>[
      ListeningDayRecord(
        date: '2026-11-24',
        totalMs: 2700000,
        works: <ListeningWorkRecord>[
          ListeningWorkRecord(
            workKey: 'rj:RJ123456',
            track: andTrack,
            milliseconds: 2700000,
            lastPlayedAtMs: 2000000,
          ),
        ],
      ),
    ]);

    // Windows saves two timeline labels on 01.wav.
    final winSegKey = TimeSegmentLabel.trackKeyFor(winTrack);
    await winDb.upsertTimeSegmentLabel(
      TimeSegmentLabelRecord(
        id: 'seg-keep',
        trackKey: winSegKey,
        name: 'Whispering',
        startMs: 10000,
        endMs: 60000,
        colorValue: 0xFF42A5F5,
        createdAtMs: 1500000,
        updatedAtMs: 1500000,
      ),
    );
    await winDb.upsertTimeSegmentLabel(
      TimeSegmentLabelRecord(
        id: 'seg-delete',
        trackKey: winSegKey,
        name: 'Old Marker',
        startMs: 70000,
        endMs: 90000,
        colorValue: 0xFFEF5350,
        createdAtMs: 1500000,
        updatedAtMs: 1500000,
      ),
    );

    // Interest preferences: Windows likes 耳かき & learned 3.0 weight; Android excludes ホラー & learned 2.0 weight.
    final tagPrefKey = AsmrPreferencesStore.interestCatalogKeys.keys.first;
    final tagCatKey = AsmrPreferencesStore.interestCatalogKeys[tagPrefKey]!;
    final winInitialTags = AsmrTagPreferences();
    final earKey = winInitialTags.resolve('耳かき');
    final whisperKey = winInitialTags.resolve('ささやき');
    winInitialTags.manualInterests.add(earKey);
    winInitialTags.selectionUpdatedAt[earKey] = 1000;
    winInitialTags.learned[whisperKey] = 3.0;
    await winDb.saveAppSetting(
      tagPrefKey,
      jsonEncode(winInitialTags.toPreferenceJson()),
    );
    await winDb.saveAppSetting(
      tagCatKey,
      jsonEncode(winInitialTags.toCatalogJson()),
    );

    final andInitialTags = AsmrTagPreferences();
    final horrorKey = andInitialTags.resolve('ホラー');
    final andWhisperKey = andInitialTags.resolve('ささやき');
    andInitialTags.excluded.add(horrorKey);
    andInitialTags.selectionUpdatedAt[horrorKey] = 2000;
    andInitialTags.learned[andWhisperKey] = 2.0;
    await andDb.saveAppSetting(
      tagPrefKey,
      jsonEncode(andInitialTags.toPreferenceJson()),
    );
    await andDb.saveAppSetting(
      tagCatKey,
      jsonEncode(andInitialTags.toCatalogJson()),
    );

    final winUpdatedPaths = <String>{};
    final andUpdatedPaths = <String>{};
    final winService = CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: winDb),
      platformName: 'windows',
      deviceName: 'Desktop-PC',
      onSyncApplied: (paths, _, {updatedDetailTargets = const {}}) async =>
          winUpdatedPaths.addAll(paths),
    );
    final andService = CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: andDb),
      platformName: 'android',
      deviceName: 'Pixel-Bedside',
      onSyncApplied: (paths, _, {updatedDetailTargets = const {}}) async =>
          andUpdatedPaths.addAll(paths),
    );
    addTearDown(() {
      winService.dispose();
      andService.dispose();
    });

    // Step 1: Export unified .dabackup from Windows -> mergeBackup on Android,
    // then export .dabackup from Android -> mergeBackup on Windows.
    final winSupportDir = Directory('${tempDir.path}/win_support');
    final andSupportDir = Directory('${tempDir.path}/and_support');
    final winBackupService = DataBackupService(
      database: winDb,
      accountStore: _MemoryAsmrTokenStore(),
      appUpdateService: _TestAppUpdateService(),
      supportDirectoryProvider: () async => winSupportDir,
      platformName: 'windows',
    );
    final andBackupService = DataBackupService(
      database: andDb,
      accountStore: _MemoryAsmrTokenStore(),
      appUpdateService: _TestAppUpdateService(),
      supportDirectoryProvider: () async => andSupportDir,
      platformName: 'android',
    );

    final winBackupFile = await winBackupService.exportBackup(
      '${tempDir.path}/win.dabackup',
    );
    final andInspection = await andBackupService.inspectBackup(
      winBackupFile.path,
    );
    expect(andInspection.isSamePlatform, isFalse);
    expect(andInspection.manifest.platform, 'windows');
    await andBackupService.mergeBackup(
      winBackupFile.path,
      syncService: andService,
    );

    final andBackupFile = await andBackupService.exportBackup(
      '${tempDir.path}/and.dabackup',
    );
    await winBackupService.mergeBackup(
      andBackupFile.path,
      syncService: winService,
    );

    // Verify LWW progress: Android's newer 18m position wins on Windows; Windows' favorite=true wins on Android!
    final winLoadedTrack = (await winLibRepo.loadTrackDetails(<String>{winTrack.path}))[winTrack.path]!;
    final andLoadedTrack = (await andLibRepo.loadTrackDetails(<String>{andTrack.path}))[andTrack.path]!;
    expect(winUpdatedPaths, contains(winTrack.path));
    expect(andUpdatedPaths, contains(andTrack.path));
    expect(winLoadedTrack.lastPlayedPosition, const Duration(minutes: 18));
    expect(andLoadedTrack.isFavorite, isTrue);

    // Verify G-Counter additive listening duration (30m + 45m = 75m = 4,500,000 ms) on BOTH devices!
    expect(_daysMap(await winDb.loadListeningDays())['2026-11-24'], 4500000);
    expect(_daysMap(await andDb.loadListeningDays())['2026-11-24'], 4500000);

    // Repeat bidirectional sync twice more with NO new playback -> zero double-counting!
    for (var i = 0; i < 2; i++) {
      final wBytes = await winService.exportSyncBytes();
      await andService.importSyncBytes(wBytes);
      final aBytes = await andService.exportSyncBytes();
      await winService.importSyncBytes(aBytes);
    }
    expect(_daysMap(await winDb.loadListeningDays())['2026-11-24'], 4500000);
    expect(_daysMap(await andDb.loadListeningDays())['2026-11-24'], 4500000);

    // Verify timeline segments can be loaded on Android (even with .mp3 stem!) and tombstone deletion propagates!
    final andSegKey = TimeSegmentLabel.trackKeyFor(andTrack);
    final andSegmentsBeforeDelete = await andDb.loadTimeSegmentLabels(andSegKey);
    expect(
      andSegmentsBeforeDelete.map((s) => s.id),
      containsAll(<String>['seg-keep', 'seg-delete']),
    );

    await andDb.deleteTimeSegmentLabel('seg-delete');
    final afterDeleteBytes = await andService.exportSyncBytes();
    await winService.importSyncBytes(afterDeleteBytes);

    final winSegmentsAfterDelete = await winDb.loadTimeSegmentLabels(winSegKey);
    expect(winSegmentsAfterDelete.map((s) => s.id), <String>['seg-keep']);

    // Verify merged ASMR tag interests (both manual states + summed 3+2=5 learned weights without inflation).
    final mergedWinTags = AsmrTagPreferences.fromJson(
      jsonDecode((await winDb.loadAppSetting(tagPrefKey))!) as Map<String, dynamic>,
      catalog: jsonDecode((await winDb.loadAppSetting(tagCatKey))!) as Map<String, dynamic>,
    );
    expect(mergedWinTags.manualInterests, contains(earKey));
    expect(mergedWinTags.excluded, contains(horrorKey));
    expect(mergedWinTags.learned[whisperKey], 5.0);

    // Verify corrupted .dasync bytes are rejected by SHA-256 verification.
    final validBytes = await winService.exportSyncBytes();
    final unzipped = Map<String, Object?>.from(
      jsonDecode(utf8.decode(gzip.decode(validBytes))) as Map,
    );
    unzipped['sha256'] = '0' * 64;
    final tamperedBytes = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(unzipped))),
    );
    expect(
      () => CrossPlatformSyncService.decodeSyncBytes(tamperedBytes),
      throwsA(isA<FormatException>()),
    );
  });

  test('WebDAV per-device shard sync merges peer shards and skips unchanged ETags', () async {
    final shards = <String, Uint8List>{};
    var peerDownloads = 0;

    final webDavServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => webDavServer.close(force: true));
    webDavServer.listen((req) async {
      final path = Uri.decodeFull(req.uri.path);
      switch (req.method) {
        case 'MKCOL':
          req.response.statusCode = HttpStatus.created;
          await req.response.close();
        case 'PUT':
          final b = BytesBuilder();
          await for (final c in req) {
            b.add(c);
          }
          shards[path] = b.takeBytes();
          req.response.statusCode = HttpStatus.created;
          await req.response.close();
        case 'MOVE':
          final dest = Uri.decodeFull(Uri.parse(req.headers.value('Destination')!).path);
          shards[dest] = shards.remove(path)!;
          req.response.statusCode = HttpStatus.noContent;
          await req.response.close();
        case 'GET':
          peerDownloads++;
          req.response.statusCode = HttpStatus.ok;
          req.response.add(shards[path]!);
          await req.response.close();
        case 'PROPFIND':
          final buf = StringBuffer('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">');
          buf.write(
            '<d:response><d:href>${req.uri.path}</d:href>'
            '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>'
            '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
          for (final entry in shards.entries) {
            if (entry.key.startsWith('/sync/devices/') && !entry.key.endsWith('.part')) {
              final name = entry.key.substring('/sync/devices/'.length);
              buf.write(
                '<d:response><d:href>/sync/devices/$name</d:href>'
                '<d:propstat><d:prop><d:resourcetype/>'
                '<d:getcontentlength>${entry.value.length}</d:getcontentlength>'
                '<d:getetag>"len-${entry.value.length}"</d:getetag></d:prop>'
                '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
              );
            }
          }
          buf.write('</d:multistatus>');
          req.response.statusCode = HttpStatus.multiStatus;
          req.response.write(buf.toString());
          await req.response.close();
      }
    });

    final rawA = await databaseFactoryFfi.openDatabase('${tempDir.path}/devA.db');
    final rawB = await databaseFactoryFfi.openDatabase('${tempDir.path}/devB.db');
    addTearDown(() async {
      await rawA.close();
      await rawB.close();
    });
    await AppDatabase.createSchemaForTest(rawA);
    await AppDatabase.createSchemaForTest(rawB);
    final dbA = AppDatabase.test(rawA);
    final dbB = AppDatabase.test(rawB);

    await dbA.importListeningBatch('a1', const <ListeningDayRecord>[
      ListeningDayRecord(date: '2026-11-24', totalMs: 600000, works: []),
    ]);

    CrossPlatformSyncService buildService(AppDatabase db) => CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: db),
      readSecret: (_) async => 'p',
      webDavClientFactory: ({required baseUri, username, password}) =>
          WebDavClient(baseUri: baseUri, username: username, password: password),
    );

    final serviceA = buildService(dbA);
    final serviceB = buildService(dbB);
    addTearDown(() {
      serviceA.dispose();
      serviceB.dispose();
    });

    final syncUrl = 'http://127.0.0.1:${webDavServer.port}/sync/';
    const configKey = 'cross_platform_webdav_sync_v1';
    final legacySettings = jsonEncode(
      WebDavSyncSettings(
        url: syncUrl,
        username: 'u',
        passwordConfigured: true,
        autoSyncEnabled: true,
      ).toJson(),
    );
    await AppPreferences.setString(configKey, legacySettings);
    await serviceA.syncWithWebDav();
    expect(shards.keys.where((k) => k.endsWith('.dasync')), hasLength(1));

    // Clear peer marker prefs to simulate Device B's own SharedPreferences store.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppPreferences.init();
    await AppPreferences.setString(configKey, legacySettings);

    final firstPull = await serviceB.syncWithWebDav();
    expect(firstPull?.peersMerged, 1);
    expect(_daysMap(await dbB.loadListeningDays())['2026-11-24'], 600000);
    expect(peerDownloads, 1);

    // Second WebDAV sync sees identical ETag for Device A's shard -> skips GET download!
    final secondPull = await serviceB.syncWithWebDav();
    expect(secondPull?.peersMerged, 0);
    expect(peerDownloads, 1);

    await serviceB.setWebDavSyncEnabled(false);
    expect(await serviceB.syncWithWebDav(), isNull);
    expect(serviceB.webDavSettings.url, syncUrl);
    expect(serviceB.webDavSettings.passwordConfigured, isTrue);
    await serviceB.setWebDavSyncEnabled(true, sourceId: 'missing-source');
    final restarted = buildService(dbB);
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.webDavSettings.sourceId, 'missing-source');
    expect(await restarted.syncWithWebDav(resolveSource: (_) => null), isNull);
  });

  test('merges work-level reviews, listenStatus (including status clear), and metadata across platforms via .dasync v23', () async {
    final winRawDb = await databaseFactoryFfi.openDatabase('${tempDir.path}/win_work_sync.db');
    final andRawDb = await databaseFactoryFfi.openDatabase('${tempDir.path}/and_work_sync.db');
    addTearDown(() async {
      await winRawDb.close();
      await andRawDb.close();
    });
    await AppDatabase.createSchemaForTest(winRawDb);
    await AppDatabase.createSchemaForTest(andRawDb);
    final winDb = AppDatabase.test(winRawDb);
    final andDb = AppDatabase.test(andRawDb);
    final winLibRepo = SqliteLibraryRepository(database: winDb);

    const winFolder = r'E:\Voice\[Circle] RJ246810 Cozy Rain';
    final winTarget = AudioDetailTarget.libraryRootFolder(winFolder);
    await winLibRepo.upsert(
      AudioDetail(
        target: winTarget,
        rjCode: 'RJ246810',
        workTitle: 'Old Title',
        circleName: 'OldCircle',
        voiceActors: const <String>['CV-1'],
        tags: const <String>['雨音'],
        listenStatus: WorkListenStatus.marked,
        userRating: 3,
        reviewText: 'Initial note',
        reviewUpdatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
    );

    final updatedTargets = <(String, String)>{};
    final winService = CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: winDb),
      platformName: 'windows',
      deviceName: 'PC',
      onSyncApplied: (_, _, {updatedDetailTargets = const {}}) async =>
          updatedTargets.addAll(updatedDetailTargets),
    );
    final andService = CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: andDb),
      platformName: 'android',
      deviceName: 'Phone',
    );
    addTearDown(() {
      winService.dispose();
      andService.dispose();
    });

    // Phone edits remote work metadata + review and records it into sync_work_states.
    await andService.upsertSyncedWorkState(
      const SyncWorkStateEntry(
        workKey: 'rj:RJ246810',
        rjCode: 'RJ246810',
        listenStatus: 'listened',
        userRating: 5,
        reviewText: 'Finished listening on phone',
        reviewUpdatedAtMs: 5000,
        workTitle: 'Cozy Rain Deluxe',
        circleName: 'RainStudio',
        voiceActors: <String>['CV-1', 'CV-2'],
        tags: <String>['雨音', '耳かき'],
        rating: 4.9,
        detailUpdatedAtMs: 5000,
      ),
    );

    final andBytes = await andService.exportSyncBytes();
    final summary = await winService.importSyncBytes(andBytes);
    expect(summary.workStatesMerged, 1);
    expect(
      updatedTargets,
      contains((winTarget.targetType.dbValue, winTarget.targetPath)),
    );

    final mergedWinDetail = await winLibRepo.load(winTarget);
    expect(mergedWinDetail, isNotNull);
    expect(mergedWinDetail!.workTitle, 'Cozy Rain Deluxe');
    expect(mergedWinDetail.circleName, 'RainStudio');
    expect(mergedWinDetail.voiceActors, <String>['CV-1', 'CV-2']);
    expect(mergedWinDetail.tags, <String>['雨音', '耳かき']);
    expect(mergedWinDetail.listenStatus, WorkListenStatus.listened);
    expect(mergedWinDetail.userRating, 5);
    expect(mergedWinDetail.reviewText, 'Finished listening on phone');

    // Clearing listenStatus with a newer reviewUpdatedAtMs propagates cleanly.
    await andService.upsertSyncedWorkState(
      const SyncWorkStateEntry(
        workKey: 'rj:RJ246810',
        rjCode: 'RJ246810',
        userRating: 4,
        reviewUpdatedAtMs: 9000,
      ),
    );
    await winService.importSyncBytes(await andService.exportSyncBytes());
    final clearedDetail = await winLibRepo.load(winTarget);
    expect(clearedDetail!.listenStatus, isNull);
    expect(clearedDetail.userRating, 4);
    expect(clearedDetail.reviewText, isEmpty);
    // Detail metadata stays intact when only review was updated!
    expect(clearedDetail.workTitle, 'Cozy Rain Deluxe');
  });

  test(
    'cross-platform .dabackup merge optionally syncs account and portable settings while preserving local paths, and full restore rotates sync deviceId',
    () async {
      final winRawDb = await databaseFactoryFfi.openDatabase(
        '${tempDir.path}/win_portable_src.db',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final andRawDb = await databaseFactoryFfi.openDatabase(
        '${tempDir.path}/and_portable_dst.db',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(() async {
        await winRawDb.close();
        await andRawDb.close();
      });
      await AppDatabase.createSchemaForTest(winRawDb);
      await AppDatabase.createSchemaForTest(andRawDb);
      final winDb = AppDatabase.test(winRawDb);
      final andDb = AppDatabase.test(andRawDb);

      await winDb.saveAppSetting('asmr_content_language_v1', 'ja');
      await winDb.saveAsmrVisibleCategoryNames(<String>['popular', 'latest']);
      await winDb.importListeningBatch('win-ledger-b1', <ListeningDayRecord>[
        const ListeningDayRecord(
          date: '2026-11-25',
          totalMs: 1200000,
          works: <ListeningWorkRecord>[],
        ),
      ]);

      // Populate Windows preferences (mix of portable settings + Windows local paths).
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_language': 'ja',
        'themeMode': 'dark',
        'pureBlackTheme': true,
        'appThemeColor': 'indigo',
        'subtitle_font_size': '22',
        'subtitle_positions': <String>[r'D:\Voice\01.wav|120.0'],
        'watched_folders_v1': jsonEncode(<String>[r'D:\Voice']),
        'windows_lan_server_settings_v1': '{"enabled":true,"port":19527}',
        'playback_settings_v1': jsonEncode(<String, Object?>{
          'asmrApiDomain': 'https://api.asmr-200.com',
          'workNameDisplay': 'folderName',
          'asmrDownloadDestinationRoot': r'E:\Downloads\ASMR',
          'pinnedLibraryPaths': <String>[r'D:\Voice\Pinned'],
          'maxCacheBytes': 1024 * 1024 * 1024,
          'networkRouteSettings': <String, Object?>{
            'proxyMode': 'http',
            'proxyHost': '127.0.0.1',
            'proxyPort': 7890,
          },
          'translationSettings': <String, Object?>{
            'provider': 'openAiCompatible',
            'apiBaseUrl': 'https://llm.example.com/v1',
            'model': 'gpt-4o-mini',
            'apiKeyConfigured': true,
          },
          'customEqPresets': <Map<String, Object?>>[
            <String, Object?>{'id': 'eq-win', 'name': 'Warm Voice'},
          ],
        }),
      });
      await AppPreferences.init();

      final winAccountStore = _MemoryAsmrTokenStore(
        token: 'win-jwt-token',
        name: 'alice_pc',
        password: 'secret-password',
      );
      final winBackupService = DataBackupService(
        database: winDb,
        accountStore: winAccountStore,
        appUpdateService: _TestAppUpdateService(),
        supportDirectoryProvider: () async =>
            Directory('${tempDir.path}/win_sup'),
        platformName: 'windows',
      );
      final winBackup = await winBackupService.exportBackup(
        '${tempDir.path}/win-portable.dabackup',
      );

      // Switch SharedPreferences to Android's local state before merging.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_language': 'zh',
        'themeMode': 'light',
        'customThemeColor': 0xFF112233,
        'watched_folders_v1': jsonEncode(<String>[
          'content://com.android.externalstorage.documents/tree/primary%3AVoice',
        ]),
        'playback_settings_v1': jsonEncode(<String, Object?>{
          'asmrApiDomain': 'https://api.asmr-300.com',
          'asmrDownloadDestinationRoot':
              'content://com.android.externalstorage.documents/tree/primary%3ADownload',
          'pinnedLibraryPaths': <String>['content://saf/pinned'],
          'maxCacheBytes': 300 * 1024 * 1024,
          'networkRouteSettings': <String, Object?>{'proxyMode': 'system'},
          'translationSettings': <String, Object?>{'apiKeyConfigured': false},
          'customEqPresets': <Map<String, Object?>>[
            <String, Object?>{'id': 'eq-and', 'name': 'Bedside Bass'},
          ],
        }),
      });
      await AppPreferences.init();

      final andAccountStore = _MemoryAsmrTokenStore(
        token: 'old-and-token',
        name: 'bob_phone',
        password: 'old-password',
      );
      final andSyncService = CrossPlatformSyncService(
        repository: SqliteCrossPlatformSyncRepository(database: andDb),
        platformName: 'android',
      );
      addTearDown(andSyncService.dispose);
      final andBackupService = DataBackupService(
        database: andDb,
        accountStore: andAccountStore,
        appUpdateService: _TestAppUpdateService(),
        supportDirectoryProvider: () async =>
            Directory('${tempDir.path}/and_sup'),
        platformName: 'android',
      );

      // 1) Default merge (syncAccountAndPortableSettings: false) leaves Android settings & account untouched.
      final mergeOnly = await andBackupService.mergeBackup(
        winBackup.path,
        syncService: andSyncService,
      );
      expect(mergeOnly.accountSynced, isFalse);
      expect(mergeOnly.portableSettingsSynced, isFalse);
      expect(await AppPreferences.getString('app_language'), 'zh');
      expect((await andAccountStore.readCredentials())?['name'], 'bob_phone');
      expect(_daysMap(await andDb.loadListeningDays())['2026-11-25'], 1200000);

      // 2) Opt-in merge (syncAccountAndPortableSettings: true) applies portable settings & account, keeping Android paths.
      final mergeWithSettings = await andBackupService.mergeBackup(
        winBackup.path,
        syncService: andSyncService,
        syncAccountAndPortableSettings: true,
      );
      expect(mergeWithSettings.accountSynced, isTrue);
      expect(mergeWithSettings.portableSettingsSynced, isTrue);
      // Listening duration must stay 1,200,000 ms (idempotent on repeated backup merge!).
      expect(_daysMap(await andDb.loadListeningDays())['2026-11-25'], 1200000);

      expect(await AppPreferences.getString('app_language'), 'ja');
      expect(await AppPreferences.getString('themeMode'), 'dark');
      expect(await AppPreferences.getBool('pureBlackTheme'), isTrue);
      expect(await AppPreferences.getString('appThemeColor'), 'indigo');
      expect(AppPreferences.getIntSync('customThemeColor'), isNull);
      expect(await AppPreferences.getString('subtitle_font_size'), '22');
      expect(await AppPreferences.getStringList('subtitle_positions'), isNull);
      expect(
        jsonDecode((await AppPreferences.getString('watched_folders_v1'))!),
        <String>[
          'content://com.android.externalstorage.documents/tree/primary%3AVoice',
        ],
      );
      expect(
        await AppPreferences.getString('windows_lan_server_settings_v1'),
        isNull,
      );
      final andPlayback =
          jsonDecode((await AppPreferences.getString('playback_settings_v1'))!)
              as Map<String, dynamic>;
      expect(andPlayback['asmrApiDomain'], 'https://api.asmr-200.com');
      expect(andPlayback['workNameDisplay'], 'folderName');
      expect(
        andPlayback['asmrDownloadDestinationRoot'],
        'content://com.android.externalstorage.documents/tree/primary%3ADownload',
      );
      expect(andPlayback['pinnedLibraryPaths'], <String>['content://saf/pinned']);
      expect(andPlayback['maxCacheBytes'], 300 * 1024 * 1024);
      expect(
        (andPlayback['networkRouteSettings'] as Map)['proxyMode'],
        'system',
      );
      expect(
        (andPlayback['translationSettings'] as Map)['apiBaseUrl'],
        'https://llm.example.com/v1',
      );
      expect(
        (andPlayback['translationSettings'] as Map)['apiKeyConfigured'],
        isFalse,
      );
      final presetIds = (andPlayback['customEqPresets'] as List)
          .map((e) => (e as Map)['id'])
          .toSet();
      expect(presetIds, <String>{'eq-and', 'eq-win'});
      expect(await andDb.loadAppSetting('asmr_content_language_v1'), 'ja');
      expect(
        await andDb.loadAsmrVisibleCategoryNames(),
        <String>['popular', 'latest'],
      );
      expect(await andAccountStore.readToken(), 'win-jwt-token');
      expect((await andAccountStore.readCredentials())?['name'], 'alice_pc');

      // 3) Same-platform full restore onto a second Windows machine rotates active sync deviceId
      // so subsequent sync with the original Windows machine never collides or double-counts!
      final winCloneDbDir = Directory('${tempDir.path}/win_clone_db');
      final winCloneSupport = Directory('${tempDir.path}/win_clone_sup');
      late Database? openedCloneRaw;
      openedCloneRaw = null;
      final winCloneDb = AppDatabase.forTest(
        opener: () async {
          openedCloneRaw = await databaseFactoryFfi.openDatabase(
            '${winCloneDbDir.path}/${AppDatabase.fileName}',
          );
          return openedCloneRaw!;
        },
      );
      addTearDown(() async {
        await winCloneDb.close();
        await openedCloneRaw?.close();
      });
      final winCloneBackupService = DataBackupService(
        database: winCloneDb,
        accountStore: _MemoryAsmrTokenStore(),
        appUpdateService: _TestAppUpdateService(),
        supportDirectoryProvider: () async => winCloneSupport,
        databasesPathProvider: () async => winCloneDbDir.path,
        platformName: 'windows',
      );
      await winCloneBackupService.inspectAndStageRestore(winBackup.path);
      final outcome = await winCloneBackupService.applyAtStartup();
      expect(outcome?.succeeded, isTrue);

      final winOrigSync = CrossPlatformSyncService(
        repository: SqliteCrossPlatformSyncRepository(database: winDb),
        platformName: 'windows',
      );
      final winCloneSync = CrossPlatformSyncService(
        repository: SqliteCrossPlatformSyncRepository(database: winCloneDb),
        platformName: 'windows',
      );
      addTearDown(() {
        winOrigSync.dispose();
        winCloneSync.dispose();
      });

      // Record +600,000 ms new listening on the restored clone.
      await winCloneDb.importListeningBatch('clone-b2', <ListeningDayRecord>[
        const ListeningDayRecord(
          date: '2026-11-25',
          totalMs: 600000,
          works: <ListeningWorkRecord>[],
        ),
      ]);
      final origId = await winDb.loadAppSetting('cross_platform_sync_device_id_v1');
      final cloneBytes = await winCloneSync.exportSyncBytes();
      final cloneId = await winCloneDb.loadAppSetting(
        'cross_platform_sync_device_id_v1',
      );
      expect(cloneId, isNotNull);
      expect(cloneId, isNot(equals(origId)));

      await winOrigSync.importSyncBytes(cloneBytes);
      await winCloneSync.importSyncBytes(await winOrigSync.exportSyncBytes());
      // 1,200,000 (original) + 600,000 (clone delta) = 1,800,000 ms on BOTH!
      expect(_daysMap(await winDb.loadListeningDays())['2026-11-25'], 1800000);
      expect(
        _daysMap(await winCloneDb.loadListeningDays())['2026-11-25'],
        1800000,
      );
    },
  );
}

class _MemoryAsmrTokenStore extends SecureAsmrTokenStore {
  _MemoryAsmrTokenStore({this.token, this.name, this.password});

  String? token;
  String? name;
  String? password;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async => token = value;

  @override
  Future<void> clearToken() async => token = null;

  @override
  Future<Map<String, String>?> readCredentials() async {
    if (name != null && password != null && name!.isNotEmpty) {
      return <String, String>{'name': name!, 'password': password!};
    }
    return null;
  }

  @override
  Future<void> writeCredentials(String user, String pass) async {
    name = user;
    password = pass;
  }

  @override
  Future<void> clearCredentials() async {
    name = null;
    password = null;
  }
}

class _TestAppUpdateService extends AppUpdateService {
  @override
  Future<AppVersionInfo> currentAppVersion() async =>
      const AppVersionInfo(versionName: '1.0.0', buildNumber: 100);
}
