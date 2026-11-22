import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/application/timer_runtime_calculator.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/test_persistence_repository.dart';

MusicTrack _track(String name, String path) => MusicTrack(
  path: path,
  displayName: name,
  groupKey: '/music',
  groupTitle: 'Album',
  groupSubtitle: '',
  isSingle: false,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('TimerRuntimeCalculator.nextClockTime (#21)', () {
    const calculator = TimerRuntimeCalculator();

    test('rolls over by local calendar day across month and year boundaries', () {
      final monthRollover = calculator.nextClockTime(
        now: DateTime(2026, 3, 31, 22, 15),
        hour: 7,
        minute: 30,
      );
      expect(monthRollover, DateTime(2026, 4, 1, 7, 30));
      expect(monthRollover.hour, 7);
      expect(monthRollover.minute, 30);

      final yearRollover = calculator.nextClockTime(
        now: DateTime(2026, 12, 31, 23, 45),
        hour: 6,
        minute: 0,
      );
      expect(yearRollover, DateTime(2027, 1, 1, 6));
      expect(yearRollover.hour, 6);
      expect(yearRollover.minute, 0);
    });
  });

  group('TimerFacade sync and fade regressions (#20, #47)', () {
    testWidgets(
      'local timer expiry without auto-resume syncs cleared native alarms (#20)',
      (tester) async {
        final service = TimerService();
        final power = _FallbackPowerPlatformService();
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: power,
        );
        addTearDown(timer.dispose);
        final session = _FakeSession('s1')..playing = true;
        timer.attachRuntime(
          hasPlayingSession: () => true,
          sessions: () => [session],
          pauseSession: (target) async {
            (target as _FakeSession).playing = false;
            return true;
          },
          activateAudioSession: () async => true,
          resumeSession: (_) async => true,
          onStateChanged: () {},
          onRuntimeRestored: () {},
          applyFadeMultiplier: (_) {},
        );

        timer.configureTimer(TimerMode.manual, const Duration(seconds: 5));
        timer.startCountdown();
        await tester.pump();
        power.timerSyncs.clear();

        service.timerEndsAt = DateTime.now().subtract(
          const Duration(seconds: 1),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(session.playing, isFalse);
        expect(timer.hasArmedRuntime, isFalse);
        expect(power.timerSyncs, hasLength(1));
        expect(power.timerSyncs.single['timerEndsAtWallClockMs'], isNull);
        expect(power.timerSyncs.single['autoResumeAtMs'], isNull);
        expect(power.timerSyncs.single['pausedSessionIds'], isEmpty);
        expect(power.timerSyncs.single['generation'], service.timerGeneration);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'local auto-resume completion syncs cleared native alarms (#20)',
      (tester) async {
        final service = TimerService();
        final power = _FallbackPowerPlatformService();
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: power,
          resumeFadeInDuration: Duration.zero,
        );
        addTearDown(timer.dispose);
        final session = _FakeSession('s1');
        timer.attachRuntime(
          hasPlayingSession: () => false,
          sessions: () => [session],
          pauseSession: (_) async => true,
          activateAudioSession: () async => true,
          resumeSession: (target) async {
            (target as _FakeSession).playing = true;
            return true;
          },
          onStateChanged: () {},
          onRuntimeRestored: () {},
          applyFadeMultiplier: (_) {},
        );

        service
          ..pausedByTimerSessionIds.add('s1')
          ..autoResumeEnabled = true
          ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1));
        timer.retryOverdueAutoResume();
        await tester.pump();
        await tester.pump();

        expect(session.playing, isTrue);
        expect(timer.hasArmedRuntime, isFalse);
        expect(power.timerSyncs, hasLength(1));
        expect(power.timerSyncs.single['autoResumeAtMs'], isNull);
        expect(power.timerSyncs.single['pausedSessionIds'], isEmpty);
        expect(power.timerSyncs.single['generation'], service.timerGeneration);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'configuring a new timer during auto-resume fade-in cancels the fade timer (#47)',
      (tester) async {
        final service = TimerService();
        final power = _FallbackPowerPlatformService();
        final multipliers = <double>[];
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: power,
        );
        addTearDown(timer.dispose);
        final session = _FakeSession('s1');
        timer.attachRuntime(
          hasPlayingSession: () => false,
          sessions: () => [session],
          pauseSession: (_) async => true,
          activateAudioSession: () async => true,
          resumeSession: (target) async {
            (target as _FakeSession).playing = true;
            return true;
          },
          onStateChanged: () {},
          onRuntimeRestored: () {},
          applyFadeMultiplier: multipliers.add,
        );

        service
          ..pausedByTimerSessionIds.add('s1')
          ..autoResumeEnabled = true
          ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1));
        timer.retryOverdueAutoResume();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(multipliers.last, lessThan(1.0));

        multipliers.clear();
        timer.configureTimer(TimerMode.manual, const Duration(minutes: 5));
        expect(multipliers, [1.0]);

        await tester.pump(const Duration(milliseconds: 500));
        expect(multipliers, [1.0]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('PlaybackSessionPersistenceCoordinator.loadPersistedState (#44)', () {
    test(
      'keeps currentQueueIndex aligned with currentTrackPath when recordPlaybackProgress is false',
      () async {
        final tracks = [
          _track('Track 0', '/music/t0.mp3'),
          _track('Track 1', '/music/t1.mp3'),
          _track('Track 2', '/music/t2.mp3'),
        ];
        final queue = PlaybackQueueDefinition(
          name: 'Album',
          entries: [
            PlaybackQueueEntry(
              id: 'entry-1',
              kind: PlaybackQueueEntryKind.work,
              title: 'Album',
              tracks: tracks,
            ),
          ],
        );
        final repository = _PersistedQueueRepository([
          PersistedPlaybackSession(
            id: 'custom-queue',
            trackPath: tracks[2].path,
            loopModeIndex: SessionLoopMode.crossSequential.index,
            volume: 1.0,
            positionMs: 42000,
            durationMs: 120000,
            customQueueTracks: tracks,
            playbackQueue: queue,
            currentQueueIndex: 2,
            channelSwapEnabled: false,
            sortOrder: 0,
          ),
          PersistedPlaybackSession(
            id: 'stale-index',
            trackPath: tracks[1].path,
            loopModeIndex: SessionLoopMode.crossSequential.index,
            volume: 1.0,
            positionMs: 15000,
            durationMs: 120000,
            customQueueTracks: tracks,
            playbackQueue: queue,
            channelSwapEnabled: false,
            sortOrder: 1,
          ),
        ]);
        final playbackService = PlaybackSessionService();
        final facade = PlaybackFacade.create(
          service: playbackService,
          databaseRepository: repository,
        );
        addTearDown(() async {
          await facade.dispose();
          await playbackService.dispose();
        });
        facade.attachPersistenceRuntime(
          trackByPath: (path) =>
              tracks.where((t) => t.path == path).firstOrNull,
          recordPlaybackProgress: () => false,
          restoreRuntime: (_, {String? focusedSessionId}) async {},
          updatePlaybackHistory:
              ({
                required String trackPath,
                required Duration position,
                required DateTime now,
                required bool updatePlayedAt,
              }) => null,
          onFocusChanged: (_) {},
        );

        await facade.loadPersistedState();

        final restored = facade.sessionById('custom-queue')!;
        expect(restored.currentTrackPath, tracks[2].path);
        expect(restored.currentQueueIndex, 2);
        expect(restored.lastKnownPosition, Duration.zero);

        final corrected = facade.sessionById('stale-index')!;
        expect(corrected.currentTrackPath, tracks[1].path);
        expect(corrected.currentQueueIndex, 1);
        expect(corrected.lastKnownPosition, Duration.zero);
      },
    );
  });
}

final class _FakeSession extends PlaybackSession {
  _FakeSession(String id)
    : super(
        id: id,
        currentTrackPath: '/music/$id.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.idle),
      );

  bool playing = false;

  @override
  bool get effectivePlaying => playing;

  @override
  bool get playbackRequested => playing;
}

final class _FallbackPowerPlatformService extends PowerPlatformService {
  _FallbackPowerPlatformService() : super(isAndroidOverride: false);

  final List<Map<String, Object?>> timerSyncs = <Map<String, Object?>>[];

  @override
  Future<TimerExecutionResult> executeTimerExpiredNow(int generation) async =>
      TimerExecutionResult.failed;

  @override
  Future<TimerExecutionResult> executeAutoResumeNow(int generation) async =>
      TimerExecutionResult.failed;

  @override
  Future<void> syncPlaybackTimerAlarms({
    required int? timerMode,
    required int? timerDurationMs,
    required bool timerWaitingForPlayback,
    required int? timerEndsAtWallClockMs,
    required bool autoResumeEnabled,
    required int autoResumeHour,
    required int autoResumeMinute,
    required int? autoResumeAtMs,
    required List<String> pausedSessionIds,
    required int generation,
    bool stopAfterCurrentTrack = false,
  }) async {
    timerSyncs.add(<String, Object?>{
      'timerEndsAtWallClockMs': timerEndsAtWallClockMs,
      'autoResumeAtMs': autoResumeAtMs,
      'pausedSessionIds': List<String>.from(pausedSessionIds),
      'generation': generation,
    });
  }
}

final class _PersistedQueueRepository extends TestPersistenceRepository {
  _PersistedQueueRepository(this.sessions);

  final List<PersistedPlaybackSession> sessions;

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() async => sessions;
}
