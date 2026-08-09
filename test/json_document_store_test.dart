import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';

void main() {
  late Directory directory;
  late DefaultJsonDocumentStore store;
  late JsonDocumentLocation location;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('json_document_store_');
    store = DefaultJsonDocumentStore();
    location = JsonDocumentLocation.folderChild(
      folder: directory.path,
      name: 'doujin-audio.json',
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test('createIfAbsent preserves every byte of an existing document', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}DOUJIN-AUDIO.JSON',
    );
    final original = utf8.encode('{"unknown": 1}\n');
    await file.writeAsBytes(original, flush: true);

    final result = await store.write(
      location: location,
      bytes: Uint8List.fromList(utf8.encode('{}')),
      mode: JsonDocumentWriteMode.createIfAbsent,
    );

    expect(result.status, JsonDocumentWriteStatus.preserved);
    expect(await file.readAsBytes(), original);
  });

  test('replace refuses stale revision and keeps original non-empty', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}doujin-audio.json',
    );
    await file.writeAsString('{"version": 1}', flush: true);
    final snapshot = (await store.read(location)).snapshot!;
    await file.writeAsString('{"version": 2}', flush: true);

    final result = await store.write(
      location: location,
      bytes: Uint8List.fromList(utf8.encode('{"version": 3}')),
      mode: JsonDocumentWriteMode.replaceIfRevision,
      expectedRevision: snapshot.revision,
    );

    expect(result.status, JsonDocumentWriteStatus.conflict);
    expect(await file.readAsString(), '{"version": 2}');
    expect(await file.length(), greaterThan(0));
  });

  test(
    'invalid staging payload cannot create or truncate a document',
    () async {
      final result = await store.write(
        location: location,
        bytes: Uint8List.fromList(utf8.encode('  ')),
        mode: JsonDocumentWriteMode.createIfAbsent,
      );

      expect(result.status, JsonDocumentWriteStatus.conflict);
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}doujin-audio.json',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'delete requires the exact revision and never removes newer data',
    () async {
      final file = File(
        '${directory.path}${Platform.pathSeparator}doujin-audio.json',
      );
      await file.writeAsString('{"version": 1}', flush: true);
      final snapshot = (await store.read(location)).snapshot!;
      await file.writeAsString('{"version": 2}', flush: true);

      final stale = await store.delete(
        location: location,
        expectedRevision: snapshot.revision,
      );

      expect(stale.status, JsonDocumentDeleteStatus.conflict);
      expect(await file.readAsString(), '{"version": 2}');

      final latest = (await store.read(location)).snapshot!;
      final deleted = await store.delete(
        location: location,
        expectedRevision: latest.revision,
      );
      expect(deleted.status, JsonDocumentDeleteStatus.deleted);
      expect(await file.exists(), isFalse);
    },
  );

  test('read restores a valid backup when the target is missing', () async {
    final backup = File(
      '${directory.path}${Platform.pathSeparator}'
      'doujin-audio.json.doujin.bak',
    );
    await backup.writeAsString('{"version": 1}', flush: true);

    final result = await store.read(location);

    expect(result.status, JsonDocumentReadStatus.found);
    expect(result.snapshot?.text, '{"version": 1}');
    expect(backup.existsSync(), isFalse);
    expect(
      File(
        '${directory.path}${Platform.pathSeparator}doujin-audio.json',
      ).existsSync(),
      isTrue,
    );
  });

  test('read promotes a valid staged create when no target exists', () async {
    final staged = File(
      '${directory.path}${Platform.pathSeparator}'
      'doujin-audio.json.doujin.part',
    );
    await staged.writeAsString('{"version": 2}', flush: true);

    final result = await store.read(location);

    expect(result.status, JsonDocumentReadStatus.found);
    expect(result.snapshot?.text, '{"version": 2}');
    expect(staged.existsSync(), isFalse);
  });

  test('valid target wins and stale transaction files are removed', () async {
    final target = File(
      '${directory.path}${Platform.pathSeparator}doujin-audio.json',
    );
    final backup = File('${target.path}.doujin.bak');
    final staged = File('${target.path}.doujin.part');
    await target.writeAsString('{"version": 3}', flush: true);
    await backup.writeAsString('{"version": 1}', flush: true);
    await staged.writeAsString('{"version": 2}', flush: true);

    final result = await store.read(location);

    expect(result.snapshot?.text, '{"version": 3}');
    expect(backup.existsSync(), isFalse);
    expect(staged.existsSync(), isFalse);
  });

  test('valid backup replaces an interrupted invalid target', () async {
    final target = File(
      '${directory.path}${Platform.pathSeparator}doujin-audio.json',
    );
    final backup = File('${target.path}.doujin.bak');
    await target.writeAsString('{', flush: true);
    await backup.writeAsString('{"version": 4}', flush: true);

    final result = await store.read(location);

    expect(result.status, JsonDocumentReadStatus.found);
    expect(result.snapshot?.text, '{"version": 4}');
    expect(backup.existsSync(), isFalse);
  });

  test('invalid target without a recoverable copy stays unreadable', () async {
    final target = File(
      '${directory.path}${Platform.pathSeparator}doujin-audio.json',
    );
    await target.writeAsString('{', flush: true);

    final read = await store.read(location);
    final write = await store.write(
      location: location,
      bytes: Uint8List.fromList(utf8.encode('{"version": 2}')),
      mode: JsonDocumentWriteMode.createIfAbsent,
    );
    final delete = await store.delete(
      location: location,
      expectedRevision: sha256.convert(utf8.encode('{')).toString(),
    );

    expect(read.status, JsonDocumentReadStatus.unreadable);
    expect(write.status, JsonDocumentWriteStatus.conflict);
    expect(delete.status, JsonDocumentDeleteStatus.conflict);
    expect(await target.readAsString(), '{');
  });

  test('independent stores serialize replacement of the same target', () async {
    final target = File(
      '${directory.path}${Platform.pathSeparator}doujin-audio.json',
    );
    await target.writeAsString('{"version": 1}', flush: true);
    final revision = (await store.read(location)).snapshot!.revision;
    final otherStore = DefaultJsonDocumentStore();

    final results = await Future.wait(<Future<JsonDocumentWriteResult>>[
      store.write(
        location: location,
        bytes: Uint8List.fromList(utf8.encode('{"version": 2}')),
        mode: JsonDocumentWriteMode.replaceIfRevision,
        expectedRevision: revision,
      ),
      otherStore.write(
        location: location,
        bytes: Uint8List.fromList(utf8.encode('{"version": 3}')),
        mode: JsonDocumentWriteMode.replaceIfRevision,
        expectedRevision: revision,
      ),
    ]);

    expect(results.where((result) => result.committed), hasLength(1));
    expect(
      results.where(
        (result) => result.status == JsonDocumentWriteStatus.conflict,
      ),
      hasLength(1),
    );
    expect(
      await target.readAsString(),
      anyOf('{"version": 2}', '{"version": 3}'),
    );
  });

  test('independent stores serialize the same SAF target', () async {
    final gateway = _InMemoryJsonGateway('{"version": 1}');
    final firstStore = DefaultJsonDocumentStore(platformGateway: gateway);
    final secondStore = DefaultJsonDocumentStore(platformGateway: gateway);
    const safLocation = JsonDocumentLocation.folderChild(
      folder: 'content://provider/tree/root',
      name: 'doujin-audio.json',
    );
    final revision = (await firstStore.read(safLocation)).snapshot!.revision;

    final results = await Future.wait(<Future<JsonDocumentWriteResult>>[
      firstStore.write(
        location: safLocation,
        bytes: Uint8List.fromList(utf8.encode('{"version": 2}')),
        mode: JsonDocumentWriteMode.replaceIfRevision,
        expectedRevision: revision,
      ),
      secondStore.write(
        location: safLocation,
        bytes: Uint8List.fromList(utf8.encode('{"version": 3}')),
        mode: JsonDocumentWriteMode.replaceIfRevision,
        expectedRevision: revision,
      ),
    ]);

    expect(results.where((result) => result.committed), hasLength(1));
    expect(gateway.maxConcurrentWrites, 1);
  });
}

