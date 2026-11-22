import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  test(
    'preference backup round-trips supported values and replaces old data',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'name': 'Nameless',
        'enabled': true,
        'count': 4,
        'ratio': 1.5,
        'folders': <String>['one', 'two'],
        'timer_runtime_v1': 'transient',
      });
      await AppPreferences.init();

      final snapshot = await AppPreferences.snapshot(
        excludedKeys: const <String>{'timer_runtime_v1'},
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.clear();
      await preferences.setString('stale', 'remove me');

      await AppPreferences.replaceSnapshot(snapshot);

      expect(preferences.getString('name'), 'Nameless');
      expect(preferences.getBool('enabled'), isTrue);
      expect(preferences.getInt('count'), 4);
      expect(preferences.getDouble('ratio'), 1.5);
      expect(preferences.getStringList('folders'), <String>['one', 'two']);
      expect(preferences.containsKey('timer_runtime_v1'), isFalse);
      expect(preferences.containsKey('stale'), isFalse);
    },
  );

  test(
    'preference restore rejects unsupported values before clearing data',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'preserved': 'value',
      });
      await AppPreferences.init();

      await expectLater(
        AppPreferences.replaceSnapshot(<String, Object?>{
          'nested': <String, Object?>{'not': 'supported'},
        }),
        throwsFormatException,
      );

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('preserved'), 'value');
    },
  );

  test(
    'snapshot preserves dynamic string lists loaded from disk (Windows JSON)',
    () async {
      final previousStore = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _DynamicListPreferencesStore({
        'flutter.subtitle_show_map': <dynamic>['trackA=1', 'trackB=0'],
        'flutter.mixed_list': <dynamic>['ok', 42],
        'flutter.name': 'WindowsUser',
      });
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previousStore;
      });
      await (await SharedPreferences.getInstance()).reload();
      await AppPreferences.init();

      final snapshot = await AppPreferences.snapshot();

      expect(snapshot['subtitle_show_map'], isA<List<String>>());
      expect(snapshot['subtitle_show_map'], <String>['trackA=1', 'trackB=0']);
      expect(snapshot.containsKey('mixed_list'), isFalse);
      expect(snapshot['name'], 'WindowsUser');
    },
  );
}

class _DynamicListPreferencesStore extends SharedPreferencesStorePlatform {
  _DynamicListPreferencesStore(this._values);

  final Map<String, Object> _values;

  @override
  Future<Map<String, Object>> getAll() async => Map<String, Object>.of(_values);

  @override
  Future<bool> clear() async {
    _values.clear();
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _values[key] = value;
    return true;
  }
}
