List<String> stringListFromSortMetadata(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .map((item) => item.toString().trim())
      .where((item) {
        return item.isNotEmpty;
      })
      .toList(growable: false);
}

DateTime? dateTimeFromSortMetadata(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

int compareOptionalSortValues<T>(
  T? left,
  T? right,
  int Function(T left, T right) compare,
) {
  if (left == null && right == null) return 0;
  if (left == null) return 1;
  if (right == null) return -1;
  return compare(left, right);
}

int compareOptionalSortStrings(String? left, String? right) {
  final normalizedLeft = left?.trim();
  final normalizedRight = right?.trim();
  return compareOptionalSortValues(
    normalizedLeft?.isEmpty == true ? null : normalizedLeft,
    normalizedRight?.isEmpty == true ? null : normalizedRight,
    (a, b) => a.compareTo(b),
  );
}
