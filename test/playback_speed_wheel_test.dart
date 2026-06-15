import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/screens/playlist_tab.dart';

void main() {
  test('desktop playback speed wheel advances one step per scroll event', () {
    expect(
      playbackSpeedWheelIndexAfterDesktopScroll(
        currentIndex: 2,
        scrollDeltaY: 240,
        itemCount: 7,
      ),
      3,
    );
    expect(
      playbackSpeedWheelIndexAfterDesktopScroll(
        currentIndex: 3,
        scrollDeltaY: -240,
        itemCount: 7,
      ),
      2,
    );
  });

  test('desktop playback speed wheel clamps at both ends', () {
    expect(
      playbackSpeedWheelIndexAfterDesktopScroll(
        currentIndex: 0,
        scrollDeltaY: -120,
        itemCount: 7,
      ),
      0,
    );
    expect(
      playbackSpeedWheelIndexAfterDesktopScroll(
        currentIndex: 6,
        scrollDeltaY: 120,
        itemCount: 7,
      ),
      6,
    );
  });

  test(
    'desktop playback speed wheel ignores events from the same wheel tick',
    () {
      expect(
        playbackSpeedWheelIndexAfterDesktopScroll(
          currentIndex: 3,
          scrollDeltaY: 120,
          itemCount: 7,
          wheelLocked: true,
        ),
        3,
      );
    },
  );
}
