import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';
import 'package:nameless_audio/core/persistence/json_document_store.dart';
import 'package:nameless_audio/features/library/application/audio_detail_document_repository.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/domain/audio_detail_store.dart';

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
      '${directory.path}${Platform.pathSeparator}nameless-audio.json',
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
      AudioDetail.empty(target).copyWith(duration: const Duration(seconds: 9)),
    );

    expect(updated.duration, const Duration(seconds: 9));
    expect(await documentFile.readAsString(), original);
  });

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
    'explicit save merges valid unknown fields and rebuilds invalid file',
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
      final rebuilt = await repository.save(
        AudioDetail.empty(target).copyWith(workTitle: 'Two'),
      );
      expect(rebuilt.documentStatus, JsonDocumentWriteStatus.replaced);
      expect(
        (jsonDecode(await documentFile.readAsString()) as Map)['workTitle'],
        'Two',
      );
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
}

final class _MemoryAudioDetailStore implements AudioDetailStore {
  final Map<String, AudioDetail> _values = <String, AudioDetail>{};

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
  Future<AudioDetail?> load(AudioDetailTarget target) async =>
      _values[_key(target)];

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
