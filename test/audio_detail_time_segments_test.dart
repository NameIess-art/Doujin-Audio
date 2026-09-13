import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';
import 'package:doujin_audio/features/player/domain/time_segment_label.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late Directory directory;
  late SqliteLibraryRepository library;
  late SqlitePlaybackRepository playback;
  late AudioDetailRepository repository;
  late AudioDetailTarget target;
  late File document;

  TimeSegmentLabel label(String id, String trackKey) => TimeSegmentLabel(
    id: id,
    trackKey: PathMatcher.normalize(trackKey),
    name: '耳语片段 $id',
    start: const Duration(milliseconds: 1250),
    end: const Duration(milliseconds: 7250),
    colorValue: 0xFF64B5F6,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026, 1, 2),
  );

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    final database = AppDatabase.test(db);
    library = SqliteLibraryRepository(database: database);
    playback = SqlitePlaybackRepository(database: database);
    repository = AudioDetailRepository(databaseRepository: library);
    directory = await Directory.systemTemp.createTemp('audio_label_document_');
    target = AudioDetailTarget.libraryRootFolder(directory.path);
    document = File(PathMatcher.join(directory.path, 'doujin-audio.json'));
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'folder export and import preserve multiple track labels and metadata',
    () async {
      final first = label(
        'first',
        PathMatcher.join(directory.path, '中文/01.mp3'),
      );
      final second = label(
        'second',
        PathMatcher.join(directory.path, '02.mp3'),
      );
      await playback.upsertTimeSegmentLabel(first);
      await playback.upsertTimeSegmentLabel(second);
      await playback.upsertTimeSegmentLabel(
        label('outside', '${directory.path}_other/01.mp3'),
      );
      await repository.save(
        AudioDetail.empty(target).copyWith(workTitle: '作品'),
      );

      final bytes = await document.readAsBytes();
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final entries = json['timeSegmentLabels'] as List<dynamic>;
      expect(entries, hasLength(2));
      expect(
        entries.map((entry) => entry['trackPath']),
        unorderedEquals(['中文/01.mp3', '02.mp3']),
      );
      await playback.deleteTimeSegmentLabel(first.id);
      await playback.deleteTimeSegmentLabel(second.id);

      final result = await repository.importBackupsMany([target]);

      expect(result.failureCount, 0);
      expect(result.importedCount, 1);
      expect(
        (await playback.loadTimeSegmentLabels(first.trackKey)).single.toRow(),
        first.toRow(),
      );
      expect(
        (await playback.loadTimeSegmentLabels(second.trackKey)).single.toRow(),
        second.toRow(),
      );
      expect(await document.readAsBytes(), bytes);
    },
  );

  test(
    'copied folder imports relative tracks without stealing original labels',
    () async {
      final original = label(
        'shared-id',
        PathMatcher.join(directory.path, '声轨/01.mp3'),
      );
      await playback.upsertTimeSegmentLabel(original);
      await repository.save(AudioDetail.empty(target));
      final destination = await Directory(
        PathMatcher.join(directory.path, 'moved'),
      ).create();
      final movedTarget = AudioDetailTarget.libraryRootFolder(destination.path);
      await document.copy(
        PathMatcher.join(destination.path, 'doujin-audio.json'),
      );

      await repository.importBackupsMany([movedTarget]);
      await repository.importBackupsMany([movedTarget]);

      final restored = await playback.loadTimeSegmentLabels(
        PathMatcher.join(destination.path, '声轨/01.mp3'),
      );
      expect(restored, hasLength(1));
      expect(restored.single.name, original.name);
      expect(restored.single.id, isNot(original.id));
      expect(
        (await playback.loadTimeSegmentLabels(
          original.trackKey,
        )).single.toRow(),
        original.toRow(),
      );
      await playback.deleteTimeSegmentLabel(original.id);
      await repository.importBackupsMany([movedTarget]);
      expect(
        await playback.loadTimeSegmentLabels(
          PathMatcher.join(destination.path, '声轨/01.mp3'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'single file exports own labels and preserves neighboring entries',
    () async {
      final firstTarget = AudioDetailTarget.singleAudioFile(
        PathMatcher.join(directory.path, '01.mp3'),
      );
      final secondTarget = AudioDetailTarget.singleAudioFile(
        PathMatcher.join(directory.path, '02.mp3'),
      );
      final first = label('first', firstTarget.targetPath);
      final second = label('second', secondTarget.targetPath);
      await playback.upsertTimeSegmentLabel(first);
      await playback.upsertTimeSegmentLabel(second);
      await repository.save(AudioDetail.empty(firstTarget));
      expect(await repository.exportTimeSegments(secondTarget), isTrue);
      final json = jsonDecode(await document.readAsString()) as List<dynamic>;
      expect(json, hasLength(2));
      expect((json.first['timeSegmentLabels'] as List).single['id'], first.id);
      expect((json.last['timeSegmentLabels'] as List).single['id'], second.id);
      await playback.deleteTimeSegmentLabel(first.id);
      await playback.deleteTimeSegmentLabel(second.id);

      await repository.importBackupsMany([firstTarget, secondTarget]);

      expect(
        (await playback.loadTimeSegmentLabels(first.trackKey)).single.toRow(),
        first.toRow(),
      );
      expect(
        (await playback.loadTimeSegmentLabels(second.trackKey)).single.toRow(),
        second.toRow(),
      );
    },
  );

  test(
    'reimport keeps newer local edits and accepts newer document edits',
    () async {
      final original = label(
        'edit',
        PathMatcher.join(directory.path, '01.mp3'),
      );
      await playback.upsertTimeSegmentLabel(original);
      await repository.save(AudioDetail.empty(target));
      final local = original.copyWith(
        name: '本地更新',
        updatedAt: DateTime.utc(2026, 2),
      );
      await playback.upsertTimeSegmentLabel(local);

      await repository.importBackupsMany([target]);
      expect(
        (await playback.loadTimeSegmentLabels(
          original.trackKey,
        )).single.toRow(),
        local.toRow(),
      );
      final json =
          jsonDecode(await document.readAsString()) as Map<String, dynamic>;
      final entry =
          (json['timeSegmentLabels'] as List).single as Map<String, dynamic>;
      entry['name'] = '文档更新';
      entry['updatedAt'] = DateTime.utc(2026, 3).toIso8601String();
      await document.writeAsString(jsonEncode(json));

      await repository.importBackupsMany([target]);
      await repository.importBackupsMany([target]);

      final labels = await playback.loadTimeSegmentLabels(original.trackKey);
      expect(labels, hasLength(1));
      expect(labels.single.name, '文档更新');
    },
  );

  test('legacy document without labels preserves existing labels', () async {
    final original = label(
      'legacy',
      PathMatcher.join(directory.path, '01.mp3'),
    );
    await playback.upsertTimeSegmentLabel(original);
    await document.writeAsString(
      '{"schemaVersion":1,"type":"audio-detail","workTitle":"Legacy"}',
    );

    await repository.importBackupsMany([target]);

    expect(
      (await playback.loadTimeSegmentLabels(original.trackKey)).single.toRow(),
      original.toRow(),
    );
    expect((await library.load(target))?.workTitle, 'Legacy');
  });

  test('label-only export preserves metadata and exports deletion', () async {
    final original = label(
      'edited',
      PathMatcher.join(directory.path, '01.mp3'),
    );
    const metadata = <String, Object?>{
      'schemaVersion': 1,
      'type': 'audio-detail',
      'workTitle': '手工编辑的作品名',
      'tags': ['保留'],
      'updatedAt': '2026-01-01T00:00:00.000Z',
      'custom': {'value': true},
    };
    await document.writeAsString(jsonEncode(metadata));
    await playback.upsertTimeSegmentLabel(original);

    expect(await repository.exportTimeSegments(target), isTrue);
    var exported =
        jsonDecode(await document.readAsString()) as Map<String, dynamic>;
    expect(exported['timeSegmentLabels'], hasLength(1));
    exported.remove('timeSegmentLabels');
    expect(exported, metadata);
    expect(await library.load(target), isNull);
    await playback.deleteTimeSegmentLabel(original.id);

    expect(await repository.exportTimeSegments(target), isTrue);
    exported =
        jsonDecode(await document.readAsString()) as Map<String, dynamic>;
    expect(exported.remove('timeSegmentLabels'), isEmpty);
    expect(exported, metadata);
    await repository.importBackupsMany([target]);
    expect(await playback.loadTimeSegmentLabels(original.trackKey), isEmpty);
  });

  test(
    'label-only export preserves malformed JSON and reports failure',
    () async {
      await document.writeAsString('{broken');

      expect(await repository.exportTimeSegments(target), isFalse);

      expect(await document.readAsString(), '{broken');
    },
  );

  test(
    'SAF imported labels are available through actual document URI',
    () async {
      const root =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      const actual = '$root/document/primary%3AMusic%2FAlbum%2F01.mp3';
      final safTarget = AudioDetailTarget.libraryRootFolder('$root::Album');
      const codec = AudioDetailJsonCodec();
      final original = label('saf', actual);
      final encoded = codec.encodeNew(
        AudioDetail.empty(safTarget),
        additionalFields: codec.timeSegmentFields(safTarget, [original]),
      );
      final decoded = codec.decodeDocument(encoded, safTarget);
      await library.importDetails([decoded.detail], decoded.timeSegmentLabels);

      final restored = await playback.loadTimeSegmentLabels(actual);

      expect(restored, hasLength(1));
      expect(restored.single.toRow(), original.toRow());
    },
  );

  test(
    'Windows paths preserve Unicode spaces and case insensitive lookup',
    () async {
      final windowsTarget = AudioDetailTarget.libraryRootFolder(
        r'C:\音声 作品\Album',
      );
      final original = label('windows', r'c:\音声 作品\ALBUM\Disc 1\01.mp3');
      const codec = AudioDetailJsonCodec();
      final bytes = codec.encodeNew(
        AudioDetail.empty(windowsTarget),
        additionalFields: codec.timeSegmentFields(windowsTarget, [original]),
      );
      final decoded = codec.decodeDocument(bytes, windowsTarget);
      expect(
        (jsonDecode(utf8.decode(bytes))['timeSegmentLabels'] as List)
            .single['trackPath'],
        'Disc 1/01.mp3',
      );
      await library.importDetails([decoded.detail], decoded.timeSegmentLabels);

      final restored = await playback.loadTimeSegmentLabels(original.trackKey);

      expect(restored.single.toRow(), original.toRow());
    },
  );

  for (final invalid in <Map<String, Object?>>[
    {'startMs': -1},
    {'endMs': 0},
    {'name': 123},
    {'trackPath': '../outside.mp3'},
    {'trackPath': r'C:\outside.mp3'},
    {'updatedAt': 'invalid-date'},
  ]) {
    test(
      'invalid label $invalid rejects entire document without partial import',
      () async {
        final first = label(
          'valid',
          PathMatcher.join(directory.path, '01.mp3'),
        );
        final second = label(
          'invalid',
          PathMatcher.join(directory.path, '02.mp3'),
        );
        await playback.upsertTimeSegmentLabel(first);
        await playback.upsertTimeSegmentLabel(second);
        await repository.save(AudioDetail.empty(target));
        final json =
            jsonDecode(await document.readAsString()) as Map<String, dynamic>;
        json['workTitle'] = 'Must not import';
        ((json['timeSegmentLabels'] as List).last as Map<String, dynamic>)
            .addAll(invalid);
        final bytes = utf8.encode(jsonEncode(json));
        await document.writeAsBytes(bytes);
        await playback.deleteTimeSegmentLabel(first.id);
        await playback.deleteTimeSegmentLabel(second.id);

        final result = await repository.importBackupsMany([target]);

        expect(result.failureCount, 1);
        expect(result.importedCount, 0);
        expect(await playback.loadTimeSegmentLabels(first.trackKey), isEmpty);
        expect(await playback.loadTimeSegmentLabels(second.trackKey), isEmpty);
        expect((await library.load(target))?.workTitle, isEmpty);
        expect(await document.readAsBytes(), bytes);
      },
    );
  }
}
