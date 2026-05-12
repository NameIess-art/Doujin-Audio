import 'package:path/path.dart' as path;

abstract final class PathMatcher {
  static final RegExp _invalidPercentEscape = RegExp(r'%(?![0-9A-Fa-f]{2})');

  static bool isContentUri(String value) => value.startsWith('content://');

  static String safeDecodeComponent(String value) {
    final sanitized = value.replaceAll(_invalidPercentEscape, '%25');
    try {
      return Uri.decodeComponent(sanitized);
    } on FormatException {
      return value;
    } on ArgumentError {
      return value;
    }
  }

  static String? contentPathSegmentAfter(String value, String marker) {
    final segments = _rawPathSegments(value);
    final markerIndex = segments.indexOf(marker);
    if (markerIndex < 0 || markerIndex + 1 >= segments.length) return null;
    return segments[markerIndex + 1];
  }

  static String? lastContentPathSegment(String value) {
    final segments = _rawPathSegments(value);
    if (segments.isEmpty) return null;
    return segments.last;
  }

  static String normalize(String value) {
    if (isContentUri(value)) {
      return value.trimRightSlash();
    }
    return path.normalize(value);
  }

  static bool equalsNormalized(String first, String second) {
    if (isContentUri(first) || isContentUri(second)) {
      final firstDoc = _documentPath(first);
      final secondDoc = _documentPath(second);
      if (firstDoc != null && secondDoc != null) {
        return firstDoc == secondDoc;
      }
      return normalize(first) == normalize(second);
    }
    return path.equals(normalize(first), normalize(second));
  }

  static bool isWithinOrEqual(String child, String parent) {
    final normalizedChild = normalize(child);
    final normalizedParent = normalize(parent);
    if (isContentUri(normalizedChild) || isContentUri(normalizedParent)) {
      final childDoc = _documentPath(normalizedChild);
      final parentDoc = _documentPath(normalizedParent);
      if (childDoc != null && parentDoc != null) {
        return childDoc == parentDoc || childDoc.startsWith('$parentDoc/');
      }
      return normalizedChild == normalizedParent ||
          normalizedChild.startsWith('$normalizedParent/');
    }
    return path.equals(normalizedChild, normalizedParent) ||
        path.isWithin(normalizedParent, normalizedChild);
  }

  static String? relativeWithin(String child, String parent) {
    if (!isWithinOrEqual(child, parent)) return null;
    if (equalsNormalized(child, parent)) return '';

    if (isContentUri(child) || isContentUri(parent)) {
      final childDoc = _documentPath(child);
      final parentDoc = _documentPath(parent);
      if (childDoc == null ||
          parentDoc == null ||
          !childDoc.startsWith('$parentDoc/')) {
        return null;
      }
      return childDoc.substring(parentDoc.length + 1);
    }

    return path.relative(child, from: parent).replaceAll('\\', '/');
  }

  static String replaceWithinOrEqual(
    String value,
    String oldParent,
    String newParent,
  ) {
    if (equalsNormalized(value, oldParent)) return newParent;
    if (!isWithinOrEqual(value, oldParent)) return value;

    if (isContentUri(value) ||
        isContentUri(oldParent) ||
        isContentUri(newParent)) {
      return _replaceContentPrefix(value, oldParent, newParent);
    }

    final relative = path.relative(value, from: oldParent);
    return path.normalize(path.join(newParent, relative));
  }

  static String? _documentPath(String value) {
    if (!isContentUri(value)) return null;
    final markerIndex = value.indexOf('::');
    final relativePath = markerIndex < 0
        ? null
        : value
              .substring(markerIndex + 2)
              .replaceAll('\\', '/')
              .trimRightSlash();
    final uriValue = markerIndex < 0 ? value : value.substring(0, markerIndex);
    final segments = _rawPathSegments(uriValue);
    final documentIndex = segments.indexOf('document');
    if (documentIndex >= 0 && documentIndex + 1 < segments.length) {
      return _joinDocumentPath(
        _normalizeDocumentId(segments[documentIndex + 1]),
        relativePath,
      );
    }

    final treeIndex = segments.indexOf('tree');
    if (treeIndex >= 0 && treeIndex + 1 < segments.length) {
      return _joinDocumentPath(
        _normalizeDocumentId(segments[treeIndex + 1]),
        relativePath,
      );
    }
    return null;
  }

  static String _replaceContentPrefix(
    String value,
    String oldParent,
    String newParent,
  ) {
    final oldDoc = _documentPath(oldParent);
    final newDoc = _documentPath(newParent);
    final valueDoc = _documentPath(value);
    if (oldDoc == null ||
        newDoc == null ||
        valueDoc == null ||
        !(valueDoc == oldDoc || valueDoc.startsWith('$oldDoc/'))) {
      return value;
    }

    final suffix = valueDoc == oldDoc
        ? ''
        : valueDoc.substring(oldDoc.length + 1);
    final nextDoc = _joinDocumentPath(newDoc, suffix);
    if (value.contains('::')) {
      return _appendSyntheticRelative(newParent, suffix);
    }

    final treeUri = _treeUriBase(newParent) ?? _treeUriBase(value);
    if (treeUri == null) return value;
    return '$treeUri/document/${Uri.encodeComponent(nextDoc)}';
  }

  static String _appendSyntheticRelative(String parent, String relative) {
    if (relative.isEmpty) return parent;
    return parent.contains('::') ? '$parent/$relative' : '$parent::$relative';
  }

  static String? _treeUriBase(String value) {
    if (!isContentUri(value)) return null;
    final markerIndex = value.indexOf('::');
    final uriValue = markerIndex < 0 ? value : value.substring(0, markerIndex);
    final schemeIndex = uriValue.indexOf('://');
    if (schemeIndex < 0) return null;
    final treeMarker = uriValue.indexOf('/tree/', schemeIndex + 3);
    if (treeMarker < 0) return null;
    final idStart = treeMarker + '/tree/'.length;
    if (idStart >= uriValue.length) return null;
    final pathEndCandidates = <int>[
      uriValue.indexOf('/', idStart),
      uriValue.indexOf('?', idStart),
      uriValue.indexOf('#', idStart),
    ].where((index) => index >= 0);
    final idEnd = pathEndCandidates.isEmpty
        ? uriValue.length
        : pathEndCandidates.reduce((a, b) => a < b ? a : b);
    return uriValue.substring(0, idEnd);
  }

  static List<String> _rawPathSegments(String value) {
    final schemeIndex = value.indexOf('://');
    if (schemeIndex < 0) return const <String>[];
    final pathStart = value.indexOf('/', schemeIndex + 3);
    if (pathStart < 0 || pathStart + 1 >= value.length) {
      return const <String>[];
    }
    final pathEndCandidates = <int>[
      value.indexOf('?', pathStart + 1),
      value.indexOf('#', pathStart + 1),
    ].where((index) => index >= 0);
    final pathEnd = pathEndCandidates.isEmpty
        ? value.length
        : pathEndCandidates.reduce((a, b) => a < b ? a : b);
    return value
        .substring(pathStart + 1, pathEnd)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
  }

  static String _normalizeDocumentId(String rawId) {
    return safeDecodeComponent(rawId).replaceAll('\\', '/').trimRightSlash();
  }

  static String _joinDocumentPath(String basePath, String? relativePath) {
    final relative = relativePath?.trimLeftSlash();
    if (relative == null || relative.isEmpty) return basePath;
    return '$basePath/$relative';
  }
}

extension _TrimSlash on String {
  String trimRightSlash() {
    var result = this;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  String trimLeftSlash() {
    var result = this;
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    return result;
  }
}
