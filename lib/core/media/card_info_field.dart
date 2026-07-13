enum CardInfoField {
  rjCode,
  voiceActors,
  circleName,
  tags,
  releaseDate,
  salesCount,
  rating;

  static const int maxSelected = 6;
  static const int maxDisplayRows = 6;

  static const List<CardInfoField> defaults = <CardInfoField>[
    rjCode,
    voiceActors,
    circleName,
    tags,
  ];

  static CardInfoField? fromName(String value) {
    for (final field in values) {
      if (field.name == value) return field;
    }
    return null;
  }

  static List<CardInfoField> normalize(Iterable<CardInfoField> fields) {
    final seen = <CardInfoField>{};
    final result = <CardInfoField>[];
    for (final field in fields) {
      if (!seen.add(field)) continue;
      result.add(field);
      if (result.length >= maxSelected) break;
    }
    return List<CardInfoField>.unmodifiable(result);
  }

  static int tagLineCountForSelection(int selectedFieldCount) {
    return (maxDisplayRows - selectedFieldCount + 1).clamp(1, maxDisplayRows);
  }

  static List<CardInfoField> decode(Object? value) {
    if (value is! List) return defaults;
    final fields = value
        .whereType<String>()
        .map(fromName)
        .whereType<CardInfoField>();
    return normalize(fields);
  }
}
