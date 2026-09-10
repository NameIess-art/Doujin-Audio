import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';

class _Session extends Fake implements PlaybackSession {
  @override
  String get id => 'saved';
  @override
  bool get effectivePlaying => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });
  for (final overdue in [false, true]) {
    test(
      'Windows restores countdown that expired while closed (overdue=$overdue)',
      () async {
        final now = DateTime.now();
        final resume = now.add(
          overdue ? const Duration(minutes: -1) : const Duration(minutes: 5),
        );
        final expiry = resume.subtract(const Duration(minutes: 10));
        SharedPreferences.setMockInitialValues({
          'timer_runtime_v1': jsonEncode({
            'timerMode': 0,
            'timerDurationMs': 1000,
            'timerEndsAtWallClockMs': expiry.millisecondsSinceEpoch,
            'timerWaitingForPlayback': false,
            'autoResumeEnabled': true,
            'autoResumeHour': resume.hour,
            'autoResumeMinute': resume.minute,
            'pausedSessionIds': <String>[],
            'countdownSessionIds': ['saved'],
            'generation': 3,
          }),
        });
        final state = TimerService();
        final timer = TimerFacade.create(
          service: state,
          powerPlatformService: PowerPlatformService(isAndroidOverride: false),
        );
        addTearDown(timer.dispose);
        final resumed = <String>[];
        timer.attachRuntime(
          hasPlayingSession: () => false,
          sessions: () => [_Session()],
          pauseSession: (_) async => true,
          activateAudioSession: () async => true,
          resumeSession: (session) async {
            resumed.add(session.id);
            return true;
          },
          onStateChanged: () {},
          onRuntimeRestored: () {},
          applyFadeMultiplier: (_) {},
        );
        await timer.loadRuntimeFromSystem();
        if (overdue) {
          expect(resumed, ['saved']);
          expect(state.pausedByTimerSessionIds, isEmpty);
        } else {
          expect(resumed, isEmpty);
          expect(state.pausedByTimerSessionIds, ['saved']);
          expect(state.autoResumeAt, isNotNull);
        }
      },
    );
  }
}
