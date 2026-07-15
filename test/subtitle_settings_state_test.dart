import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/subtitle_settings_provider.dart';

void main() {
  test('copyWith preserves, updates, and explicitly clears subtitle colors', () {
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
  });
}
