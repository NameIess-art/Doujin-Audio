import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/embedded_cover_artwork_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'embedded_cover_cache_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') return tempDir.path;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'reads FLAC metadata block picture as standalone cover artwork',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'embedded_cover_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final flacFile = File('${directory.path}/track.flac');
      final imageBytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47]);
      await flacFile.writeAsBytes(_flacWithPicture(imageBytes), flush: true);

      final coverPath = await EmbeddedCoverArtworkService.resolveForTrack(
        MusicTrack(
          path: flacFile.path,
          displayName: 'track.flac',
          groupKey: flacFile.path,
          groupTitle: 'track',
          groupSubtitle: '',
          isSingle: true,
        ),
      );

      expect(coverPath, isNotNull);
      expect(await File(coverPath!).readAsBytes(), imageBytes);
    },
  );

  test('different audio files reuse one identical embedded cover', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_dedup_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final imageBytes = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
    ]);
    final firstTrack = File('${directory.path}/first.flac');
    final secondTrack = File('${directory.path}/second.flac');
    await firstTrack.writeAsBytes(_flacWithPicture(imageBytes), flush: true);
    await secondTrack.writeAsBytes(_flacWithPicture(imageBytes), flush: true);

    final firstCover = await EmbeddedCoverArtworkService.resolveForPath(
      firstTrack.path,
    );
    final secondCover = await EmbeddedCoverArtworkService.resolveForPath(
      secondTrack.path,
    );

    expect(secondCover, firstCover);
    expect(
      await Directory('${tempDir.path}/embedded_covers')
          .list()
          .where((entity) => entity is File && !entity.path.endsWith('.part'))
          .length,
      1,
    );
  });

  test('reads FLAC picture after a leading ID3v2 tag', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final flacFile = File('${directory.path}/track-with-id3.flac');
    final imageBytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);
    await flacFile.writeAsBytes(
      _withId3v2Prefix(_flacWithPicture(imageBytes)),
      flush: true,
    );

    final coverPath = await EmbeddedCoverArtworkService.resolveForPath(
      flacFile.path,
    );

    expect(coverPath, isNotNull);
    expect(await File(coverPath!).readAsBytes(), imageBytes);
  });

  test('reads FLAC METADATA_BLOCK_PICTURE vorbis comment', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final flacFile = File('${directory.path}/track-comment.flac');
    final imageBytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d]);
    await flacFile.writeAsBytes(
      _flacWithVorbisPictureComment(imageBytes),
      flush: true,
    );

    final coverPath = await EmbeddedCoverArtworkService.resolveForPath(
      flacFile.path,
    );

    expect(coverPath, isNotNull);
    expect(await File(coverPath!).readAsBytes(), imageBytes);
  });

  test('partial cleanup failures never replace the primary result', () async {
    final partial = File('${tempDir.path}/cover.image.part');
    await partial.writeAsBytes(<int>[1], flush: true);

    await expectLater(
      cleanupEmbeddedCoverPartial(
        partial,
        delete: () async {
          throw const FileSystemException('injected cleanup failure');
        },
      ),
      completes,
    );
    expect(await partial.exists(), isTrue);
  });

  test('rejects an MP4 cover atom that exceeds its containing file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_mp4_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/malformed.m4a');
    await file.writeAsBytes(_malformedMp4WithOversizedCoverAtom(), flush: true);

    expect(await EmbeddedCoverArtworkService.resolveForPath(file.path), isNull);
  });

  test('reads FLAC COVERART vorbis comment', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_flac_coverart_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final flacFile = File('${directory.path}/track.flac');
    final imageBytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 0x01]);
    await flacFile.writeAsBytes(
      _flacWithCoverartComment(imageBytes),
      flush: true,
    );

    final coverPath = await EmbeddedCoverArtworkService.resolveForPath(
      flacFile.path,
    );
    expect(coverPath, isNotNull);
    expect(await File(coverPath!).readAsBytes(), imageBytes);
  });

  test('reads Ogg METADATA_BLOCK_PICTURE vorbis comment', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_ogg_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final oggFile = File('${directory.path}/track.ogg');
    final imageBytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe0, 0x12]);
    await oggFile.writeAsBytes(
      _oggWithVorbisMetadataBlockPicture(imageBytes),
      flush: true,
    );

    final coverPath = await EmbeddedCoverArtworkService.resolveForPath(
      oggFile.path,
    );
    expect(coverPath, isNotNull);
    expect(await File(coverPath!).readAsBytes(), imageBytes);
  });

  test('reads Opus COVERART vorbis comment', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_opus_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final opusFile = File('${directory.path}/track.opus');
    final imageBytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 0x99]);
    await opusFile.writeAsBytes(
      _opusWithVorbisCoverart(imageBytes),
      flush: true,
    );

    final coverPath = await EmbeddedCoverArtworkService.resolveForPath(
      opusFile.path,
    );
    expect(coverPath, isNotNull);
    expect(await File(coverPath!).readAsBytes(), imageBytes);
  });

  test('reads WAV RIFF id3 chunk APIC cover', () async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_wav_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final wavFile = File('${directory.path}/track.wav');
    final imageBytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe1, 0xaa]);
    await wavFile.writeAsBytes(
      _wavWithId3Apic(imageBytes),
      flush: true,
    );

    final coverPath = await EmbeddedCoverArtworkService.resolveForPath(
      wavFile.path,
    );
    expect(coverPath, isNotNull);
    expect(await File(coverPath!).readAsBytes(), imageBytes);
  });
}

