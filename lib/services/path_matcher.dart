import 'package:path/path.dart' as path;

abstract final class PathMatcher {
  static bool isContentUri(String value) => value.startsWith('content://');

  static String normalize(String value) {
    return isContentUri(value) ? value : path.normalize(value);
  }

  static bool equalsNormalized(String first, String second) {
    if (isContentUri(first) || isContentUri(second)) {
      return normalize(first) == normalize(second);
    }
    return path.equals(normalize(first), normalize(second));
  }

  static bool isWithinOrEqual(String child, String parent) {
    final normalizedChild = normalize(child);
    final normalizedParent = normalize(parent);
    if (isContentUri(normalizedChild) || isContentUri(normalizedParent)) {
      return normalizedChild == normalizedParent ||
          normalizedChild.startsWith('$normalizedParent/');
    }
    return path.equals(normalizedChild, normalizedParent) ||
        path.isWithin(normalizedParent, normalizedChild);
  }
}
