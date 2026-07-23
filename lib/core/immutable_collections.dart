import 'dart:collection';

List<T> immutableList<T>(Iterable<T> values) {
  if (values is UnmodifiableListView<T>) return values;
  return UnmodifiableListView<T>(List<T>.of(values, growable: false));
}

Map<K, V> immutableMap<K, V>(Map<K, V> values) {
  if (values is UnmodifiableMapView<K, V>) return values;
  return UnmodifiableMapView<K, V>(Map<K, V>.of(values));
}

Set<T> immutableSet<T>(Iterable<T> values) {
  if (values is UnmodifiableSetView<T>) return values;
  return UnmodifiableSetView<T>(Set<T>.of(values));
}

Map<String, Object?>? immutableJsonMap(Map<String, Object?>? values) {
  if (values == null) return null;
  if (values is UnmodifiableMapView<String, Object?>) return values;
  return UnmodifiableMapView<String, Object?>(<String, Object?>{
    for (final entry in values.entries)
      entry.key: deepFreezeJsonValue(entry.value),
  });
}

Object? deepFreezeJsonValue(Object? value) {
  if (value is UnmodifiableListView<Object?> ||
      value is UnmodifiableMapView<Object?, Object?> ||
      value is UnmodifiableSetView<Object?>) {
    return value;
  }
  if (value is List) {
    return UnmodifiableListView<Object?>(
      value.map<Object?>(deepFreezeJsonValue).toList(growable: false),
    );
  }
  if (value is Map) {
    return UnmodifiableMapView<Object?, Object?>(<Object?, Object?>{
      for (final entry in value.entries)
        entry.key: deepFreezeJsonValue(entry.value),
    });
  }
  if (value is Set) {
    return UnmodifiableSetView<Object?>(
      value.map<Object?>(deepFreezeJsonValue).toSet(),
    );
  }
  return value;
}
