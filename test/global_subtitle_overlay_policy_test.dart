import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';

void main() {
  test('Windows overlay stays visible in foreground and background', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(shouldRunGlobalSubtitleOverlay(appInForeground: true), isTrue);
    expect(shouldRunGlobalSubtitleOverlay(appInForeground: false), isTrue);
  });
  test(
    'mobile global subtitle overlay only runs while app is backgrounded',
    () {
      expect(shouldRunGlobalSubtitleOverlay(appInForeground: true), isFalse);
      expect(shouldRunGlobalSubtitleOverlay(appInForeground: false), isTrue);
    },
  );
}
