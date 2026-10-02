import 'dart:convert';

import '../../core/logging/app_log_service.dart';
import '../../core/persistence/app_database.dart';

/// Committed display state only. Media and playback remain feature-owned.
final class BrowsePageStateStore {
  BrowsePageStateStore({
    Future<String?> Function()? read,
    Future<void> Function(String?)? write,
    bool persistent = true,
  }) : _read = read ?? (() => AppDatabase.instance.loadAppSetting(_setting)),
       _write =
           write ??
           ((value) => AppDatabase.instance.saveAppSetting(_setting, value)),
       _persistent = persistent;

  static const _setting = 'browse_page_state_v1';
  final Future<String?> Function() _read;
  final Future<void> Function(String?) _write;
  final bool _persistent;
  final Map<String, Map<String, Object?>> _pages = {};
  Future<void>? _initialization;
  Future<void> _tail = Future<void>.value();
  bool _writeScheduled = false;
  int _epoch = 0;

  int get epoch => _epoch;
  Map<String, Object?> stateFor(String key) =>
      Map.unmodifiable(_pages[key] ?? const {});

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!_persistent) return;
    final epoch = _epoch;
    try {
      final text = await _read();
      if (text == null || epoch != _epoch) return;
      final value = jsonDecode(text);
      if (value is! Map || value['version'] != 1 || value['pages'] is! Map) {
        return;
      }
      for (final entry in (value['pages'] as Map).entries) {
        if (entry.key is String && entry.value is Map) {
          final restored = Map<String, Object?>.from(entry.value as Map);
          // Interaction during startup takes precedence over disk state.
          _pages[entry.key as String] = {...restored, ...?_pages[entry.key]};
        }
      }
    } catch (error, stackTrace) {
      _log('browse_page_state_restore_failed', error, stackTrace);
    }
  }

  void update(String key, Map<String, Object?> patch, {int? epoch}) {
    if (epoch != null && epoch != _epoch) return;
    final next = {...?_pages[key], ...patch};
    if (jsonEncode(next) == jsonEncode(_pages[key])) return;
    _pages[key] = next;
    if (!_persistent || _writeScheduled) return;
    _writeScheduled = true;
    final generation = _epoch;
    _tail = _tail.then((_) async {
      await initialize();
      _writeScheduled = false;
      if (generation != _epoch) return;
      try {
        await _write(jsonEncode({'version': 1, 'pages': _pages}));
      } catch (error, stackTrace) {
        _log('browse_page_state_save_failed', error, stackTrace);
      }
    });
  }

  Future<void> flush() async {
    await initialize();
    while (true) {
      final pending = _tail;
      await pending;
      if (identical(pending, _tail)) return;
    }
  }

  Future<void> clear() async {
    _epoch++;
    _pages.clear();
    _writeScheduled = false;
    _tail = _tail.then((_) async {
      await initialize();
      if (_persistent) {
        try {
          await _write(null);
        } catch (error, stackTrace) {
          _log('browse_page_state_clear_failed', error, stackTrace);
        }
      }
    });
    await _tail;
  }

  static void _log(String event, Object error, StackTrace stackTrace) {
    AppLogService.error(event, error: error, stackTrace: stackTrace);
  }
}
