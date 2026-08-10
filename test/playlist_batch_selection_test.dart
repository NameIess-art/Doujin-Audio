import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Playlist batch selection rules', () {
    bool isPlayEnabled({
      required int count,
      required bool multiThreadEnabled,
    }) {
      return count > 0 && (multiThreadEnabled || count <= 1);
    }

    bool isPauseEnabled(int count) => count > 0;
    bool isRemoveEnabled(int count) => count > 0;

    test('Play button is disabled when selected count is 0', () {
      expect(
        isPlayEnabled(count: 0, multiThreadEnabled: false),
        isFalse,
      );
      expect(
        isPlayEnabled(count: 0, multiThreadEnabled: true),
        isFalse,
      );
      expect(isPauseEnabled(0), isFalse);
      expect(isRemoveEnabled(0), isFalse);
    });

    test('Play button is enabled for single selection regardless of multi-thread setting', () {
      expect(
        isPlayEnabled(count: 1, multiThreadEnabled: false),
        isTrue,
      );
      expect(
        isPlayEnabled(count: 1, multiThreadEnabled: true),
        isTrue,
      );
      expect(isPauseEnabled(1), isTrue);
      expect(isRemoveEnabled(1), isTrue);
    });

    test('Play button is grayed out/disabled for multiple selection when multi-thread playback is OFF', () {
      expect(
        isPlayEnabled(count: 2, multiThreadEnabled: false),
        isFalse,
      );
      expect(
        isPlayEnabled(count: 5, multiThreadEnabled: false),
        isFalse,
      );
      expect(isPauseEnabled(2), isTrue);
      expect(isRemoveEnabled(2), isTrue);
    });

    test('Play button is enabled for multiple selection when multi-thread playback is ON', () {
      expect(
        isPlayEnabled(count: 2, multiThreadEnabled: true),
        isTrue,
      );
      expect(
        isPlayEnabled(count: 5, multiThreadEnabled: true),
        isTrue,
      );
      expect(isPauseEnabled(2), isTrue);
      expect(isRemoveEnabled(2), isTrue);
    });
  });
}
