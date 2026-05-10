import '../models/playback_mode.dart';

class CountdownTickResult {
  const CountdownTickResult({
    required this.remaining,
    required this.expired,
    required this.changed,
  });

  final Duration remaining;
  final bool expired;
  final bool changed;
}

class TimerRuntimeCalculator {
  const TimerRuntimeCalculator();

  bool hasArmedRuntime({
    required TimerMode? mode,
    required Duration? duration,
    required bool waitingForPlayback,
    required bool active,
    required DateTime? endsAt,
    required DateTime? autoResumeAt,
    required bool hasPausedByTimerSessionIds,
  }) {
    final hasPendingTrigger =
        mode == TimerMode.trigger && duration != null && waitingForPlayback;
    final hasRunningCountdown = active && endsAt != null;
    return hasPendingTrigger ||
        hasRunningCountdown ||
        autoResumeAt != null ||
        hasPausedByTimerSessionIds;
  }

  bool hasPendingAutoResume({
    required DateTime? autoResumeAt,
    required bool hasPausedByTimerSessionIds,
  }) {
    return autoResumeAt != null && hasPausedByTimerSessionIds;
  }

  DateTime nextClockTime({
    required DateTime now,
    required int hour,
    required int minute,
  }) {
    var target = DateTime(now.year, now.month, now.day, hour, minute);
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }

  CountdownTickResult countdownTick({
    required bool active,
    required DateTime? endsAt,
    required DateTime now,
    required Duration? currentRemaining,
  }) {
    if (!active || endsAt == null) {
      return CountdownTickResult(
        remaining: currentRemaining ?? Duration.zero,
        expired: false,
        changed: false,
      );
    }

    final remaining = endsAt.difference(now);
    if (remaining <= Duration.zero) {
      final changed = currentRemaining != Duration.zero;
      return CountdownTickResult(
        remaining: Duration.zero,
        expired: true,
        changed: changed,
      );
    }

    final roundedSeconds = (remaining.inMilliseconds + 999) ~/ 1000;
    final next = Duration(seconds: roundedSeconds);
    return CountdownTickResult(
      remaining: next,
      expired: false,
      changed: next != currentRemaining,
    );
  }
}
