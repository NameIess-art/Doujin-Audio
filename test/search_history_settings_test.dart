import 'dart:async';
import 'dart:convert';

import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();

  Future<bool> Function()? beforeSave;
  final writes = <Map<String, dynamic>>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(jsonDecode(value as String) as Map<String, dynamic>);
    if (beforeSave != null && !await beforeSave!()) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Preferences preferences;
  late SettingsRepository settings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    preferences = _Preferences();
    SharedPreferencesStorePlatform.instance = preferences;
    settings = SettingsRepository()..syncSlice(isInitialized: true);
  });

  tearDown(() async {
    await settings.dispose();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'normalizes confirmed queries and keeps library scopes separate',
    () async {
      await settings.recordSearchQuery(
        '  Actor  Name ,  Tag, actor name ',
        online: false,
      );
      await settings.recordSearchQuery('Online work', online: true);
      expect(settings.slice.state.librarySearchHistory, ['Actor Name, Tag']);
      expect(settings.slice.state.asmrSearchHistory, ['Online work']);
      expect(preferences.writes.last['librarySearchHistory'], [
        'Actor Name, Tag',
      ]);
      expect(preferences.writes.last['asmrSearchHistory'], ['Online work']);
    },
  );

  test(
    'moves a case insensitive duplicate to the front and caps each scope at 50',
    () async {
      for (final online in [false, true]) {
        for (var i = 0; i < 52; i++) {
          await settings.recordSearchQuery('Work $i', online: online);
        }
        await settings.recordSearchQuery(' work  20 ', online: online);
        final history = online
            ? settings.slice.state.asmrSearchHistory
            : settings.slice.state.librarySearchHistory;
        expect(history, hasLength(50));
        expect(history.first, 'work 20');
        expect(history[1], 'Work 51');
        expect(history.last, 'Work 2');
        expect(
          history.where((query) => query.toLowerCase() == 'work 20'),
          hasLength(1),
        );
        expect(history, isNot(contains('Work 1')));
      }
    },
  );

  test(
    'empty queries and an unchanged most recent query do not write',
    () async {
      for (final query in ['', '   ', ' , , ']) {
        await settings.recordSearchQuery(query, online: false);
        await settings.recordSearchQuery(query, online: true);
      }
      expect(preferences.writes, isEmpty);
      await settings.recordSearchQuery('Actor, Tag', online: true);
      await settings.recordSearchQuery(' Actor ,  Tag ', online: true);
      expect(preferences.writes, hasLength(1));
    },
  );

  test(
    'restores full queries after restart and follows backup restore and reset',
    () async {
      await settings.recordSearchQuery('Local actor, Local tag', online: false);
      await settings.recordSearchQuery(
        'Online actor, Online tag',
        online: true,
      );
      final backup = await AppPreferences.snapshot();
      final restarted = SettingsRepository();
      addTearDown(restarted.dispose);
      await restarted.loadPersistedState(enforceCacheLimit: false);
      expect(restarted.slice.state.librarySearchHistory, [
        'Local actor, Local tag',
      ]);
      expect(restarted.slice.state.asmrSearchHistory, [
        'Online actor, Online tag',
      ]);

      await settings.recordSearchQuery('Other local', online: false);
      await settings.recordSearchQuery('Other online', online: true);
      await AppPreferences.replaceSnapshot(backup);
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.slice.state.librarySearchHistory, [
        'Local actor, Local tag',
      ]);
      expect(settings.slice.state.asmrSearchHistory, [
        'Online actor, Online tag',
      ]);
      await settings.resetPersistedState();
      expect(settings.librarySearchHistory, isEmpty);
      expect(settings.asmrSearchHistory, isEmpty);
      expect(settings.slice.state.librarySearchHistory, isEmpty);
      expect(settings.slice.state.asmrSearchHistory, isEmpty);
    },
  );

  test(
    'missing or malformed histories load safely and normalize stored values',
    () async {
      await AppPreferences.writeJson('playback_settings_v1', {
        'librarySearchHistory': [
          null,
          2,
          '',
          '  Actor , Tag ',
          'actor, tag',
          'Other',
        ],
        'asmrSearchHistory': 'invalid',
      });
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.slice.state.librarySearchHistory, [
        'Actor, Tag',
        'Other',
      ]);
      expect(settings.slice.state.asmrSearchHistory, isEmpty);

      await AppPreferences.writeJson('playback_settings_v1', {});
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.slice.state.librarySearchHistory, isEmpty);
      expect(settings.slice.state.asmrSearchHistory, isEmpty);
    },
  );

  test(
    'a failed save rolls back both repository and published history',
    () async {
      await settings.recordSearchQuery('Saved local', online: false);
      await settings.recordSearchQuery('Saved online', online: true);
      final original = settings.slice.state;
      preferences.beforeSave = () async => false;
      await expectLater(
        settings.recordSearchQuery('Rejected', online: true),
        throwsStateError,
      );
      expect(settings.asmrSearchHistory, ['Saved online']);
      expect(settings.slice.state, original);

      preferences.beforeSave = null;
      await settings.setAllowVideoPlayback(false);
      expect(preferences.writes.last['librarySearchHistory'], ['Saved local']);
      expect(preferences.writes.last['asmrSearchHistory'], ['Saved online']);
    },
  );

  test(
    'serial saves publish only after commit and preserve queued queries',
    () async {
      final blocked = Completer<bool>();
      preferences.beforeSave = () => preferences.writes.length == 1
          ? blocked.future
          : Future<bool>.value(true);
      final first = settings.recordSearchQuery('First', online: true);
      final second = settings.recordSearchQuery('Second', online: true);
      await Future<void>.delayed(Duration.zero);
      expect(preferences.writes, hasLength(1));
      expect(settings.slice.state.asmrSearchHistory, isEmpty);
      blocked.complete(true);
      await Future.wait([first, second]);
      expect(settings.slice.state.asmrSearchHistory, ['Second', 'First']);
      expect(preferences.writes.last['asmrSearchHistory'], ['Second', 'First']);
    },
  );

  test('history snapshots are immutable and participate in state equality', () {
    final source = ['Actor, Tag'];
    final state = SettingsState(
      librarySearchHistory: source,
      asmrSearchHistory: const ['Online'],
    );
    source.add('Changed');
    expect(state.librarySearchHistory, ['Actor, Tag']);
    expect(
      () => state.librarySearchHistory.add('Changed'),
      throwsUnsupportedError,
    );
    expect(() => state.asmrSearchHistory.clear(), throwsUnsupportedError);
    final equal = SettingsState(
      librarySearchHistory: const ['Actor, Tag'],
      asmrSearchHistory: const ['Online'],
    );
    expect(state, equal);
    expect(state.hashCode, equal.hashCode);
    expect(state, isNot(SettingsState(asmrSearchHistory: const ['Online'])));
    expect(
      state,
      isNot(SettingsState(librarySearchHistory: const ['Actor, Tag'])),
    );
  });
}
