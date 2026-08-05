import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/features/library/data/audio_detail_cover_store.dart';

void main() {
  late Directory directory;
  late Directory portableDirectory;
  late AudioDetailCoverStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('detail_cover_source_');
    portableDirectory = await Directory.systemTemp.createTemp(
      'detail_cover_portable_',
    );
    store = AudioDetailCoverStore(
      portableDirectory: () async => portableDirectory,
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
    await portableDirectory.delete(recursive: true);
  });

  test('folder-local cover is stored as a portable relative path', () async {
    final cover = File('${directory.path}${Platform.pathSeparator}cover.png');
    await cover.writeAsBytes(_pngBytes, flush: true);
    final detail = AudioDetail.empty(
      AudioDetailTarget.libraryRootFolder(directory.path),
    ).copyWith(cardCoverPath: cover.path, cardCoverSelected: true);

    final fields = await store.documentFields(detail);
    final restored = await store.restore(
      detail.copyWith(cardCoverPath: '/old/location/cover.png'),
      fields,
    );

    expect(fields[AudioDetailCoverStore.relativePathKey], 'cover.png');
    expect(fields[AudioDetailCoverStore.embeddedKey], isNull);
    expect(restored.cardCoverPath, cover.path);
  });

  test('relative cover follows an explicitly migrated target path', () async {
    final nextRoot = Directory(
      '${directory.path}${Platform.pathSeparator}renamed',
    )..createSync();
    final detail = AudioDetail.empty(
      AudioDetailTarget.libraryRootFolder(nextRoot.path),
    );

    final restored = await store.restore(detail, const <String, Object?>{
      AudioDetailCoverStore.relativePathKey: 'art/cover.png',
    });

    expect(
      restored.cardCoverPath,
      '${nextRoot.path}${Platform.pathSeparator}art'
      '${Platform.pathSeparator}cover.png',
    );
  });

  test('external cover embeds verified bytes and restores them', () async {
    final root = Directory('${directory.path}${Platform.pathSeparator}library')
      ..createSync();
    final cover = File('${directory.path}${Platform.pathSeparator}cover.png');
    await cover.writeAsBytes(_pngBytes, flush: true);
    final detail = AudioDetail.empty(
      AudioDetailTarget.libraryRootFolder(root.path),
    ).copyWith(cardCoverPath: cover.path, cardCoverSelected: true);

    final fields = await store.documentFields(detail);
    final embedded = fields[AudioDetailCoverStore.embeddedKey] as Map;
    final restored = await store.restore(
      detail.copyWith(cardCoverPath: '/missing/cover.png'),
      fields,
    );

    expect(embedded['sha256'], sha256.convert(_pngBytes).toString());
    expect(restored.cardCoverPath, isNot('/missing/cover.png'));
    expect(await File(restored.cardCoverPath!).readAsBytes(), _pngBytes);
  });

  test('tampered embedded cover is ignored', () async {
    final detail = AudioDetail.empty(
      AudioDetailTarget.libraryRootFolder(directory.path),
    ).copyWith(cardCoverPath: '/missing/cover.png', cardCoverSelected: true);

    final restored = await store.restore(detail, <String, Object?>{
      AudioDetailCoverStore.embeddedKey: <String, Object?>{
        'encoding': 'base64',
        'mimeType': 'image/png',
        'sha256': List<String>.filled(64, '0').join(),
        'byteLength': _pngBytes.length,
        'data': base64Encode(_pngBytes),
      },
    });

    expect(restored.cardCoverPath, '/missing/cover.png');
    expect(portableDirectory.listSync(), isEmpty);
  });
}

final List<int> _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
