import 'dart:convert';

import 'package:path/path.dart' as path;

import 'path_matcher.dart';

abstract final class PathDisplay {
  static String fileName(String value, {bool withoutExtension = false}) {
    final displayPath = displayPathFor(value);
    final name = displayPath.split(RegExp(r'[\\/]')).last.trim();
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
    if (!PathMatcher.isContentUri(trimmed)) {
      return _normalizeDisplaySegment(path.normalize(trimmed));
    }

    final decodedDocumentPath = _decodedContentDocumentPath(trimmed);
    if (decodedDocumentPath != null && decodedDocumentPath.isNotEmpty) {
      return decodedDocumentPath;
    }

    final fallback = PathMatcher.safeDecodeComponent(
      PathMatcher.lastContentPathSegment(trimmed) ?? trimmed,
    );
    return _normalizeDisplaySegment(fallback);
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
    return _normalizeDisplaySegment(documentPath);
  }

  static String normalizeDisplaySegment(String value) {
    return _normalizeDisplaySegment(value);
  }

  static String safeFileName(
    String value, {
    String replacement = ' ',
    bool collapseWhitespace = true,
    bool trimTrailingDotsAndSpaces = true,
    String fallback = '',
  }) {
    final cleaned = value.replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
      replacement,
    );
    final whitespaceAdjusted = collapseWhitespace
        ? cleaned.replaceAll(RegExp(r'\s+'), replacement)
        : cleaned;
    final trimmed = whitespaceAdjusted.trim();
    final result = trimTrailingDotsAndSpaces
        ? trimmed.replaceAll(RegExp(r'[. ]+$'), '')
        : trimmed;
    return result.isEmpty ? fallback : result;
  }

  static String _normalizeDisplaySegment(String value) {
    var normalized = value.trim();
    if (normalized.isEmpty) return normalized;
    normalized = PathMatcher.safeDecodeComponent(normalized);
    final fixed = _tryLatin1ToUtf8(normalized);
    if (_looksLikeMojibake(normalized) && !_looksLikeMojibake(fixed)) {
      normalized = fixed;
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
    return value.runes
            .where((rune) => rune >= 0x00C0 && rune <= 0x00FF)
            .length >=
        2;
  }
}
