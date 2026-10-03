import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/features/library/application/audio_detail_document_repository.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';
import 'package:doujin_audio/features/library/domain/audio_detail_store.dart';
import 'package:doujin_audio/features/player/domain/time_segment_label.dart';

void main() {
  late Directory directory;
  late _MemoryAudioDetailStore database;
  late DefaultJsonDocumentStore documents;
  late AudioDetailRepository repository;
  late AudioDetailTarget target;
  late File documentFile;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('audio_detail_repo_');
    database = _MemoryAudioDetailStore();
    documents = DefaultJsonDocumentStore();
    repository = AudioDetailRepository(
      databaseRepository: database,
      documentRepository: AudioDetailDocumentRepository(store: documents),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    target = AudioDetailTarget.libraryRootFolder(directory.path);
    documentFile = File(
      '${directory.path}${Platform.pathSeparator}doujin-audio.json',
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test('explicit save commits database then creates valid document', () async {
    final result = await repository.save(
      AudioDetail.empty(target).copyWith(workTitle: 'Saved'),
    );

    expect(result.documentStatus, JsonDocumentWriteStatus.created);
    expect((await database.load(target))?.workTitle, 'Saved');
    expect(
      jsonDecode(await documentFile.readAsString()),
      isA<Map<Object?, Object?>>(),
    );
  });

  test('derived update never creates or changes JSON', () async {
    const original = '{"foreign":true}\n';
    await documentFile.writeAsString(original, flush: true);

    final updated = await repository.updateDerivedFields(
      target,
      duration: const Duration(seconds: 9),
    );

    expect(updated.duration, const Duration(seconds: 9));
    expect(updated.createdAt, isNull);
    expect(updated.updatedAt, isNull);
    expect(await documentFile.readAsString(), original);
  });

  for (final writeDocument in [false, true]) {
    test(
      '${writeDocument ? 'explicit cover selection' : 'cover discovery'} queued across JSON import preserves imported metadata',
      () async {
        const original = '''{
  "schemaVersion": 1,
  "type": "audio-detail",
  "targetType": "library-root-folder",
  "rjCode": "RJ123456",
  "workTitle": "Imported work",
  "circleName": "Imported circle",
  "voiceActors": ["Imported voice"],
  "tags": ["Imported tag"],
  "releaseDate": "2024-01-02T00:00:00.000Z",
  "durationMs": 123000,
  "salesCount": 100,
  "rating": 4.8,
  "createdAt": "2024-01-01T00:00:00.000Z",
  "updatedAt": "2024-01-03T00:00:00.000Z",
  "unknown": {"keep": true}
}''';
        await documentFile.writeAsString(original, flush: true);
        final originalBytes = await documentFile.readAsBytes();
        final cache = AudioDetailCacheService(repository: repository);
        final loadGate = Completer<void>();
        final loadStarted = Completer<void>();
        database.beforeNextLoad = loadGate.future;
        database.nextLoadStarted = loadStarted;
        final coverPath = '${directory.path}${Platform.pathSeparator}cover.png';

        // Submit the cover request while the DB is empty, then queue an import
        // before that request's first DB read completes. Both persistence modes
        // must preserve the metadata already present in the source document.
        final coverSave = cache.saveCardCoverPath(
          target,
          coverPath,
          selected: writeDocument,
          writeDocument: writeDocument,
        );
        final backupImport = cache.importBackupsMany([target]);
        await loadStarted.future;
        loadGate.complete();
        expect((await backupImport).importedCount, 1);
        expect(await coverSave, coverPath);

        final stored = (await database.load(target))!;
        final cached = cache.resolvedDetail(target)!;
        for (final detail in [stored, cached]) {
          expect(detail.rjCode, 'RJ123456');
          expect(detail.workTitle, 'Imported work');
          expect(detail.circleName, 'Imported circle');
          expect(detail.voiceActors, ['Imported voice']);
          expect(detail.tags, ['Imported tag']);
          expect(
            detail.releaseDate,
            DateTime.parse('2024-01-02T00:00:00.000Z'),
          );
          expect(detail.duration, const Duration(seconds: 123));
          expect(detail.salesCount, 100);
          expect(detail.rating, 4.8);
          expect(detail.createdAt, DateTime.parse('2024-01-01T00:00:00.000Z'));
          expect(
            detail.updatedAt,
            writeDocument
                ? DateTime.fromMillisecondsSinceEpoch(1000)
                : DateTime.parse('2024-01-03T00:00:00.000Z'),
          );
          expect(detail.cardCoverPath, coverPath);
        }
        if (writeDocument) {
          final fields = jsonDecode(await documentFile.readAsString()) as Map;
          expect(fields['rjCode'], 'RJ123456');
          expect(fields['workTitle'], 'Imported work');
          expect(fields['circleName'], 'Imported circle');
          expect(fields['voiceActors'], ['Imported voice']);
          expect(fields['tags'], ['Imported tag']);
          expect(fields['unknown'], {'keep': true});
          expect(fields['cardCoverPath'], coverPath);
          expect(fields['cardCoverSelected'], isTrue);
        } else {
          expect(await documentFile.readAsBytes(), originalBytes);
        }
      },
    );
  }

  test(
    'queued duration and RJ patches retain newly imported user fields',
    () async {
      const original = '''{
  "schemaVersion": 1,
  "type": "audio-detail",
  "targetType": "library-root-folder",
  "rjCode": "RJ123456",
  "workTitle": "Imported work",
  "circleName": "Imported circle",
  "voiceActors": ["Imported voice"],
  "tags": ["Imported tag"],
  "durationMs": 123000,
  "rating": 4.8,
  "unknown": {"keep": true}
}''';
      await documentFile.writeAsString(original, flush: true);
      final bytes = await documentFile.readAsBytes();
      final cache = AudioDetailCacheService(repository: repository);
      final importing = cache.importBackupsMany([target]);
      final patching = cache.updateDerivedFields(
        target,
        rjCode: 'RJ999999',
        duration: const Duration(seconds: 4),
      );
      expect((await importing).importedCount, 1);
      final patched = await patching;
      for (final detail in [
        patched,
        (await database.load(target))!,
        cache.resolvedDetail(target)!,
      ]) {
        expect(detail.rjCode, 'RJ123456');
        expect(detail.duration, const Duration(seconds: 123));
        expect(detail.workTitle, 'Imported work');
        expect(detail.circleName, 'Imported circle');
        expect(detail.voiceActors, ['Imported voice']);
        expect(detail.tags, ['Imported tag']);
        expect(detail.rating, 4.8);
      }
      expect(await documentFile.readAsBytes(), bytes);
    },
  );

  test(
    'read-only import updates database without changing source bytes',
    () async {
      const original = '''{
  "schemaVersion": 1,
  "type": "audio-detail",
  "targetType": "library-root-folder",
  "workTitle": "Imported",
  "unknown": {"keep": true}
}''';
      await documentFile.writeAsString(original, flush: true);

      final result = await repository.importBackupsMany(<AudioDetailTarget>[
        target,
      ]);

      expect(result.importedCount, 1);
      expect((await database.load(target))?.workTitle, 'Imported');
      expect(await documentFile.readAsString(), original);
    },
  );

  test(
    'unchanged explicit cover hydrates the stale cache without rewriting JSON',
    () async {
      final coverPath = '${directory.path}${Platform.pathSeparator}cover.png';
      final source = const AudioDetailJsonCodec().encodeNew(
        AudioDetail.empty(target).copyWith(
          workTitle: 'Restored existing cover',
          voiceActors: ['Restored voice'],
          tags: ['Restored tag'],
          cardCoverPath: coverPath,
          cardCoverSelected: true,
        ),
      );
      await documentFile.writeAsBytes(source, flush: true);
      final cache = AudioDetailCacheService(repository: repository);
      expect((await cache.load(target)).detail.workTitle, isEmpty);
      final revision = cache.revision;

      expect(
        await cache.saveCardCoverPath(
          target,
          coverPath,
          selected: true,
          writeDocument: true,
        ),
        coverPath,
      );
      final cached = cache.resolvedDetail(target)!;
      expect(cached.workTitle, 'Restored existing cover');
      expect(cached.voiceActors, ['Restored voice']);
      expect(cached.tags, ['Restored tag']);
      expect(cached.cardCoverPath, coverPath);
      expect(cached.cardCoverSelected, isTrue);
      expect(cache.revision, greaterThan(revision));
      expect(await documentFile.readAsBytes(), source);
    },
  );

  test(
    'invalid import records failure and leaves database and bytes alone',
    () async {
      const original = '{truncated';
      await documentFile.writeAsString(original, flush: true);

      final result = await repository.importBackupsMany(<AudioDetailTarget>[
        target,
      ]);

      expect(result.failureCount, 1);
      expect(await database.load(target), isNull);
      expect(await documentFile.readAsString(), original);
    },
  );

  test(
    'explicit save merges valid fields but preserves an invalid document',
    () async {
      await documentFile.writeAsString(
        '{"schemaVersion":1,"type":"audio-detail","unknown":7}',
        flush: true,
      );
      await repository.save(
        AudioDetail.empty(target).copyWith(workTitle: 'One'),
      );
      final merged = jsonDecode(await documentFile.readAsString()) as Map;
      expect(merged['unknown'], 7);
      expect(merged['workTitle'], 'One');

      await documentFile.writeAsString('', flush: true);
      final rejected = await repository.save(
        AudioDetail.empty(target).copyWith(workTitle: 'Two'),
      );
      expect(rejected.documentStatus, JsonDocumentWriteStatus.conflict);
      expect(await documentFile.readAsString(), isEmpty);
    },
  );

  test('document failure does not roll back database', () async {
    final failing = AudioDetailRepository(
      databaseRepository: database,
      documentRepository: AudioDetailDocumentRepository(
        store: _ConflictingDocumentStore(),
      ),
    );

    final result = await failing.save(
      AudioDetail.empty(target).copyWith(workTitle: 'Database wins'),
    );

    expect(result.documentFailed, isTrue);
    expect((await database.load(target))?.workTitle, 'Database wins');
  });

  test(
    'explicit save preserves incompatible JSON layouts byte for byte',
    () async {
      for (final original in <String>[
        '[{"targetPath":"other.mp3","unknown":"keep"}]\n',
        '"foreign document"\n',
        '{"schemaVersion":2,"type":"audio-detail","unknown":7}\n',
        '{"schemaVersion":1,"type":"audio-detail","tags":{}}\n',
      ]) {
        await documentFile.writeAsString(original, flush: true);

        final result = await repository.save(
          AudioDetail.empty(target).copyWith(workTitle: 'Edited'),
        );

        expect(result.documentFailed, isTrue);
        expect(await documentFile.readAsString(), original);
        expect((await database.load(target))?.workTitle, 'Edited');
      }
    },
  );

  test('concurrent single-file saves keep every sibling entry', () async {
    final results = await Future.wait([
      for (var index = 0; index < 8; index++)
        AudioDetailDocumentRepository(
          store: DefaultJsonDocumentStore(),
        ).saveExplicit(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(
              '${directory.path}${Platform.pathSeparator}track$index.mp3',
            ),
          ).copyWith(workTitle: 'Track $index'),
        ),
    ]);

    expect(results.every((result) => result.committed), isTrue);
    final entries = jsonDecode(await documentFile.readAsString()) as List;
    expect(entries, hasLength(8));
    expect(
      entries.map((entry) => (entry as Map)['workTitle']),
      unorderedEquals([for (var index = 0; index < 8; index++) 'Track $index']),
    );
  });

  test('cover edit preserves authored database metadata', () async {
    await documentFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'library-root-folder',
        'workTitle': 'External title',
        'tags': ['External tag'],
        'updatedAt': '2099-01-01T00:00:00.000Z',
      }),
      flush: true,
    );
    await database.upsert(
      AudioDetail.empty(
        target,
      ).copyWith(workTitle: 'User title', updatedAt: DateTime.utc(2024)),
    );
    final cache = AudioDetailCacheService(repository: repository);
    await cache.saveCardCoverPath(
      target,
      '${directory.path}${Platform.pathSeparator}cover.png',
      selected: true,
      writeDocument: true,
    );
    expect(cache.resolvedDetail(target)?.workTitle, 'User title');
    expect(cache.resolvedDetail(target)?.tags, isEmpty);
    final fields = jsonDecode(await documentFile.readAsString()) as Map;
    expect(fields['workTitle'], 'User title');
    expect(fields['tags'], isEmpty);
  });

  test('import does not restore tags when user record cleared tags', () async {
    const originalWithTags = '''{
  "schemaVersion": 1,
  "type": "audio-detail",
  "targetType": "library-root-folder",
  "workTitle": "Work",
  "tags": ["TagA", "TagB"],
  "updatedAt": "2024-01-01T00:00:00.000Z"
}''';
    await documentFile.writeAsString(originalWithTags, flush: true);
    await database.upsert(
      AudioDetail.empty(target).copyWith(
        workTitle: 'Work',
        tags: const <String>[],
        updatedAt: DateTime.parse('2024-01-02T00:00:00.000Z'),
      ),
    );

    final result = await repository.importBackupsMany(<AudioDetailTarget>[
      target,
    ]);
    expect(result.importedCount, 1);
    final loaded = await database.load(target);
    expect(loaded?.tags, isEmpty);
  });
}

