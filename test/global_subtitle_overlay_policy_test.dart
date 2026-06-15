import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/screens/main_screen.dart';

void main() {
  test(
    'Windows global subtitle overlay runs while the app is foregrounded',
    () {
      expect(
        shouldRunGlobalSubtitleOverlay(appInForeground: true, isWindows: true),
        isTrue,
      );
    },
  );

  test(
    'mobile global subtitle overlay only runs while app is backgrounded',
    () {
      expect(
        shouldRunGlobalSubtitleOverlay(appInForeground: true, isWindows: false),
        isFalse,
      );
      expect(
        shouldRunGlobalSubtitleOverlay(
          appInForeground: false,
          isWindows: false,
        ),
        isTrue,
      );
    },
  );
}
