import 'package:path/path.dart' as path;

abstract final class PathMatcher {
  static final RegExp _invalidPercentEscape = RegExp(r'%(?![0-9A-Fa-f]{2})');
  static final path.Context _windowsContext = path.Context(
    style: path.Style.windows,
  );
  static final int _filePrefixHash = _hashSeed('file:');
  static final int _windowsPrefixHash = _hashSeed('windows:');

  static bool _hasHttpSchemePrefix(String value) {
    final len = value.length;
    if (len < 5) return false;
    final c0 = value.codeUnitAt(0) | 0x20;
    if (c0 != 0x68) return false; // 'h'
    if ((value.codeUnitAt(1) | 0x20) != 0x74) return false; // 't'
    if ((value.codeUnitAt(2) | 0x20) != 0x74) return false; // 't'
    if ((value.codeUnitAt(3) | 0x20) != 0x70) return false; // 'p'
    final c4 = value.codeUnitAt(4);
    if (c4 == 0x3A) return true; // ':'
    return len >= 6 &&
        (c4 | 0x20) == 0x73 && // 's'
        value.codeUnitAt(5) == 0x3A; // ':'
  }

  static bool _isWindowsAbsolutePath(String value) {
    final len = value.length;
    if (len < 2) return false;
    final c0 = value.codeUnitAt(0);
    final c1 = value.codeUnitAt(1);
    if (c0 == 0x5C && c1 == 0x5C) return true; // '\\'
    if (len < 3 || c1 != 0x3A) return false; // ':'
    final isAsciiLetter =
        (c0 >= 0x41 && c0 <= 0x5A) || (c0 >= 0x61 && c0 <= 0x7A);
    if (!isAsciiLetter) return false;
    final c2 = value.codeUnitAt(2);
    return c2 == 0x5C || c2 == 0x2F;
  }

  static bool isContentUri(String value) => value.startsWith('content://');

  /// Confirms the grant encoded in a document URI, not its parent directory.
  static bool hasSameContentTree(String document, String root) {
    if (!isContentUri(document) ||
        !isContentUri(root) ||
        _contentAuthority(document) != _contentAuthority(root)) {
      return false;
    }
    final documentTree = contentPathSegmentAfter(
      document.split('::').first,
      'tree',
    );
    final rootTree = contentPathSegmentAfter(root.split('::').first, 'tree');
    return documentTree != null &&
        rootTree != null &&
        safeDecodeComponent(documentTree) == safeDecodeComponent(rootTree);
  }

  static bool isRemoteUri(String value) =>
      _hasHttpSchemePrefix(value) && Uri.tryParse(value) != null;