final class _MemoryAudioDetailStore implements AudioDetailStore {
  final Map<String, AudioDetail> _values = <String, AudioDetail>{};
  Future<void>? beforeNextLoad;
  Completer<void>? nextLoadStarted;

  @override
  Future<List<TimeSegmentLabel>> loadTimeSegmentLabelsForTarget(
    AudioDetailTarget target,
  ) async => const [];

  @override
  Future<void> importDetails(
    Iterable<AudioDetail> details,
    Iterable<TimeSegmentLabel> labels,
  ) => upsertMany(details);

  String _key(AudioDetailTarget target) =>
      '${target.targetType.dbValue}|${PathMatcher.equivalenceKey(target.targetPath)}';

  @override
  Future<void> delete(AudioDetailTarget target) async {
    _values.remove(_key(target));
  }

  @override
  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) async {
    for (final target in targets) {
      _values.remove(_key(target));
    }
  }

  @override
  Future<AudioDetail?> load(AudioDetailTarget target) async {
    final value = _values[_key(target)];
    final gate = beforeNextLoad;
    beforeNextLoad = null;
    if (gate != null) {
      nextLoadStarted?.complete();
      await gate;
    }
    return value;
  }

  @override
  Future<List<AudioDetail>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async => targets
      .map((target) => _values[_key(target)])
      .whereType<AudioDetail>()
      .toList();

  @override
  Future<void> upsert(AudioDetail detail) async {
    _values[_key(detail.target)] = detail;
  }

  @override
  Future<void> upsertMany(Iterable<AudioDetail> details) async {
    for (final detail in details) {
      _values[_key(detail.target)] = detail;
    }
  }
}

final class _ConflictingDocumentStore implements JsonDocumentStore {
  @override
  Future<JsonDocumentDeleteResult> delete({
    required JsonDocumentLocation location,
    required String expectedRevision,
  }) async => const JsonDocumentDeleteResult(
    status: JsonDocumentDeleteStatus.conflict,
    error: 'delete_failed',
  );

  @override
  Future<JsonDocumentReadResult> read(JsonDocumentLocation location) async =>
      const JsonDocumentReadResult.unreadable('read_failed');

  @override
  Future<JsonDocumentWriteResult> write({
    required JsonDocumentLocation location,
    required Uint8List bytes,
    required JsonDocumentWriteMode mode,
    String? expectedRevision,
  }) async => const JsonDocumentWriteResult(
    status: JsonDocumentWriteStatus.conflict,
    error: 'write_failed',
  );
}
