import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/cover_image_format.dart';
import '../../../core/media/path_matcher.dart';

final class AudioDetailCoverStore {
  AudioDetailCoverStore({Future<Directory> Function()? portableDirectory})
    : _portableDirectory = portableDirectory ?? _defaultPortableDirectory;

  static const String relativePathKey = 'cardCoverRelativePath';
  static const String embeddedKey = 'cardCoverEmbedded';

  final Future<Directory> Function() _portableDirectory;

  AudioDetail normalize(AudioDetail detail) {
    final value = detail.cardCoverPath?.trim();
    return value == null || value.isEmpty
        ? detail.copyWith(cardCoverPath: null, cardCoverSelected: false)
        : detail.copyWith(cardCoverPath: value);
  }

  Future<Map<String, Object?>> documentFields(AudioDetail detail) async {
    final coverPath = detail.cardCoverPath;
    if (coverPath == null) {
      return const <String, Object?>{relativePathKey: null, embeddedKey: null};
    }
    final basePath = _portableBasePath(detail.target);
    final relative = basePath == null
        ? null
        : _normalizeRelativePath(
            PathMatcher.relativeWithin(coverPath, basePath),
          );
    if (relative != null) {
      return <String, Object?>{relativePathKey: relative, embeddedKey: null};
    }
    if (PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return const <String, Object?>{relativePathKey: null, embeddedKey: null};
    }
    try {
      final file = File(coverPath);
      if (!await file.exists()) {
        return const <String, Object?>{
          relativePathKey: null,
          embeddedKey: null,
        };
      }
      final length = await file.length();
      if (length <= 0 || length > maxCoverFileBytes) {
        return const <String, Object?>{
          relativePathKey: null,
          embeddedKey: null,
        };
      }
      final bytes = await file.readAsBytes();
      final mimeType = detectCoverMimeType(coverPath, bytes);
      if (mimeType == null) {
        return const <String, Object?>{
          relativePathKey: null,
          embeddedKey: null,
        };
      }
      return <String, Object?>{
        relativePathKey: null,
        embeddedKey: <String, Object?>{
          'encoding': 'base64',
          'mimeType': mimeType,
          'sha256': sha256.convert(bytes).toString(),
          'byteLength': bytes.length,
          'data': base64Encode(bytes),
        },
      };
    } on Object {
      return const <String, Object?>{relativePathKey: null, embeddedKey: null};
    }
  }

  Future<AudioDetail> restore(
    AudioDetail detail,
    Map<String, Object?> fields,
  ) async {
    final relative = _normalizeRelativePath(fields[relativePathKey]);
    final basePath = _portableBasePath(detail.target);
    if (relative != null && basePath != null) {
      return detail.copyWith(
        cardCoverPath: PathMatcher.join(basePath, relative),
        cardCoverSelected: true,
      );
    }
    final embeddedPath = await _restoreEmbedded(fields[embeddedKey]);
    return embeddedPath == null
        ? detail
        : detail.copyWith(cardCoverPath: embeddedPath, cardCoverSelected: true);
  }

  Future<String?> _restoreEmbedded(Object? value) async {
    if (value is! Map<Object?, Object?>) return null;
    final embedded = Map<String, Object?>.from(value);
    if (embedded['encoding'] != 'base64') return null;
    final mimeType = embedded['mimeType'];
    final expectedDigest = embedded['sha256'];
    final expectedLength = (embedded['byteLength'] as num?)?.toInt();
    final encoded = embedded['data'];
    if (mimeType is! String ||
        !supportedCoverMimeTypes.contains(mimeType.toLowerCase()) ||
        expectedDigest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest) ||
        expectedLength == null ||
        expectedLength <= 0 ||
        expectedLength > maxCoverFileBytes ||
        encoded is! String ||
        encoded.length > ((maxCoverFileBytes + 2) ~/ 3) * 4) {
      return null;
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      return null;
    }
    if (bytes.length != expectedLength ||
        sha256.convert(bytes).toString() != expectedDigest ||
        detectCoverMimeType('', bytes) != mimeType.toLowerCase()) {
      return null;
    }
    final directory = await _portableDirectory();
    await directory.create(recursive: true);
    final output = File(
      path.join(
        directory.path,
        '$expectedDigest.${extensionForCoverMimeType(mimeType)}',
      ),
    );
    if (await _matches(output, bytes.length, expectedDigest)) {
      return output.path;
    }
    final temporary = File(
      '${output.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.part',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (!await _matches(temporary, bytes.length, expectedDigest)) return null;
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
      return output.path;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> _matches(File file, int length, String digest) async {
    if (!await file.exists() || await file.length() != length) return false;
    return sha256.convert(await file.readAsBytes()).toString() == digest;
  }

  String? _portableBasePath(AudioDetailTarget target) =>
      target.isLibraryRootFolder
      ? target.targetPath
      : PathMatcher.parentPath(target.targetPath);

  String? _normalizeRelativePath(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.startsWith('/')) return null;
    final segments = normalized.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      return null;
    }
    return segments.join('/');
  }

  static Future<Directory> _defaultPortableDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'portable_card_covers'));
  }
}
