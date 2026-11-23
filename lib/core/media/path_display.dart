import 'dart:convert';

import 'package:path/path.dart' as path;

import 'path_matcher.dart';

abstract final class PathDisplay {
  static final RegExp _pathSeparatorPattern = RegExp(r'[\\/]');
  static final RegExp _unsafeFileNameChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static final RegExp _whitespacePattern = RegExp(r'\s+');
  static final RegExp _trailingDotsAndSpaces = RegExp(r'[. ]+$');

  static String fileName(String value, {bool withoutExtension = false}) {
    final displayPath = displayPathFor(value);
    final segments = displayPath
        .split(_pathSeparatorPattern)
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    final name = segments.isEmpty ? displayPath.trim() : segments.last.trim();
    if (withoutExtension) {
      return path.basenameWithoutExtension(name);
    }
    return name.isEmpty ? displayPath : name;
  }

  static String folderName(String value) {
    final name = fileName(value);
    return name.isEmpty ? displayPathFor(value) : name;
  }

  static String displayPathFor(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    if (PathMatcher.isContentUri(trimmed)) {
      final decodedDocumentPath = _decodedContentDocumentPath(trimmed);
      if (decodedDocumentPath != null && decodedDocumentPath.isNotEmpty) {
        return decodedDocumentPath;
      }

      final fallback = PathMatcher.safeDecodeComponent(
        PathMatcher.lastContentPathSegment(trimmed) ?? trimmed,
      );
      return _normalizeDisplaySegment(fallback, decodePercent: false);
    }
    if (PathMatcher.isRemoteUri(trimmed) || _isFileUri(trimmed)) {
      return _normalizeDisplaySegment(trimmed);
    }

    final androidSharedStoragePath = _androidSharedStoragePath(trimmed);
    if (androidSharedStoragePath != null) {
      return _normalizeDisplaySegment(
        androidSharedStoragePath,
        decodePercent: false,
      );
    }
    return _normalizeDisplaySegment(
      path.normalize(trimmed),
      decodePercent: false,
    );
  }

  static bool _isFileUri(String value) =>
      value.length >= 7 && value.substring(0, 7).toLowerCase() == 'file://';

  static String? _androidSharedStoragePath(String value) {
    const root = '/storage/emulated/0';
    final normalized = path.posix.normalize(value.replaceAll('\\', '/'));
    if (normalized == root) return '/';
    const prefix = '$root/';
    if (!normalized.startsWith(prefix)) return null;
    return normalized.substring(prefix.length);
  }

  static String? _decodedContentDocumentPath(String value) {
    final relativeMarker = value.indexOf('::');
    final relativePath = relativeMarker < 0
        ? ''
        : value.substring(relativeMarker + 2).replaceAll('\\', '/');
    final uriValue = relativeMarker < 0
        ? value
        : value.substring(0, relativeMarker);
    final rawDocumentId =
        PathMatcher.contentPathSegmentAfter(uriValue, 'document') ??
        PathMatcher.contentPathSegmentAfter(uriValue, 'tree');
    if (rawDocumentId == null) return null;

    var documentPath = PathMatcher.safeDecodeComponent(
      rawDocumentId,
    ).replaceAll('\\', '/').trim();
    final colonIndex = documentPath.indexOf(':');
    if (colonIndex >= 0 && colonIndex + 1 < documentPath.length) {
      documentPath = documentPath.substring(colonIndex + 1);
    }
    if (relativePath.isNotEmpty) {
      documentPath = documentPath.isEmpty
          ? relativePath
          : '$documentPath/$relativePath';
    }
    final sharedStoragePath = _androidSharedStoragePath(documentPath);
    final displayPath = sharedStoragePath ?? documentPath;
    return _normalizeDisplaySegment(
      displayPath,
      decodePercent: false,
    ).replaceAll('\\', '/');
  }

  static String normalizeDisplaySegment(
    String value, {
    bool decodePercent = true,
  }) {
    return _normalizeDisplaySegment(value, decodePercent: decodePercent);
  }

  static String safeFileName(
    String value, {
    String replacement = ' ',
    bool collapseWhitespace = true,
    bool trimTrailingDotsAndSpaces = true,
    String fallback = '',
  }) {
    final cleaned = value.replaceAll(_unsafeFileNameChars, replacement);
    final whitespaceAdjusted = collapseWhitespace
        ? cleaned.replaceAll(_whitespacePattern, replacement)
        : cleaned;
    final trimmed = whitespaceAdjusted.trim();
    final result = trimTrailingDotsAndSpaces
        ? trimmed.replaceAll(_trailingDotsAndSpaces, '')
        : trimmed;
    return result.isEmpty ? fallback : result;
  }

  static String _normalizeDisplaySegment(
    String value, {
    bool decodePercent = true,
  }) {
    var normalized = value.trim();
    if (normalized.isEmpty) return normalized;
    if (decodePercent) {
      normalized = PathMatcher.safeDecodeComponent(normalized);
    }
    if (_looksLikeMojibake(normalized)) {
      final fixed = _tryLatin1ToUtf8(normalized);
      if (!_looksLikeMojibake(fixed)) {
        normalized = fixed;
      }
    }
    return normalized;
  }

  static String _tryLatin1ToUtf8(String input) {
    try {
      return utf8.decode(latin1.encode(input), allowMalformed: false);
    } catch (_) {
      return input;
    }
  }

  static bool _looksLikeMojibake(String value) {
    if (value.contains('\uFFFD') || value.contains('\u951F')) return true;
    var count = 0;
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (c >= 0x00C0 && c <= 0x00FF) {
        if (++count >= 2) return true;
      }
    }
    return false;
  }
}
