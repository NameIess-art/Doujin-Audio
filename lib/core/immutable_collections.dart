import 'dart:collection';

List<T> immutableList<T>(Iterable<T> values) {
  if (values is _ImmutableListSnapshot<T>) return values;
  return _ImmutableListSnapshot<T>(values);
}

Map<K, V> immutableMap<K, V>(Map<K, V> values) {
  if (values is _ImmutableMapSnapshot<K, V>) return values;
  return _ImmutableMapSnapshot<K, V>(values);
}

Set<T> immutableSet<T>(Iterable<T> values) {
  if (values is _ImmutableSetSnapshot<T>) return values;
  return _ImmutableSetSnapshot<T>(values);
}

Map<String, Object?>? immutableJsonMap(Map<String, Object?>? values) {
  if (values == null) return null;
  if (values is _ImmutableJsonMap) return values;
  return _ImmutableJsonMap(values);
}

Object? deepFreezeJsonValue(Object? value) {
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

final class _ImmutableListSnapshot<T> extends UnmodifiableListView<T> {
  _ImmutableListSnapshot(Iterable<T> values)
    : super(List<T>.of(values, growable: false));
}

final class _ImmutableMapSnapshot<K, V> extends UnmodifiableMapView<K, V> {
  _ImmutableMapSnapshot(Map<K, V> values) : super(Map<K, V>.of(values));
}

final class _ImmutableSetSnapshot<T> extends UnmodifiableSetView<T> {
  _ImmutableSetSnapshot(Iterable<T> values) : super(Set<T>.of(values));
}

final class _ImmutableJsonMap extends UnmodifiableMapView<String, Object?> {
  _ImmutableJsonMap(Map<String, Object?> values)
    : super(<String, Object?>{
        for (final entry in values.entries)
          entry.key: deepFreezeJsonValue(entry.value),
      });
}
