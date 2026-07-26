import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';

typedef EmbeddedCoverPartialDelete = Future<void> Function();

@visibleForTesting
Future<void> cleanupEmbeddedCoverPartial(
  File partial, {
  EmbeddedCoverPartialDelete? delete,
}) async {
  try {
    if (await partial.exists()) {
      if (delete != null) {
        await delete();
      } else {
        await partial.delete();
      }
    }
  } catch (_) {
    // Cleanup is best effort and must not replace the extraction result.
  }
}

class EmbeddedCoverArtworkService {
  static const String _flacCacheVersion = 'flac-picture-v1';
  static const int _maxEmbeddedPictureBytes = 20 * 1024 * 1024;

  static Future<String?> resolveForTrack(MusicTrack track) async {
    return resolveForPath(track.path);
  }

  static Future<String?> resolveForPath(String pathValue) async {
    final trackPath = pathValue.trim();
    if (trackPath.isEmpty ||
        PathMatcher.isRemoteUri(trackPath) ||
        PathMatcher.isContentUri(trackPath)) {
      return null;
    }
    final trackFile = File(trackPath);
    late final FileStat stat;
    try {
      stat = await trackFile.stat();
    } catch (_) {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;

    final cacheKey = sha256
        .convert(
          utf8.encode(
            '$trackPath|${stat.modified.millisecondsSinceEpoch}|${stat.size}|$_flacCacheVersion',
          ),
        )
        .toString();
    Uint8List? picture;
    try {
      RandomAccessFile? raf;
      late final Uint8List header;
      try {
        raf = await trackFile.open();
        header = await raf.read(12);
      } finally {
        await raf?.close();
      }

      if (header.length >= 3 &&
          header[0] == 0x49 &&
          header[1] == 0x44 &&
          header[2] == 0x33) {
        picture = await _readId3v2Picture(trackFile);
        picture ??= await _readFlacPicture(trackFile);
      } else if (header.length >= 4 &&
          ascii.decode(header.sublist(0, 4), allowInvalid: true) == 'fLaC') {
        picture = await _readFlacPicture(trackFile);
      } else if (header.length >= 8 &&
          ascii.decode(header.sublist(4, 8), allowInvalid: true) == 'ftyp') {
        picture = await _readMp4Picture(trackFile);
      } else {
        picture =
            await _readId3v2Picture(trackFile) ??
            await _readMp4Picture(trackFile) ??
            await _readFlacPicture(trackFile);
      }
    } catch (_) {}

    if (picture == null || picture.isEmpty) return null;

    final cacheRoot = await getTemporaryDirectory();
    final cacheDirectory = Directory(
      path.join(cacheRoot.path, 'embedded_covers'),
    );
    await cacheDirectory.create(recursive: true);
    final output = File(path.join(cacheDirectory.path, '$cacheKey.image'));
    if (await output.exists() && await output.length() > 0) {
      await output.setLastModified(DateTime.now());
      return output.path;
    }

    final partial = File('${output.path}.part');
    try {
      await partial.writeAsBytes(picture, flush: true);
      if (await output.exists()) await output.delete();
      await partial.rename(output.path);
      return output.path;
    } catch (_) {
      return null;
    } finally {
      await cleanupEmbeddedCoverPartial(partial);
    }
  }

  static Future<Uint8List?> _readId3v2Picture(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(10);
      if (header.length != 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        return null;
      }
      final majorVersion = header[3];
      if (majorVersion < 2 || majorVersion > 4) return null;

      final flags = header[5];
      final extHeader = (flags & 0x40) != 0;

      final tagSize =
          ((header[6] & 0x7f) << 21) |
          ((header[7] & 0x7f) << 14) |
          ((header[8] & 0x7f) << 7) |
          (header[9] & 0x7f);

      if (tagSize <= 0 || tagSize > 20 * 1024 * 1024) return null;

      final tagData = await raf.read(tagSize);
      if (tagData.length != tagSize) return null;

      int offset = 0;
      if (extHeader) {
        if (majorVersion == 3) {
          final extSize = ByteData.sublistView(
            tagData,
            offset,
            offset + 4,
          ).getUint32(0);
          offset += extSize;
        } else if (majorVersion == 4) {
          final extSize =
              ((tagData[offset] & 0x7f) << 21) |
              ((tagData[offset + 1] & 0x7f) << 14) |
              ((tagData[offset + 2] & 0x7f) << 7) |
              (tagData[offset + 3] & 0x7f);
          offset += extSize;
        }
      }

      while (offset < tagData.length) {
        final idLength = majorVersion == 2 ? 3 : 4;
        if (offset + idLength > tagData.length) break;

        final frameId = ascii.decode(
          Uint8List.sublistView(tagData, offset, offset + idLength),
          allowInvalid: true,
        );
        offset += idLength;

        if (frameId.codeUnits.any((c) => c == 0)) break;

        int frameSize;
        if (majorVersion == 2) {
          if (offset + 3 > tagData.length) break;
          frameSize =
              (tagData[offset] << 16) |
              (tagData[offset + 1] << 8) |
              tagData[offset + 2];
          offset += 3;
        } else if (majorVersion == 3) {
          if (offset + 4 > tagData.length) break;
          frameSize = ByteData.sublistView(
            tagData,
            offset,
            offset + 4,
          ).getUint32(0);
          offset += 4;
        } else {
          if (offset + 4 > tagData.length) break;
          frameSize =
              ((tagData[offset] & 0x7f) << 21) |
              ((tagData[offset + 1] & 0x7f) << 14) |
              ((tagData[offset + 2] & 0x7f) << 7) |
              (tagData[offset + 3] & 0x7f);
          offset += 4;
        }

        final flagsLength = majorVersion == 2 ? 0 : 2;
        offset += flagsLength;

        if (frameSize <= 0 || offset + frameSize > tagData.length) {
          offset += frameSize;
          continue;
        }

        if (frameId == 'APIC' || frameId == 'PIC') {
          int frameOffset = offset;
          final encoding = tagData[frameOffset];
          frameOffset++;

          if (majorVersion == 2) {
            frameOffset += 3;
          } else {
            while (frameOffset < offset + frameSize &&
                tagData[frameOffset] != 0) {
              frameOffset++;
            }
            frameOffset++;
          }

          frameOffset++; // Picture type

          if (encoding == 1 || encoding == 2) {
            while (frameOffset < offset + frameSize - 1) {
              if (tagData[frameOffset] == 0 && tagData[frameOffset + 1] == 0) {
                frameOffset += 2;
                break;
              }
              frameOffset++;
            }
          } else {
            while (frameOffset < offset + frameSize &&
                tagData[frameOffset] != 0) {
              frameOffset++;
            }
            frameOffset++;
          }

          final pictureDataLength = (offset + frameSize) - frameOffset;
          if (pictureDataLength > 0) {
            return Uint8List.sublistView(
              tagData,
              frameOffset,
              offset + frameSize,
            );
          }
        }
        offset += frameSize;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  static Future<Uint8List?> _readMp4Picture(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final length = await file.length();

      Future<Map<String, dynamic>?> readAtom(
        int start,
        int limit,
        String targetPath,
        int depth,
      ) async {
        if (start >= limit) return null;
        final targetTypes = targetPath.split('.');
        int current = start;
        while (current < limit) {
          await raf!.setPosition(current);
          final header = await raf.read(8);
          if (header.length < 8) return null;
          int size = ByteData.sublistView(header, 0, 4).getUint32(0);
          final type = ascii.decode(
            Uint8List.sublistView(header, 4, 8),
            allowInvalid: true,
          );

          int headerSize = 8;
          if (size == 1) {
            final size64 = await raf.read(8);
            if (size64.length < 8) return null;
            size = ByteData.sublistView(size64, 0, 8).getUint64(0).toInt();
            headerSize = 16;
          } else if (size == 0) {
            size = limit - current;
          }
          final remaining = limit - current;
          if (size < headerSize || size > remaining) return null;

          if (type == targetTypes[depth]) {
            if (depth == targetTypes.length - 1) {
              return {
                'offset': current,
                'size': size,
                'headerSize': headerSize,
              };
            } else {
              int childrenStart = current + headerSize;
              if (type == 'meta') childrenStart += 4;
              if (childrenStart > current + size) return null;
              return await readAtom(
                childrenStart,
                current + size,
                targetPath,
                depth + 1,
              );
            }
          }
          current += size;
        }
        return null;
      }

      final covrAtom = await readAtom(
        0,
        length,
        'moov.udta.meta.ilst.covr.data',
        0,
      );
      if (covrAtom != null) {
        int dataOffset = covrAtom['offset'] as int;
        int dataSize = covrAtom['size'] as int;
        int headerSize = covrAtom['headerSize'] as int;
        final payloadSize = dataSize - (headerSize + 8);
        final payloadOffset = dataOffset + headerSize + 8;
        if (payloadSize <= 0 ||
            payloadSize > _maxEmbeddedPictureBytes ||
            payloadOffset < 0 ||
            payloadOffset > length ||
            payloadSize > length - payloadOffset) {
          return null;
        }
        await raf.setPosition(payloadOffset);
        return await raf.read(payloadSize);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  static Future<Uint8List?> _readFlacPicture(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      await _skipLeadingId3v2Tag(raf);
      final signature = await raf.read(4);
      if (signature.length != 4 || ascii.decode(signature) != 'fLaC') {
        return null;
      }

      var lastBlock = false;
      while (!lastBlock) {
        final header = await raf.read(4);
        if (header.length != 4) return null;
        final firstByte = header[0];
        lastBlock = (firstByte & 0x80) != 0;
        final blockType = firstByte & 0x7f;
        final blockLength = (header[1] << 16) | (header[2] << 8) | header[3];
        if (blockLength <= 0) continue;
        final block = await raf.read(blockLength);
        if (blockType == 6) {
          return _pictureDataFromFlacBlock(block);
        }
        if (blockType == 4) {
          final picture = _pictureDataFromVorbisCommentBlock(block);
          if (picture != null) return picture;
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  static Future<void> _skipLeadingId3v2Tag(RandomAccessFile raf) async {
    final start = await raf.position();
    final header = await raf.read(10);
    if (header.length != 10 ||
        header[0] != 0x49 ||
        header[1] != 0x44 ||
        header[2] != 0x33) {
      await raf.setPosition(start);
      return;
    }
    final tagSize =
        ((header[6] & 0x7f) << 21) |
        ((header[7] & 0x7f) << 14) |
        ((header[8] & 0x7f) << 7) |
        (header[9] & 0x7f);
    final hasFooter = (header[5] & 0x10) != 0;
    await raf.setPosition(start + 10 + tagSize + (hasFooter ? 10 : 0));
  }

  static Uint8List? _pictureDataFromVorbisCommentBlock(Uint8List block) {
    var offset = 0;

    int? readUint32Le() {
      if (offset + 4 > block.length) return null;
      final value = ByteData.sublistView(
        block,
        offset,
        offset + 4,
      ).getUint32(0, Endian.little);
      offset += 4;
      return value;
    }

    String? readUtf8String(int length) {
      if (length < 0 || offset + length > block.length) return null;
      final value = utf8.decode(
        Uint8List.sublistView(block, offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      return value;
    }

    final vendorLength = readUint32Le();
    if (vendorLength == null || readUtf8String(vendorLength) == null) {
      return null;
    }
    final commentCount = readUint32Le();
    if (commentCount == null) return null;
    for (var i = 0; i < commentCount; i++) {
      final commentLength = readUint32Le();
      if (commentLength == null) return null;
      final comment = readUtf8String(commentLength);
      if (comment == null) return null;
      final separatorIndex = comment.indexOf('=');
      if (separatorIndex <= 0) continue;
      final key = comment.substring(0, separatorIndex).toUpperCase();
      if (key != 'METADATA_BLOCK_PICTURE') continue;
      final encoded = comment.substring(separatorIndex + 1).trim();
      try {
        return _pictureDataFromFlacBlock(base64.decode(encoded));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Uint8List? _pictureDataFromFlacBlock(Uint8List block) {
    var offset = 0;

    int? readUint32() {
      if (offset + 4 > block.length) return null;
      final value = ByteData.sublistView(
        block,
        offset,
        offset + 4,
      ).getUint32(0);
      offset += 4;
      return value;
    }

    bool skip(int length) {
      if (length < 0 || offset + length > block.length) return false;
      offset += length;
      return true;
    }

    if (readUint32() == null) return null;
    final mimeLength = readUint32();
    if (mimeLength == null || !skip(mimeLength)) return null;
    final descriptionLength = readUint32();
    if (descriptionLength == null || !skip(descriptionLength)) return null;
    for (var i = 0; i < 4; i++) {
      if (readUint32() == null) return null;
    }
    final pictureLength = readUint32();
    if (pictureLength == null ||
        pictureLength <= 0 ||
        offset + pictureLength > block.length) {
      return null;
    }
    return Uint8List.sublistView(block, offset, offset + pictureLength);
  }
}