Uint8List _flacWithPicture(Uint8List pictureBytes) {
  return _flacWithMetadataBlock(
    blockType: 6,
    block: _pictureBlock(pictureBytes),
  );
}

Uint8List _flacWithVorbisPictureComment(Uint8List pictureBytes) {
  final comment = utf8.encode(
    'METADATA_BLOCK_PICTURE=${base64.encode(_pictureBlock(pictureBytes))}',
  );
  final block = BytesBuilder();
  final vendor = utf8.encode('doujin-audio-test');
  _addUint32Le(block, vendor.length);
  block.add(vendor);
  _addUint32Le(block, 1);
  _addUint32Le(block, comment.length);
  block.add(comment);
  return _flacWithMetadataBlock(blockType: 4, block: block.toBytes());
}

Uint8List _flacWithMetadataBlock({
  required int blockType,
  required Uint8List block,
}) {
  final flac = BytesBuilder();
  flac.add(ascii.encode('fLaC'));
  flac.add(<int>[
    0x80 | blockType,
    (block.length >> 16) & 0xff,
    (block.length >> 8) & 0xff,
    block.length & 0xff,
  ]);
  flac.add(block);
  return flac.toBytes();
}

Uint8List _pictureBlock(Uint8List pictureBytes) {
  final pictureBlock = BytesBuilder();
  _addUint32(pictureBlock, 3);
  final mime = ascii.encode('image/png');
  _addUint32(pictureBlock, mime.length);
  pictureBlock.add(mime);
  _addUint32(pictureBlock, 0);
  _addUint32(pictureBlock, 1);
  _addUint32(pictureBlock, 1);
  _addUint32(pictureBlock, 24);
  _addUint32(pictureBlock, 0);
  _addUint32(pictureBlock, pictureBytes.length);
  pictureBlock.add(pictureBytes);
  return pictureBlock.toBytes();
}

Uint8List _withId3v2Prefix(Uint8List flacBytes) {
  const payload = <int>[1, 2, 3, 4];
  final bytes = BytesBuilder();
  bytes.add(<int>[0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, payload.length]);
  bytes.add(payload);
  bytes.add(flacBytes);
  return bytes.toBytes();
}

