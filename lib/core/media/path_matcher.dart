import 'package:path/path.dart' as path;

abstract final class PathMatcher {
  static final RegExp _invalidPercentEscape = RegExp(r'%(?![0-9A-Fa-f]{2})');
  static final RegExp _windowsAbsolutePath = RegExp(
    r'^(?:[A-Za-z]:[\\/]|\\\\)',
  );
  static final path.Context _windowsContext = path.Context(
    style: path.Style.windows,
  );

  static bool isContentUri(String value) => value.startsWith('content://');

  static bool isRemoteUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

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
    if (isContentUri(value) || isRemoteUri(value)) {
      return value.trimRightSlash();
    }
    return _contextFor(value).normalize(value);
  }

  static bool equalsNormalized(String first, String second) {
    if (isRemoteUri(first) || isRemoteUri(second)) {
      return normalize(first) == normalize(second);
    }
    if (isContentUri(first) || isContentUri(second)) {
      final firstDoc = _documentPath(first);
      final secondDoc = _documentPath(second);
      if (firstDoc != null && secondDoc != null) {
        return firstDoc == secondDoc;
      }
      return normalize(first) == normalize(second);
    }
    final context = _contextFor(first, second);
    return context.equals(context.normalize(first), context.normalize(second));
  }

  static String equivalenceKey(String value) {
    final normalized = normalize(value);
    if (isRemoteUri(normalized)) return 'remote:$normalized';
    if (isContentUri(normalized)) {
      return 'content:${_documentPath(normalized) ?? normalized}';
    }
    final canonical = normalized.replaceAll('\\', '/');
    return _windowsAbsolutePath.hasMatch(normalized)
        ? 'windows:${canonical.toLowerCase()}'
        : 'file:$canonical';
  }

  static String parentEquivalenceKey(String value) {
    final normalized = normalize(value);
    if (isContentUri(normalized)) {
      final documentPath = _documentPath(normalized);
      if (documentPath != null) {
        final separator = documentPath.lastIndexOf('/');
        final parent = separator < 0
            ? documentPath
            : documentPath.substring(0, separator);
        return 'content:$parent';
      }
      final uri = Uri.tryParse(normalized);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        return 'content:${uri.replace(pathSegments: uri.pathSegments.sublist(0, uri.pathSegments.length - 1))}';
      }
      return equivalenceKey(normalized);
    }
    if (isRemoteUri(normalized)) {
      final uri = Uri.tryParse(normalized);
      if (uri == null || uri.pathSegments.isEmpty) {
        return equivalenceKey(normalized);
      }
      return equivalenceKey(
        uri
            .replace(
              pathSegments: uri.pathSegments.sublist(
                0,
                uri.pathSegments.length - 1,
              ),
            )
            .toString(),
      );
    }
    return equivalenceKey(_contextFor(normalized).dirname(normalized));
  }

  static bool isWithinOrEqual(String child, String parent) {
    final normalizedChild = normalize(child);
    final normalizedParent = normalize(parent);
    if (isRemoteUri(normalizedChild) || isRemoteUri(normalizedParent)) {
      return normalizedChild == normalizedParent;
    }
    if (isContentUri(normalizedChild) || isContentUri(normalizedParent)) {
      final childDoc = _documentPath(normalizedChild);
      final parentDoc = _documentPath(normalizedParent);
      if (childDoc != null && parentDoc != null) {
        return childDoc == parentDoc || childDoc.startsWith('$parentDoc/');
      }
      return normalizedChild == normalizedParent ||
          normalizedChild.startsWith('$normalizedParent/');
    }
    final context = _contextFor(normalizedChild, normalizedParent);
    return context.equals(normalizedChild, normalizedParent) ||
        context.isWithin(normalizedParent, normalizedChild);
  }

  static bool isWithinOrEqualNormalized(
    String normalizedChild,
    String normalizedParent,
  ) {
    if (isRemoteUri(normalizedChild) || isRemoteUri(normalizedParent)) {
      return normalizedChild == normalizedParent;
    }
    if (isContentUri(normalizedChild) || isContentUri(normalizedParent)) {
      final childDoc = _documentPath(normalizedChild);
      final parentDoc = _documentPath(normalizedParent);
      if (childDoc != null && parentDoc != null) {
        return childDoc == parentDoc || childDoc.startsWith('$parentDoc/');
      }
      return normalizedChild == normalizedParent ||
          normalizedChild.startsWith('$normalizedParent/');
    }
    final context = _contextFor(normalizedChild, normalizedParent);
    return context.equals(normalizedChild, normalizedParent) ||
        context.isWithin(normalizedParent, normalizedChild);
  }

  static String? relativeWithin(String child, String parent) {
    if (!isWithinOrEqual(child, parent)) return null;
    if (equalsNormalized(child, parent)) return '';

    if (isRemoteUri(child) || isRemoteUri(parent)) {
      return null;
    }

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

    return _contextFor(
      child,
      parent,
    ).relative(child, from: parent).replaceAll('\\', '/');
  }

  static String replaceWithinOrEqual(
    String value,
    String oldParent,
    String newParent,
  ) {
    if (equalsNormalized(value, oldParent)) return newParent;
    if (!isWithinOrEqual(value, oldParent)) return value;

    if (isRemoteUri(value) ||
        isRemoteUri(oldParent) ||
        isRemoteUri(newParent)) {
      return value;
    }

    if (isContentUri(value) ||
        isContentUri(oldParent) ||
        isContentUri(newParent)) {
      return _replaceContentPrefix(value, oldParent, newParent);
    }

    final context = _contextFor(value, oldParent, newParent);
    final relative = context.relative(value, from: oldParent);
    return context.normalize(context.join(newParent, relative));
  }

  static String join(String parent, String child) {
    final context = _contextFor(parent);
    return context.normalize(context.join(parent, child));
  }

  static path.Context _contextFor(
    String first, [
    String? second,
    String? third,
  ]) {
    if (_windowsAbsolutePath.hasMatch(first) ||
        (second != null && _windowsAbsolutePath.hasMatch(second)) ||
        (third != null && _windowsAbsolutePath.hasMatch(third))) {
      return _windowsContext;
    }
    return path.context;
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

final class PathMembershipIndex {
  PathMembershipIndex(Iterable<String> paths)
    : _keys = paths.map(PathMatcher.equivalenceKey).toSet() {
    _sortedKeys = _keys.toList(growable: false)..sort();
  }

  final Set<String> _keys;
  late final List<String> _sortedKeys;

  bool containsEquivalent(String value) {
    return _keys.contains(PathMatcher.equivalenceKey(value));
  }

  bool containsDescendantOrEqual(String value) {
    final key = PathMatcher.equivalenceKey(value);
    if (_keys.contains(key)) return true;
    final prefix = '$key/';
    var low = 0;
    var high = _sortedKeys.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (_sortedKeys[middle].compareTo(prefix) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low < _sortedKeys.length && _sortedKeys[low].startsWith(prefix);
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
