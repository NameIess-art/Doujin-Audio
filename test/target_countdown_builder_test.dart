import 'dart:async';

import 'package:doujin_audio/core/widgets/target_countdown_builder.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('countdown ticks only while visible with time remaining', (
    tester,
  ) async {
    const interval = Duration(milliseconds: 937);
    final activeTarget = DateTime.now().add(const Duration(minutes: 1));
    Timer? countdownTimer;
    Duration? remaining;

    Widget countdown({bool enabled = true, DateTime? target}) => TickerMode(
      enabled: enabled,
      child: TargetCountdownBuilder(
        target: target ?? activeTarget,
        tickInterval: interval,
        builder: (_, duration) {
          remaining = duration;
          return const SizedBox.shrink();
        },
      ),
    );

    await runZoned(
      () async {
        final binding = tester.binding;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        addTearDown(() {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        });

        await tester.pumpWidget(countdown());
        expect(remaining, greaterThan(Duration.zero));
        expect(countdownTimer?.isActive, isTrue);

        await tester.pumpWidget(countdown(enabled: false));
        expect(countdownTimer?.isActive, isFalse);

        await tester.pumpWidget(countdown());
        expect(countdownTimer?.isActive, isTrue);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        expect(countdownTimer?.isActive, isFalse);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(countdownTimer?.isActive, isTrue);

        await tester.pumpWidget(
          countdown(target: activeTarget.subtract(const Duration(minutes: 2))),
        );
        expect(remaining, Duration.zero);
        expect(countdownTimer?.isActive, isFalse);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == interval) countdownTimer = timer;
          return timer;
        },
      ),
    );
  });

  testWidgets(
    'app lifecycle changes do not rebuild an offscreen countdown tab',
    (tester) async {
      final target = DateTime.now().add(const Duration(minutes: 2));
      var buildCount = 0;

      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });

      await tester.pumpWidget(
        TickerMode(
          enabled: false,
          child: TargetCountdownBuilder(
            target: target,
            builder: (_, _) {
              buildCount++;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final initialBuilds = buildCount;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 50));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 50));

      expect(buildCount, initialBuilds);
    },
  );
}
