import 'dart:collection';

/// Root-page display state for the current application run only.
/// Media, user preferences and playback remain feature-owned.
final class BrowsePageStateStore {
  final Map<String, Map<String, Object?>> _pages = {};
  int _epoch = 0;

  int get epoch => _epoch;
  Map<String, Object?> stateFor(String key) => _pages[key] ?? const {};

  void update(String key, Map<String, Object?> patch, {int? epoch}) {
    if ((epoch != null && epoch != _epoch) || patch.isEmpty) return;
    final previous = _pages[key];
    if (previous != null &&
        patch.entries.every(
          (entry) =>
              previous[entry.key] == entry.value &&
              (entry.value != null || previous.containsKey(entry.key)),
        )) {
      return;
    }
    _pages[key] = UnmodifiableMapView({...?previous, ...patch});
  }

  void clear() {
    _epoch++;
    _pages.clear();
  }
}
