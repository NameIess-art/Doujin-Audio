import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/presentation/main_screen.dart';

void main() {
  test(
    'mobile global subtitle overlay only runs while app is backgrounded',
    () {
      expect(shouldRunGlobalSubtitleOverlay(appInForeground: true), isFalse);
      expect(shouldRunGlobalSubtitleOverlay(appInForeground: false), isTrue);
    },
  );
}
