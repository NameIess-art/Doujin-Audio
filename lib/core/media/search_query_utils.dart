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

/// Retains phrase boundaries for AND matching and removes duplicate conditions.
String canonicalSearchQuery(String query) {
  final seen = <String>{};
  return extractSearchTerms(
    query,
  ).where((term) => seen.add(term.toLowerCase())).join(', ');
}

List<String> normalizedSearchTerms(String query) => extractSearchTerms(
  query,
).map((term) => term.toLowerCase()).toList(growable: false);

typedef SearchElements = ({List<String> all, List<String> any});

const SearchElements emptySearchElements = (all: [], any: []);

bool matchesSearchTerms(
  Iterable<String> haystacks,
  String query, {
  List<String>? normalizedTerms,
  List<String> normalizedAnyTerms = const [],
}) {
  final effectiveTerms = normalizedTerms ?? normalizedSearchTerms(query);
  if (effectiveTerms.isEmpty && normalizedAnyTerms.isEmpty) {
    return true;
  }
  final mergedHaystack = haystacks
      .map(
        (value) => value
            .replaceAll(_searchQueryWhitespacePattern, ' ')
            .trim()
            .toLowerCase(),
      )
      .join('\n');
  return effectiveTerms.every(mergedHaystack.contains) &&
      (normalizedAnyTerms.isEmpty ||
          normalizedAnyTerms.any(mergedHaystack.contains));
}

final _elementSeparator = RegExp(r'[,/，、]');
final _elementEscape = RegExp(r'[\\(),/（），、]');

String _escapeElement(String term) =>
    term.replaceAllMapped(_elementEscape, (match) => '\\${match[0]}');

String formatSearchElements(SearchElements elements) => [
  elements.all.map(_escapeElement).join(', '),
  elements.any.map((term) => '（${_escapeElement(term)}）').join(),
].where((group) => group.isNotEmpty).join(' ');

String legacySearchElements(String value) => formatSearchElements((
  all: extractSearchTerms(canonicalSearchQuery(value)),
  any: const [],
));

SearchElements? parseSearchElements(String input) {
  final all = <String>[];
  final any = <String>[];
  final buffer = StringBuffer();
  String? close;
  var escaped = false;
  String take() {
    final term = buffer
        .toString()
        .replaceAll(_searchQueryWhitespacePattern, ' ')
        .trim();
    buffer.clear();
    return term;
  }

  void add(List<String> group, String term) {
    if (term.isNotEmpty &&
        !group.any((item) => item.toLowerCase() == term.toLowerCase())) {
      group.add(term);
    }
  }

  for (final char in input.split('')) {
    if (escaped) {
      if (!_elementEscape.hasMatch(char)) buffer.write('\\');
      buffer.write(char);
      escaped = false;
    } else if (char == '\\') {
      escaped = true;
    } else if (char == '(' || char == '（') {
      if (close != null) return null;
      add(all, take());
      close = char == '(' ? ')' : '）';
    } else if (char == ')' || char == '）') {
      if (close != char) return null;
      final term = take();
      if (term.isEmpty) return null;
      add(any, term);
      close = null;
    } else if (close == null && _elementSeparator.hasMatch(char)) {
      add(all, take());
    } else {
      buffer.write(char);
    }
  }
  if (close != null) return null;
  if (escaped) buffer.write('\\');
  add(all, take());
  return (all: all, any: any);
}

String canonicalElementQuery(String query) {
  final elements = parseSearchElements(query);
  return elements == null ? '' : formatSearchElements(elements);
}

String toggleSearchElement(
  SearchElements elements,
  String term, {
  required bool matchAll,
}) {
  final all = [...elements.all];
  final any = [...elements.any];
  final active = matchAll ? all : any;
  bool same(String item) => item.toLowerCase() == term.toLowerCase();
  final selected = active.any(same);
  all.removeWhere(same);
  any.removeWhere(same);
  if (!selected) active.add(term);
  return formatSearchElements((all: all, any: any));
}

List<String> searchElementBranches(String query) {
  final elements = parseSearchElements(query);
  if (elements == null || elements.any.isEmpty) return [query];
  return [
    for (final term in elements.any)
      formatSearchElements((all: [...elements.all, term], any: const [])),
  ];
}

String searchElementKeyword(String query) =>
    parseSearchElements(query)?.all.join(' ') ?? normalizeSearchQuery(query);

String searchElementHighlight(String query) {
  final elements = parseSearchElements(query);
  return elements == null
      ? query
      : [...elements.all, ...elements.any].join(', ');
}
