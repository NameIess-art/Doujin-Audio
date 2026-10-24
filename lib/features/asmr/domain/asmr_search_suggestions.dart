/// Bounded search suggestions in the popularity order supplied by Eara.
class AsmrSearchSuggestions {
  AsmrSearchSuggestions({
    required List<String> voiceActors,
    required List<String> tags,
  }) : voiceActors = _normalize(voiceActors),
       tags = _normalize(tags);

  static const displayLimit = 30;

  final List<String> voiceActors;
  final List<String> tags;

  factory AsmrSearchSuggestions.fromJson(Map<String, dynamic> json) =>
      AsmrSearchSuggestions(
        voiceActors: _readTerms(json['hotCvs']),
        tags: _readTerms(json['hotTags']),
      );

  Map<String, dynamic> toJson() => {
    'hotCvs': [
      for (final value in voiceActors) {'value': value},
    ],
    'hotTags': [
      for (final value in tags) {'value': value},
    ],
  };

  static List<String> _normalize(List<String> values) {
    final terms = <String>{};
    for (final value in values) {
      final term = value.trim();
      if (term.isNotEmpty) terms.add(term);
      if (terms.length == displayLimit) break;
    }
    return List<String>.unmodifiable(terms);
  }

  static List<String> _readTerms(Object? raw) {
    if (raw is! List) {
      throw const FormatException('Invalid Eara search suggestions list.');
    }
    final terms = <String>{};
    for (final item in raw) {
      if (item is! Map || item['value'] is! String) {
        throw const FormatException('Invalid Eara search suggestion.');
      }
      final value = (item['value'] as String).trim();
      if (value.isEmpty) {
        throw const FormatException('Empty Eara search suggestion.');
      }
      terms.add(value);
      if (terms.length == displayLimit) break;
    }
    return terms.toList(growable: false);
  }
}
