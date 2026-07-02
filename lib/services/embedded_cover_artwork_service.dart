import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/music_track.dart';
import 'path_matcher.dart';

class EmbeddedCoverArtworkService {
  static const String _flacCacheVersion = 'flac-picture-v1';

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
    final picture = await _readFlacPicture(trackFile);
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
      if (await partial.exists()) await partial.delete();
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
