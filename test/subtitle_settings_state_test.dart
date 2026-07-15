import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/subtitle_settings_provider.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'copyWith preserves, updates, and explicitly clears subtitle colors',
    () {
      const fontColor = Color(0xFF112233);
      const backgroundColor = Color(0xAA445566);
      final initial = SubtitleSettingsState(
        showSubtitlesMap: const {'session': false},
        globalSubtitlesMap: const {'session': true},
        positions: const {'session': 42},
        fontFamily: 'Test Font',
        fontColor: fontColor,
        backgroundOpacity: 0.4,
        backgroundColor: backgroundColor,
        borderDepth: 1.5,
        fontSize: 20,
      );

      final updated = initial.copyWith(
        showSubtitlesMap: const {'other': true},
        backgroundOpacity: 0.7,
        fontSize: 24,
      );

      expect(updated.showSubtitlesMap, const {'other': true});
      expect(updated.globalSubtitlesMap, same(initial.globalSubtitlesMap));
      expect(updated.positions, same(initial.positions));
      expect(updated.fontFamily, initial.fontFamily);
      expect(updated.fontColor, fontColor);
      expect(updated.backgroundOpacity, 0.7);
      expect(updated.backgroundColor, backgroundColor);
      expect(updated.borderDepth, initial.borderDepth);
      expect(updated.fontSize, 24);
      expect(updated.isShowEnabled('missing'), isTrue);
      expect(updated.isGlobalEnabled('missing'), isFalse);

      final cleared = updated.copyWith(
        clearFontColor: true,
        clearBackgroundColor: true,
      );
      expect(cleared.fontColor, isNull);
      expect(cleared.backgroundColor, isNull);
    },
  );

  test('notifier restores persisted session and appearance settings', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'subtitle_show_map': <String>['first|false', 'second|true', 'invalid'],
      'subtitle_global_map': <String>['first|true'],
      'subtitle_positions': <String>['first|42.5', 'second|invalid'],
      'subtitle_background_opacity': '0.65',
      'subtitle_font_family': 'Noto Sans',
      'subtitle_font_color': 'ff112233',
      'subtitle_background_color': 'aa445566',
      'subtitle_border_depth': '1.25',
      'subtitle_font_size': '22',
    });
    await AppPreferences.init();
    final notifier = SubtitleSettingsNotifier();
    addTearDown(notifier.dispose);

    final restored = await notifier.stream.firstWhere(
      (state) => state.fontFamily == 'Noto Sans',
    );

    expect(restored.isShowEnabled('first'), isFalse);
    expect(restored.isShowEnabled('second'), isTrue);
    expect(restored.isGlobalEnabled('first'), isTrue);
    expect(restored.positions, <String, double>{'first': 42.5, 'second': -1});
    expect(restored.fontColor, const Color(0xFF112233));
    expect(restored.backgroundColor, const Color(0xAA445566));
    expect(restored.backgroundOpacity, 0.65);
    expect(restored.borderDepth, 1.25);
    expect(restored.fontSize, 22);
  });

  test('session toggles update dependent state and persistence', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'subtitle_show_map': <String>['session|true'],
      'subtitle_global_map': <String>['session|true'],
      'subtitle_positions': <String>['session|80'],
    });
    await AppPreferences.init();
    final notifier = SubtitleSettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.stream.firstWhere(
      (state) => state.positions['session'] == 80,
    );

    notifier.toggleShowSubtitles('session');
    expect(notifier.state.isShowEnabled('session'), isFalse);
    expect(notifier.state.isGlobalEnabled('session'), isFalse);
    expect(notifier.state.positions['session'], 80);

    notifier.toggleShowSubtitles('session');
    expect(notifier.state.isShowEnabled('session'), isTrue);
    expect(notifier.state.positions.containsKey('session'), isFalse);

    notifier.toggleGlobalSubtitles('session');
    notifier.setGlobalEnabled('session', true);
    notifier.setGlobalEnabled('session', true);
    notifier.updatePosition('session', 96.5);
    expect(notifier.state.isGlobalEnabled('session'), isTrue);
    expect(notifier.state.positions['session'], 96.5);

    notifier.resetForSession('session');
    expect(notifier.state.isShowEnabled('session'), isTrue);
    expect(notifier.state.isGlobalEnabled('session'), isFalse);

    notifier.toggleShowSubtitles('other');
    notifier.turnOffAllSubtitles();
    expect(notifier.state.showSubtitlesMap, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('subtitle_show_map'), isEmpty);
    expect(prefs.getStringList('subtitle_global_map'), isEmpty);
    expect(prefs.getStringList('subtitle_positions'), contains('session|96.5'));
  });

  test('appearance setters persist values and clear optional colors', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final notifier = SubtitleSettingsNotifier();
    addTearDown(notifier.dispose);
    await Future<void>.delayed(Duration.zero);

    notifier.setFontFamily('Rounded');
    notifier.setFontColor(const Color(0xFF123456));
    notifier.setBackgroundOpacity(0.75);
    notifier.setFontSize(24);
    notifier.setBorderDepth(2);
    notifier.setBackgroundColor(const Color(0xCC654321));

    expect(notifier.state.fontFamily, 'Rounded');
    expect(notifier.state.fontColor, const Color(0xFF123456));
    expect(notifier.state.backgroundOpacity, 0.75);
    expect(notifier.state.fontSize, 24);
    expect(notifier.state.borderDepth, 2);
    expect(notifier.state.backgroundColor, const Color(0xCC654321));

    notifier.setFontColor(null);
    notifier.setBackgroundColor(null);
    expect(notifier.state.fontColor, isNull);
    expect(notifier.state.backgroundColor, isNull);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('subtitle_font_family'), 'Rounded');
    expect(prefs.getString('subtitle_background_opacity'), '0.75');
    expect(prefs.getString('subtitle_font_size'), '24.0');
    expect(prefs.getString('subtitle_border_depth'), '2.0');
    expect(prefs.containsKey('subtitle_font_color'), isFalse);
    expect(prefs.containsKey('subtitle_background_color'), isFalse);
  });
}
