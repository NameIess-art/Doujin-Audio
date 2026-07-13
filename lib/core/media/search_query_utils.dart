final RegExp _searchQueryDelimiterPattern = RegExp(r'[,/\uFF0C]+');
final RegExp _searchQueryWhitespacePattern = RegExp(r'\s+');

List<String> splitSearchTerms(String query) {
  return query
      .split(_searchQueryDelimiterPattern)
      .map((term) => term.replaceAll(_searchQueryWhitespacePattern, ' ').trim())
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
}

List<String> extractSearchTerms(String query) {
  final normalizedQuery = query
      .replaceAll(_searchQueryWhitespacePattern, ' ')
      .trim();
  if (normalizedQuery.isEmpty) {
    return const <String>[];
  }
  if (!_searchQueryDelimiterPattern.hasMatch(query)) {
    return <String>[normalizedQuery];
  }
  return splitSearchTerms(query);
}

String normalizeSearchQuery(String query) {
  return extractSearchTerms(query).join(' ');
}

bool matchesSearchTerms(
  Iterable<String> haystacks,
  String query, {
  List<String>? terms,
}) {
  final effectiveTerms = terms ?? extractSearchTerms(query);
  if (effectiveTerms.isEmpty) {
    return true;
  }
  final normalizedTerms = effectiveTerms
      .map(
        (term) => term
            .replaceAll(_searchQueryWhitespacePattern, ' ')
            .trim()
            .toLowerCase(),
      )
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  final mergedHaystack = haystacks
      .map(
        (value) => value
            .replaceAll(_searchQueryWhitespacePattern, ' ')
            .trim()
            .toLowerCase(),
      )
      .join('\n');
  return normalizedTerms.every(mergedHaystack.contains);
}