  static String safeDecodeComponent(String value) {
    if (!value.contains('%')) return value;
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

  static String trimRightSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static String normalize(String value) {
    if (isContentUri(value) || isRemoteUri(value)) {
      return trimRightSlash(value);
    }
    return _contextFor(value).normalize(value);
  }

  static bool equalsNormalized(String first, String second) {
    if (isRemoteUri(first) || isRemoteUri(second)) {
      return normalize(first) == normalize(second);
    }
    if (isContentUri(first) || isContentUri(second)) {
      if (!isContentUri(first) ||
          !isContentUri(second) ||
          _contentAuthority(first) != _contentAuthority(second)) {
        return false;
      }
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
    final fast = _tryFastEquivalenceKey(value);
    if (fast != null) return fast;
    if (isRemoteUri(value)) return 'remote:${trimRightSlash(value)}';

    final context = isContentUri(value) ? null : _contextFor(value);
    final normalized = context?.normalize(value) ?? trimRightSlash(value);
    if (isContentUri(normalized)) {
      return 'content:${_contentAuthority(normalized)}:${_documentPath(normalized) ?? normalized}';
    }
    // Normalizing a relative path can expose a scheme or a drive prefix.
    if (normalized != value && isRemoteUri(normalized)) {
      return 'remote:$normalized';
    }
    final canonical = normalized.replaceAll('\\', '/');
    final windows = normalized == value
        ? identical(context, _windowsContext)
        : _isWindowsAbsolutePath(normalized);
    return windows ? 'windows:${canonical.toLowerCase()}' : 'file:$canonical';
  }

  static String? _tryFastEquivalenceKey(String value) {
    final fast = _classifyFastEquivalence(value);
    if (fast < 0) return null;
    final end = fast >> 1;
    if ((fast & 1) == 0) {
      return end == value.length
          ? 'file:$value'
          : 'file:${value.substring(0, end)}';
    }
    final sliced = end == value.length ? value : value.substring(0, end);
    return 'windows:${sliced.replaceAll('\\', '/').toLowerCase()}';
  }

  static int _hashCombine(int hash, int codeUnit) {
    hash = 0x1fffffff & (hash + codeUnit);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int _hashFinish(int hash) {
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }

  static int _hashSeed(String prefix) {
    var hash = 0;
    for (var i = 0; i < prefix.length; i++) {
      hash = _hashCombine(hash, prefix.codeUnitAt(i));
    }
    return hash;
  }

  static int _hashString(String value) {
    var hash = 0;
    for (var i = 0; i < value.length; i++) {
      hash = _hashCombine(hash, value.codeUnitAt(i));
    }
    return _hashFinish(hash);
  }

  /// Classifies clean absolute POSIX or Windows paths without allocating.
  ///
  /// Returns `-1` when normalization or Unicode case-folding fallback is needed.
  /// Otherwise returns `(effectiveEnd << 1) | kind`, where `kind == 0` is POSIX
  /// (`file:`) and `kind == 1` is Windows (`windows:`).
  static int _classifyFastEquivalence(String value) {
    final len = value.length;
    if (len == 0) return -1;
    final c0 = value.codeUnitAt(0);

    // Clean POSIX absolute paths `/...` (not starting with `//`).
    if (c0 == 0x2F) {
      if (len == 1) return 1 << 1;
      if (value.codeUnitAt(1) == 0x2F) return -1;
      final effectiveEnd = value.codeUnitAt(len - 1) == 0x2F ? len - 1 : len;
      if (effectiveEnd <= 1) return -1;
      var segStart = 1;
      for (var i = 1; i < effectiveEnd; i++) {
        final c = value.codeUnitAt(i);
        if (c == 0x5C) return -1;
        if (c == 0x2F) {
          final segLen = i - segStart;
          if (segLen == 0 ||
              (segLen == 1 && value.codeUnitAt(segStart) == 0x2E) ||
              (segLen == 2 &&
                  value.codeUnitAt(segStart) == 0x2E &&
                  value.codeUnitAt(segStart + 1) == 0x2E)) {
            return -1;
          }
          segStart = i + 1;
        }
      }
      final lastLen = effectiveEnd - segStart;
      if (lastLen == 0 ||
          (lastLen == 1 && value.codeUnitAt(segStart) == 0x2E) ||
          (lastLen == 2 &&
              value.codeUnitAt(segStart) == 0x2E &&
              value.codeUnitAt(segStart + 1) == 0x2E)) {
        return -1;
      }
      return effectiveEnd << 1;
    }

    // Clean Windows drive paths `X:\...` or `X:/...`.
    if (len >= 3 &&
        value.codeUnitAt(1) == 0x3A &&
        ((c0 >= 0x41 && c0 <= 0x5A) || (c0 >= 0x61 && c0 <= 0x7A))) {
      final c2 = value.codeUnitAt(2);
      if (c2 != 0x5C && c2 != 0x2F) return -1;
      if (len == 3) return (3 << 1) | 1;
      final lastChar = value.codeUnitAt(len - 1);
      final effectiveEnd = (lastChar == 0x5C || lastChar == 0x2F)
          ? len - 1
          : len;
      if (effectiveEnd <= 3) return -1;
      var segStart = 3;
      for (var i = 3; i < effectiveEnd; i++) {
        final c = value.codeUnitAt(i);
        // Non-ASCII characters outside CJK/Hangul may fold under toLowerCase().
        if (c >= 0x80 &&
            !(c >= 0x3000 && c <= 0x9FFF) &&
            !(c >= 0xAC00 && c <= 0xD7AF)) {
          return -1;
        }
        if (c == 0x5C || c == 0x2F) {
          final segLen = i - segStart;
          if (segLen == 0 ||
              (segLen == 1 && value.codeUnitAt(segStart) == 0x2E) ||
              (segLen == 2 &&
                  value.codeUnitAt(segStart) == 0x2E &&
                  value.codeUnitAt(segStart + 1) == 0x2E)) {
            return -1;
          }
          segStart = i + 1;
        }
      }
      final lastLen = effectiveEnd - segStart;
      if (lastLen == 0 ||
          (lastLen == 1 && value.codeUnitAt(segStart) == 0x2E) ||
          (lastLen == 2 &&
              value.codeUnitAt(segStart) == 0x2E &&
              value.codeUnitAt(segStart + 1) == 0x2E)) {
        return -1;
      }
      return (effectiveEnd << 1) | 1;
    }

    return -1;
  }

  /// Allocation-free hash consistent with [equivalenceEquals] and [equivalenceKey].
  static int equivalenceHashCode(String value) {
    final fast = _classifyFastEquivalence(value);
    if (fast >= 0) {
      final end = fast >> 1;
      if ((fast & 1) == 0) {
        var hash = _filePrefixHash;
        for (var i = 0; i < end; i++) {
          hash = _hashCombine(hash, value.codeUnitAt(i));
        }
        return _hashFinish(hash);
      }
      var hash = _windowsPrefixHash;
      for (var i = 0; i < end; i++) {
        var c = value.codeUnitAt(i);
        if (c == 0x5C) {
          c = 0x2F;
        } else if (c >= 0x41 && c <= 0x5A) {
          c += 0x20;
        }
        hash = _hashCombine(hash, c);
      }
      return _hashFinish(hash);
    }
    return _hashString(equivalenceKey(value));
  }

  /// Allocation-free equivalence check matching `equivalenceKey(first) == equivalenceKey(second)`.
  static bool equivalenceEquals(String first, String second) {
    if (identical(first, second)) return true;
    final firstFast = _classifyFastEquivalence(first);
    final secondFast = _classifyFastEquivalence(second);
    if (firstFast >= 0 && secondFast >= 0) {
      final kind = firstFast & 1;
      if (kind != (secondFast & 1)) return false;
      final end = firstFast >> 1;
      if (end != (secondFast >> 1)) return false;
      if (kind == 0) {
        if (end == first.length && end == second.length) {
          return first == second;
        }
        for (var i = 0; i < end; i++) {
          if (first.codeUnitAt(i) != second.codeUnitAt(i)) return false;
        }
        return true;
      }
      for (var i = 0; i < end; i++) {
        var a = first.codeUnitAt(i);
        if (a == 0x5C) {
          a = 0x2F;
        } else if (a >= 0x41 && a <= 0x5A) {
          a += 0x20;
        }
        var b = second.codeUnitAt(i);
        if (b == 0x5C) {
          b = 0x2F;
        } else if (b >= 0x41 && b <= 0x5A) {
          b += 0x20;
        }
        if (a != b) return false;
      }
      return true;
    }
    return equivalenceKey(first) == equivalenceKey(second);
  }

  static String parentEquivalenceKey(String value) {
    final normalized = normalize(value);
    if (isContentUri(normalized)) {
      final documentPath = _documentPath(normalized);
      if (documentPath != null) {
        final separator = documentPath.lastIndexOf('/');
        final String parent;
        if (separator >= 0) {
          parent = documentPath.substring(0, separator);
        } else {
          final colon = documentPath.indexOf(':');
          parent = colon >= 0
              ? documentPath.substring(0, colon + 1)
              : documentPath;
        }
        return 'content:${_contentAuthority(normalized)}:$parent';
      }
      final uri = Uri.tryParse(normalized);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        return 'content:${_contentAuthority(normalized)}:${uri.replace(pathSegments: uri.pathSegments.sublist(0, uri.pathSegments.length - 1))}';
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

  static String? parentPath(String value) {
    final normalized = normalize(value);
    if (isRemoteUri(normalized)) return null;
    if (isContentUri(normalized)) {
      final markerIndex = normalized.indexOf('::');
      if (markerIndex >= 0) {
        final base = normalized.substring(0, markerIndex);
        final relative = trimRightSlash(normalized.substring(markerIndex + 2));
        if (relative.isEmpty) return null;
        final lastSlash = relative.lastIndexOf('/');
        if (lastSlash < 0) {
          return normalize(base);
        }
        final parentRelative = relative.substring(0, lastSlash);
        return parentRelative.isEmpty
            ? normalize(base)
            : '${normalize(base)}::$parentRelative';
      }

      final treeBase = _treeUriBase(normalized);
      final docPath = _documentPath(normalized);
      if (treeBase != null && docPath != null) {
        final treeDocId = _documentPath(treeBase);
        final relative = treeDocId == null
            ? null
            : _relativeDocPath(docPath, treeDocId);
        if (relative != null && relative.isNotEmpty) {
          final lastSlash = relative.lastIndexOf('/');
          if (lastSlash < 0) {
            return normalize(treeBase);
          }
          final parentRelative = relative.substring(0, lastSlash);
          return parentRelative.isEmpty
              ? normalize(treeBase)
              : '${normalize(treeBase)}::$parentRelative';
        }
      }
      return null;
    }
    final context = _contextFor(normalized);
    final directoryPath = context.dirname(normalized);
    if (directoryPath.isEmpty ||
        directoryPath == '.' ||
        context.equals(directoryPath, normalized)) {
      return null;
    }
    return directoryPath;
  }

  static bool isWithinOrEqual(String child, String parent) {
    return isWithinOrEqualNormalized(normalize(child), normalize(parent));
  }

  static bool isWithinOrEqualNormalized(
    String normalizedChild,
    String normalizedParent,
  ) {
    if (isRemoteUri(normalizedChild) || isRemoteUri(normalizedParent)) {
      return normalizedChild == normalizedParent;
    }
    if (isContentUri(normalizedChild) || isContentUri(normalizedParent)) {
      if (!isContentUri(normalizedChild) ||
          !isContentUri(normalizedParent) ||
          _contentAuthority(normalizedChild) !=
              _contentAuthority(normalizedParent)) {
        return false;
      }
      final childDoc = _documentPath(normalizedChild);
      final parentDoc = _documentPath(normalizedParent);
      if (childDoc != null && parentDoc != null) {
        return _relativeDocPath(childDoc, parentDoc) != null;
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
      if (childDoc == null || parentDoc == null) {
        return null;
      }
      return _relativeDocPath(childDoc, parentDoc);
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
    if (isContentUri(parent)) {
      return _joinContentUri(parent, child);
    }
    final context = _contextFor(parent);
    return context.normalize(context.join(parent, child));
  }

  static String _joinContentUri(String parent, String child) {
    final normalizedParent = normalize(parent);
    final sanitizedChild = child.replaceAll('\\', '/').trim();
    final relativeChild = sanitizedChild.trimLeftSlash().trimRightSlash();
    if (relativeChild.isEmpty || relativeChild == '.') {
      return normalizedParent;
    }
    final normalizedChild = path.posix.normalize(relativeChild);
    if (normalizedChild.isEmpty || normalizedChild == '.') {
      return normalizedParent;
    }
    final markerIndex = normalizedParent.indexOf('::');
    if (markerIndex >= 0) {
      final base = normalize(normalizedParent.substring(0, markerIndex));
      final existingRelative = normalizedParent
          .substring(markerIndex + 2)
          .replaceAll('\\', '/')
          .trimLeftSlash()
          .trimRightSlash();
      final combined = existingRelative.isEmpty
          ? normalizedChild
          : path.posix.normalize(
              path.posix.join(existingRelative, normalizedChild),
            );
      if (combined.isEmpty || combined == '.') {
        return base;
      }
      return '$base::$combined';
    }
    return _appendSyntheticRelative(normalizedParent, normalizedChild);
  }

  static path.Context _contextFor(
    String first, [
    String? second,
    String? third,
  ]) {
    if (_isWindowsAbsolutePath(first) ||
        (second != null && _isWindowsAbsolutePath(second)) ||
        (third != null && _isWindowsAbsolutePath(third))) {
      return _windowsContext;
    }
    return path.context;
  }

  static String _contentAuthority(String value) =>
      Uri.tryParse(value)?.authority.toLowerCase() ?? '';

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
    if (oldDoc == null || newDoc == null || valueDoc == null) {
      return value;
    }
    final suffix = _relativeDocPath(valueDoc, oldDoc);
    if (suffix == null) {
      return value;
    }

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
    final normalized = safeDecodeComponent(
      rawId,
    ).replaceAll('\\', '/').trimRightSlash();
    final colonIndex = normalized.indexOf(':');
    if (colonIndex > 0 &&
        !normalized.startsWith('raw:/') &&
        colonIndex + 1 < normalized.length &&
        normalized[colonIndex + 1] == '/') {
      final afterColon = normalized.substring(colonIndex + 1).trimLeftSlash();
      return '${normalized.substring(0, colonIndex + 1)}$afterColon';
    }
    return normalized;
  }

  static String? _relativeDocPath(String childDoc, String parentDoc) {
    if (childDoc == parentDoc) return '';
    if (parentDoc.endsWith(':')) {
      if (!childDoc.startsWith(parentDoc) ||
          childDoc.length == parentDoc.length) {
        return null;
      }
      final relative = childDoc.substring(parentDoc.length);
      return relative.startsWith('/') ? relative.substring(1) : relative;
    }
    if (childDoc.startsWith('$parentDoc/')) {
      return childDoc.substring(parentDoc.length + 1);
    }
    return null;
  }

  static String _joinDocumentPath(String basePath, String? relativePath) {
    final relative = relativePath?.trimLeftSlash();
    if (relative == null || relative.isEmpty) return basePath;
    if (basePath.endsWith(':')) return '$basePath$relative';
    return '$basePath/$relative';
  }
}

final class PathMembershipIndex {
  PathMembershipIndex(Iterable<String> paths)
    : _keys = paths.map(PathMatcher.equivalenceKey).toSet();

  final Set<String> _keys;
  late final List<String> _sortedKeys = _keys.toList(growable: false)..sort();

  bool containsEquivalent(String value) {
    return _keys.contains(PathMatcher.equivalenceKey(value));
  }

  bool containsDescendantOrEqual(String value) {
    final key = PathMatcher.equivalenceKey(value);
    if (_keys.contains(key)) return true;
    final prefix =
        key.endsWith('/') || (key.startsWith('content:') && key.endsWith(':'))
        ? key
        : '$key/';
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

  bool containsAncestorOrEqual(String value) {
    var key = PathMatcher.equivalenceKey(value);
    if (_keys.contains(key)) return true;
    if (key.startsWith('remote:')) return false;
    while (true) {
      final separator = key.lastIndexOf('/');
      if (separator < 0) {
        if (key.startsWith('content:')) {
          final authorityEnd = key.indexOf(':', 'content:'.length);
          if (authorityEnd >= 0 &&
              !key.startsWith('content://', authorityEnd + 1)) {
            final rootColon = key.indexOf(':', authorityEnd + 1);
            if (rootColon >= 0 &&
                rootColon + 1 < key.length &&
                _keys.contains(key.substring(0, rootColon + 1))) {
              return true;
            }
          }
        }
        return false;
      }
      // File-system roots retain their trailing separator in equivalence keys.
      if (_keys.contains(key.substring(0, separator + 1))) return true;
      key = key.substring(0, separator);
      if (_keys.contains(key)) return true;
    }
  }
}

/// Maps path equivalence keys to their original roots for O(depth) ancestor lookup.
final class PathRootIndex {
  PathRootIndex(Iterable<String> roots) {
    for (final root in roots) {
      if (root.isEmpty) continue;
      final key = PathMatcher.equivalenceKey(root);
      if (key.startsWith('remote:')) continue;
      final opaqueContent =
          key.startsWith('content:') && key.contains(':content://');
      final relativeFile = key.startsWith('file:') && !key.startsWith('file:/');
      if (opaqueContent || relativeFile) {
        _fallbackRoots.add(root);
        continue;
      }
      final existing = _byKey[key];
      if (existing == null || root.length > existing.length) {
        _byKey[key] = root;
      }
    }
  }

  final Map<String, String> _byKey = <String, String>{};
  final List<String> _fallbackRoots = <String>[];

  bool get isEmpty => _byKey.isEmpty && _fallbackRoots.isEmpty;

  bool containsEquivalent(String value) {
    if (isEmpty || value.isEmpty) return false;
    final key = PathMatcher.equivalenceKey(value);
    if (_byKey.containsKey(key)) return true;
    for (final root in _fallbackRoots) {
      if (PathMatcher.equalsNormalized(value, root)) return true;
    }
    return false;
  }

  String? mostSpecificContaining(String value) {
    if (isEmpty || value.isEmpty) return null;
    final key = PathMatcher.equivalenceKey(value);
    if (key.startsWith('remote:')) return null;
    String? best;
    if (_byKey.isNotEmpty) {
      var current = key;
      if (_byKey[current] case final match?) {
        best = match;
      } else {
        while (true) {
          final separator = current.lastIndexOf('/');
          if (separator < 0) {
            if (current.startsWith('content:')) {
              final authorityEnd = current.indexOf(':', 'content:'.length);
              if (authorityEnd >= 0 &&
                  !current.startsWith('content://', authorityEnd + 1)) {
                final rootColon = current.indexOf(':', authorityEnd + 1);
                if (rootColon >= 0 && rootColon + 1 < current.length) {
                  final match = _byKey[current.substring(0, rootColon + 1)];
                  if (match != null) best = match;
                }
              }
            }
            break;
          }
          final withSlash = _byKey[current.substring(0, separator + 1)];
          if (withSlash != null) {
            best = withSlash;
            break;
          }
          current = current.substring(0, separator);
          final withoutSlash = _byKey[current];
          if (withoutSlash != null) {
            best = withoutSlash;
            break;
          }
        }
      }
    }
    for (final root in _fallbackRoots) {
      if (best != null && root.length <= best.length) continue;
      if (PathMatcher.isWithinOrEqual(value, root)) {
        best = root;
      }
    }
    return best;
  }
}

extension _TrimSlash on String {
  String trimRightSlash() => PathMatcher.trimRightSlash(this);

  String trimLeftSlash() {
    var result = this;
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    return result;
  }
}
