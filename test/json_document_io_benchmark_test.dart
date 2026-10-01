import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';

void main() {
  test('measure local JSON transactions with the same dataset', () async {
    final directory = await Directory.systemTemp.createTemp('json_io_measure_');
    addTearDown(() => directory.delete(recursive: true));
    for (var i = 0; i < 1000; i++) {
      await File('${directory.path}/entry_$i.txt').writeAsString('media');
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'tracks': List.generate(100, (i) => {'id': i, 'name': '音频 $i'}),
        }),
      ),
    );
    final location = JsonDocumentLocation.folderChild(
      folder: directory.path,
      name: 'doujin-audio.json',
    );
    await File('${directory.path}/DOUJIN-AUDIO.JSON').writeAsBytes(payload);
    final store = DefaultJsonDocumentStore();
    for (var sample = 0; sample < 4; sample++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        expect(
          (await store.read(location)).status,
          JsonDocumentReadStatus.found,
        );
      }
      watch.stop();
      // The first sample warms filesystem and Dart caches.
      // ignore: avoid_print
      print('JSON_READ_SAMPLE_$sample=${watch.elapsedMicroseconds}us');
    }
    for (var sample = 0; sample < 4; sample++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        final current = (await store.read(location)).snapshot!;
        expect(
          (await store.write(
            location: location,
            bytes: payload,
            mode: JsonDocumentWriteMode.replaceIfRevision,
            expectedRevision: current.revision,
          )).committed,
          isTrue,
        );
      }
      watch.stop();
      // ignore: avoid_print
      print('JSON_REPLACE_SAMPLE_$sample=${watch.elapsedMicroseconds}us');
    }
  });
}
