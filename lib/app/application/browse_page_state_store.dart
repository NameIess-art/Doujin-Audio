/// Root-page display state for the current application run only.
/// Media, user preferences and playback remain feature-owned.
final class BrowsePageStateStore {
  final Map<String, Map<String, Object?>> _pages = {};
  int _epoch = 0;

  int get epoch => _epoch;
  Map<String, Object?> stateFor(String key) =>
      Map.unmodifiable(_pages[key] ?? const {});

  void update(String key, Map<String, Object?> patch, {int? epoch}) {
    if (epoch != null && epoch != _epoch) return;
    _pages[key] = {...?_pages[key], ...patch};
  }

  void clear() {
    _epoch++;
    _pages.clear();
  }
}
