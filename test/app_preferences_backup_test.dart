import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