void _addUint32(BytesBuilder builder, int value) {
  builder.add(<int>[
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);
}

void _addUint32Le(BytesBuilder builder, int value) {
  builder.add(<int>[
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
}

Uint8List _malformedMp4WithOversizedCoverAtom() {
  final dataPayload = Uint8List.fromList(const <int>[0, 0, 0, 0, 0, 0, 0, 0]);
  final data = _mp4Atom('data', dataPayload, declaredSize: 0xffffffff);
  final covr = _mp4Atom('covr', data);
  final ilst = _mp4Atom('ilst', covr);
  final meta = _mp4Atom('meta', Uint8List.fromList(<int>[0, 0, 0, 0, ...ilst]));
  final udta = _mp4Atom('udta', meta);
  final moov = _mp4Atom('moov', udta);
  return Uint8List.fromList(<int>[
    ..._mp4Atom('ftyp', Uint8List.fromList(const <int>[0, 0, 0, 0])),
    ...moov,
  ]);
}

Uint8List _mp4Atom(String type, Uint8List payload, {int? declaredSize}) {
  final bytes = BytesBuilder();
  final size = declaredSize ?? payload.length + 8;
  _addUint32(bytes, size);
  bytes.add(ascii.encode(type));
  bytes.add(payload);
  return bytes.toBytes();
}

Uint8List _flacWithCoverartComment(Uint8List pictureBytes) {
  final comment = utf8.encode(
    'COVERART=${base64.encode(pictureBytes)}',
  );
  final block = BytesBuilder();
  final vendor = utf8.encode('doujin-audio-test');
  _addUint32Le(block, vendor.length);
  block.add(vendor);
  _addUint32Le(block, 1);
  _addUint32Le(block, comment.length);
  block.add(comment);
  return _flacWithMetadataBlock(blockType: 4, block: block.toBytes());
}

Uint8List _oggWithVorbisMetadataBlockPicture(Uint8List pictureBytes) {
  final comment = utf8.encode(
    'METADATA_BLOCK_PICTURE=${base64.encode(_pictureBlock(pictureBytes))}',
  );
  final block = BytesBuilder();
  final vendor = utf8.encode('doujin-audio-test');
  _addUint32Le(block, vendor.length);
  block.add(vendor);
  _addUint32Le(block, 1);
  _addUint32Le(block, comment.length);
  block.add(comment);

  final packet = BytesBuilder();
  packet.add(<int>[0x03]);
  packet.add(ascii.encode('vorbis'));
  packet.add(block.toBytes());

  final ogg = BytesBuilder();
  ogg.add(ascii.encode('OggS'));
  ogg.add(<int>[
    0, 2,
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
  ]);
  final packetBytes = packet.toBytes();
  final segCount = (packetBytes.length + 254) ~/ 255;
  ogg.add(<int>[segCount]);
  var remaining = packetBytes.length;
  for (var i = 0; i < segCount; i++) {
    final len = remaining > 255 ? 255 : remaining;
    ogg.add(<int>[len]);
    remaining -= len;
  }
  ogg.add(packetBytes);
  return ogg.toBytes();
}

Uint8List _opusWithVorbisCoverart(Uint8List pictureBytes) {
  final comment = utf8.encode(
    'COVERART=${base64.encode(pictureBytes)}',
  );
  final block = BytesBuilder();
  final vendor = utf8.encode('doujin-audio-test');
  _addUint32Le(block, vendor.length);
  block.add(vendor);
  _addUint32Le(block, 1);
  _addUint32Le(block, comment.length);
  block.add(comment);

  final packet = BytesBuilder();
  packet.add(ascii.encode('OpusTags'));
  packet.add(block.toBytes());

  final ogg = BytesBuilder();
  ogg.add(ascii.encode('OggS'));
  ogg.add(<int>[
    0, 2,
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
  ]);
  final packetBytes = packet.toBytes();
  final segCount = (packetBytes.length + 254) ~/ 255;
  ogg.add(<int>[segCount]);
  var remaining = packetBytes.length;
  for (var i = 0; i < segCount; i++) {
    final len = remaining > 255 ? 255 : remaining;
    ogg.add(<int>[len]);
    remaining -= len;
  }
  ogg.add(packetBytes);
  return ogg.toBytes();
}

Uint8List _wavWithId3Apic(Uint8List pictureBytes) {
  final apicPayload = BytesBuilder();
  apicPayload.addByte(0);
  apicPayload.add(ascii.encode('image/jpeg'));
  apicPayload.addByte(0);
  apicPayload.addByte(3);
  apicPayload.addByte(0);
  apicPayload.add(pictureBytes);

  final apicFrame = BytesBuilder();
  apicFrame.add(ascii.encode('APIC'));
  final payloadBytes = apicPayload.toBytes();
  final frameSizeBuf = ByteData(4)..setUint32(0, payloadBytes.length);
  apicFrame.add(frameSizeBuf.buffer.asUint8List());
  apicFrame.add(<int>[0, 0]);
  apicFrame.add(payloadBytes);

  final tagPayload = apicFrame.toBytes();
  final id3Header = BytesBuilder();
  id3Header.add(ascii.encode('ID3'));
  id3Header.add(<int>[3, 0, 0]);
  final tagLen = tagPayload.length;
  id3Header.add(<int>[
    (tagLen >> 21) & 0x7f,
    (tagLen >> 14) & 0x7f,
    (tagLen >> 7) & 0x7f,
    tagLen & 0x7f,
  ]);
  id3Header.add(tagPayload);
  final fullId3 = id3Header.toBytes();

  final wav = BytesBuilder();
  wav.add(ascii.encode('RIFF'));
  final body = BytesBuilder();
  body.add(ascii.encode('WAVE'));

  body.add(ascii.encode('fmt '));
  final fmtSize = ByteData(4)..setUint32(0, 16, Endian.little);
  body.add(fmtSize.buffer.asUint8List());
  final fmtData = ByteData(16)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, 2, Endian.little)
    ..setUint32(4, 44100, Endian.little)
    ..setUint32(8, 176400, Endian.little)
    ..setUint16(12, 4, Endian.little)
    ..setUint16(14, 16, Endian.little);
  body.add(fmtData.buffer.asUint8List());

  body.add(ascii.encode('data'));
  final dataSize = ByteData(4)..setUint32(0, 4, Endian.little);
  body.add(dataSize.buffer.asUint8List());
  body.add(<int>[0, 0, 0, 0]);

  body.add(ascii.encode('id3 '));
  final id3ChunkSize = ByteData(4)..setUint32(0, fullId3.length, Endian.little);
  body.add(id3ChunkSize.buffer.asUint8List());
  body.add(fullId3);
  if (fullId3.length.isOdd) {
    body.addByte(0);
  }

  final bodyBytes = body.toBytes();
  final riffSize = ByteData(4)..setUint32(0, bodyBytes.length, Endian.little);
  wav.add(riffSize.buffer.asUint8List());
  wav.add(bodyBytes);

  return wav.toBytes();
}