final class _InMemoryJsonGateway extends FileCachePlatformGateway {
  _InMemoryJsonGateway(String initial)
    : _bytes = Uint8List.fromList(utf8.encode(initial)),
      super(isAndroid: () => true);

  Uint8List _bytes;
  int _concurrentWrites = 0;
  int maxConcurrentWrites = 0;

  String get _revision => sha256.convert(_bytes).toString();

  @override
  Future<Map<String, Object?>?> readJsonDocument(
    Map<String, Object?> location,
  ) async => <String, Object?>{
    'status': 'found',
    'bytes': _bytes,
    'revision': _revision,
  };

  @override
  Future<Map<String, Object?>?> writeJsonDocument({
    required Map<String, Object?> location,
    required Uint8List bytes,
    required String mode,
    String? expectedRevision,
  }) async {
    _concurrentWrites++;
    maxConcurrentWrites = maxConcurrentWrites < _concurrentWrites
        ? _concurrentWrites
        : maxConcurrentWrites;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (expectedRevision != _revision) {
        return <String, Object?>{
          'status': 'conflict',
          'error': 'revision_mismatch',
          'revision': _revision,
        };
      }
      _bytes = Uint8List.fromList(bytes);
      return <String, Object?>{
        'status': 'replaced',
        'bytesWritten': bytes.length,
        'revision': _revision,
      };
    } finally {
      _concurrentWrites--;
    }
  }
}
