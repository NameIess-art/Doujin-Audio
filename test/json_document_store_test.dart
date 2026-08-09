import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';

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
}
