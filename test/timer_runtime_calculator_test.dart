import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/models/playback_mode.dart';
import 'package:music_player/services/timer_runtime_calculator.dart';

void main() {
  const calculator = TimerRuntimeCalculator();

  test('hasArmedRuntime covers waiting trigger and auto resume', () {
    expect(
      calculator.hasArmedRuntime(
        mode: TimerMode.trigger,
        duration: const Duration(minutes: 10),
        waitingForPlayback: true,
        active: false,
        endsAt: null,
        autoResumeAt: null,
        hasPausedByTimerPaths: false,
      ),
      isTrue,
    );

    expect(
      calculator.hasArmedRuntime(
        mode: null,
        duration: null,
        waitingForPlayback: false,
        active: false,
        endsAt: null,
        autoResumeAt: DateTime(2026, 1, 1, 8),
        hasPausedByTimerPaths: true,
      ),
      isTrue,
    );
  });

  test('nextClockTime rolls to tomorrow when time already passed', () {
    final next = calculator.nextClockTime(
      now: DateTime(2026, 1, 1, 8, 30),
      hour: 8,
      minute: 0,
    );

    expect(next, DateTime(2026, 1, 2, 8));
  });

  test('countdownTick rounds up remaining seconds', () {
    final tick = calculator.countdownTick(
      active: true,
      endsAt: DateTime(2026, 1, 1, 8, 0, 2, 100),
      now: DateTime(2026, 1, 1, 8),
      currentRemaining: const Duration(seconds: 3),
    );

    expect(tick.remaining, const Duration(seconds: 3));
    expect(tick.expired, isFalse);
    expect(tick.changed, isFalse);
  });

  test('countdownTick reports expiry', () {
    final tick = calculator.countdownTick(
      active: true,
      endsAt: DateTime(2026, 1, 1, 8),
      now: DateTime(2026, 1, 1, 8, 0, 1),
      currentRemaining: const Duration(seconds: 1),
    );

    expect(tick.remaining, Duration.zero);
    expect(tick.expired, isTrue);
    expect(tick.changed, isTrue);
  });

  test('hasPendingAutoResume requires paused paths', () {
    expect(
      calculator.hasPendingAutoResume(
        autoResumeAt: DateTime(2026, 1, 1, 8),
        hasPausedByTimerPaths: false,
      ),
      isFalse,
    );
  });
}
