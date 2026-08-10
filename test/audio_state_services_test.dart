import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/card_info_field.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';
import 'package:doujin_audio/app/application/audio_state_slice.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_state_models.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  group('AudioStateSlice', () {
    test('update skips equal states', () async {
      final slice = AudioStateSlice<int>(1);
      addTearDown(slice.dispose);

      final values = <int>[];
      final subscription = slice.stream.listen(values.add);
      addTearDown(subscription.cancel);

      await Future<void>.delayed(Duration.zero);
      slice.update(1);
      slice.update(2);
      slice.update(2);
      await Future<void>.delayed(Duration.zero);

      expect(values, <int>[1, 2]);
    });
  });

  group('PlaybackSessionService', () {
    test('continues queued preparation after a predecessor fails', () async {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);
      var secondPreparationRan = false;

      service.enqueueSessionPreparation(() async {
        throw StateError('injected preparation failure');
      });
      service.enqueueSessionPreparation(() async {
        secondPreparationRan = true;
      });

      await service.sessionPreparationQueue;

      expect(secondPreparationRan, isTrue);
    });
  });

  group('SettingsRepository', () {
    test('loads persisted playback and converter settings', () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'playback_settings_v1',
        json.encode(<String, Object?>{
          'multiThreadPlaybackEnabled': true,
          'notificationsEnabled': false,
          'showPlaybackCard': false,
          'startupPage': StartupPage.asmrOne.name,
          'bottomNavigationStyle': BottomNavigationStyle.bar.name,
          'autoPlayAddedSessions': false,
          'autoCheckUpdates': true,
          'recordPlaybackProgress': false,
          'asmrPlaybackCacheEnabled': true,
          'blurPlayerBackgroundEnabled': false,
          'uiBlurEffectEnabled': false,
          'hapticFeedbackEnabled': false,
          'coverImageResolution': CoverImageResolution.ultraHigh.name,
          'coverImageDisplayMode': CoverImageDisplayMode.tile.name,
          'preferEmbeddedAudioCover': false,
          'asmrDownloadDestinationRoot': '/backup/asmr',
          'asmrDownloadConflictPolicy': AsmrDownloadConflictPolicy.skip.name,
          'audioDeviceDisconnectBehavior':
              AudioDeviceDisconnectBehavior.continuePlayback.name,
          'transientAudioFocusLossBehavior':
              TransientAudioFocusLossBehavior.pause.name,
          'interruptionResumeBehavior':
              InterruptionResumeBehavior.stayPaused.name,
          'startupPlaybackRestoreBehavior':
              StartupPlaybackRestoreBehavior.pause.name,
          'allowDuplicateWorks': true,
          'reduceAnimations': true,
          'dlsiteMetadataLanguage': ContentLanguagePreference.en.name,
          'librarySortCriterion': LibrarySortCriterion.duration.name,
          'librarySortAscending': false,
          'libraryGroupByLibrary': true,
          'playlistSortCriterion': PlaylistSortCriterion.voiceActor.name,
          'playlistSortAscending': false,
          'playlistGroupByLibrary': true,
          'maxCacheBytes': 256 * 1024 * 1024,
        }),
      );
      await preferences.setString(
        'converter_settings_v1',
        json.encode(<String, Object?>{'format': 'flac', 'bitrate': '192k'}),
      );
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.loadPersistedState();

      expect(repository.slice.state.isInitialized, isTrue);
      expect(repository.multiThreadPlaybackEnabled, isTrue);
      expect(repository.notificationsEnabled, isFalse);
      expect(repository.coverImageResolution, CoverImageResolution.ultraHigh);
      expect(repository.coverImageDisplayMode, CoverImageDisplayMode.tile);
      expect(repository.preferEmbeddedAudioCover, isFalse);
      expect(repository.blurPlayerBackgroundEnabled, isFalse);
      expect(repository.startupPage, StartupPage.asmrOne);
      expect(repository.bottomNavigationStyle, BottomNavigationStyle.bar);
      expect(repository.asmrDownloadDestinationRoot, '/backup/asmr');
      expect(
        repository.asmrDownloadConflictPolicy,
        AsmrDownloadConflictPolicy.skip,
      );
      expect(
        repository.audioDeviceDisconnectBehavior,
        AudioDeviceDisconnectBehavior.continuePlayback,
      );
      expect(
        repository.transientAudioFocusLossBehavior,
        TransientAudioFocusLossBehavior.pause,
      );
      expect(
        repository.interruptionResumeBehavior,
        InterruptionResumeBehavior.stayPaused,
      );
      expect(
        repository.startupPlaybackRestoreBehavior,
        StartupPlaybackRestoreBehavior.pause,
      );
      expect(repository.allowDuplicateWorks, isTrue);
      expect(repository.reduceAnimations, isTrue);
      expect(repository.librarySortCriterion, LibrarySortCriterion.duration);
      expect(repository.librarySortAscending, isFalse);
      expect(repository.libraryGroupByLibrary, isTrue);
      expect(
        repository.playlistSortCriterion,
        PlaylistSortCriterion.voiceActor,
      );
      expect(repository.playlistSortAscending, isFalse);
      expect(repository.playlistGroupByLibrary, isTrue);
      expect(repository.converterFormat, 'flac');
      expect(repository.converterBitrate, '192k');
    });

    test('syncSlice publishes settings from the owning repository', () {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      repository
        ..converterFormat = 'flac'
        ..converterBitrate = '192k'
        ..multiThreadPlaybackEnabled = true
        ..notificationsEnabled = false
        ..showPlaybackCard = false
        ..startupPage = StartupPage.asmrOne
        ..bottomNavigationStyle = BottomNavigationStyle.bar
        ..autoPlayAddedSessions = false
        ..autoCheckUpdates = true
        ..dlsiteMetadataLanguage = ContentLanguagePreference.en
        ..asmrPlaybackCacheEnabled = true
        ..coverImageDisplayMode = CoverImageDisplayMode.stretch
        ..asmrDownloadDestinationRoot = '/downloads/asmr'
        ..asmrDownloadConflictPolicy = AsmrDownloadConflictPolicy.skip
        ..audioDeviceDisconnectBehavior =
            AudioDeviceDisconnectBehavior.continuePlayback
        ..transientAudioFocusLossBehavior =
            TransientAudioFocusLossBehavior.pause
        ..interruptionResumeBehavior = InterruptionResumeBehavior.stayPaused
        ..startupPlaybackRestoreBehavior = StartupPlaybackRestoreBehavior.pause
        ..allowDuplicateWorks = true
        ..reduceAnimations = true
        ..maxCacheBytes = 500 * 1024 * 1024;
      repository.syncSlice();

      expect(
        repository.slice.state,
        isA<SettingsState>()
            .having((state) => state.converterFormat, 'format', 'flac')
            .having((state) => state.converterBitrate, 'bitrate', '192k')
            .having(
              (state) => state.multiThreadPlaybackEnabled,
              'multi-thread',
              isTrue,
            )
            .having(
              (state) => state.notificationsEnabled,
              'notifications',
              isFalse,
            )
            .having((state) => state.showPlaybackCard, 'show card', isFalse)
            .having(
              (state) => state.startupPage,
              'startup page',
              StartupPage.asmrOne,
            )
            .having(
              (state) => state.bottomNavigationStyle,
              'bottom navigation',
              BottomNavigationStyle.bar,
            )
            .having(
              (state) => state.autoPlayAddedSessions,
              'auto play',
              isFalse,
            )
            .having(
              (state) => state.autoCheckUpdates,
              'auto update check',
              isTrue,
            )
            .having(
              (state) => state.dlsiteMetadataLanguage,
              'dlsite language',
              ContentLanguagePreference.en,
            )
            .having(
              (state) => state.asmrPlaybackCacheEnabled,
              'asmr playback cache',
              isTrue,
            )
            .having(
              (state) => state.coverImageDisplayMode,
              'cover display mode',
              CoverImageDisplayMode.stretch,
            )
            .having(
              (state) => state.asmrDownloadDestinationRoot,
              'asmr destination',
              '/downloads/asmr',
            )
            .having(
              (state) => state.asmrDownloadConflictPolicy,
              'asmr conflict policy',
              AsmrDownloadConflictPolicy.skip,
            )
            .having(
              (state) => state.maxCacheBytes,
              'max cache',
              500 * 1024 * 1024,
            )
            .having(
              (state) => state.audioDeviceDisconnectBehavior,
              'audio disconnect',
              AudioDeviceDisconnectBehavior.continuePlayback,
            )
            .having(
              (state) => state.transientAudioFocusLossBehavior,
              'transient focus',
              TransientAudioFocusLossBehavior.pause,
            )
            .having(
              (state) => state.interruptionResumeBehavior,
              'interruption resume',
              InterruptionResumeBehavior.stayPaused,
            )
            .having(
              (state) => state.startupPlaybackRestoreBehavior,
              'startup restore',
              StartupPlaybackRestoreBehavior.pause,
            )
            .having(
              (state) => state.allowDuplicateWorks,
              'duplicate works',
              isTrue,
            )
            .having(
              (state) => state.reduceAnimations,
              'reduce animations',
              isTrue,
            ),
      );
    });

    test('new playback behavior settings preserve current defaults', () {
      final state = SettingsState();

      expect(
        state.audioDeviceDisconnectBehavior,
        AudioDeviceDisconnectBehavior.pause,
      );
      expect(
        state.transientAudioFocusLossBehavior,
        TransientAudioFocusLossBehavior.duck,
      );
      expect(
        state.interruptionResumeBehavior,
        InterruptionResumeBehavior.resume,
      );
      expect(
        state.startupPlaybackRestoreBehavior,
        StartupPlaybackRestoreBehavior.resume,
      );
      expect(state.allowDuplicateWorks, isFalse);
      expect(state.reduceAnimations, isFalse);
      expect(state.portraitLockEnabled, isFalse);
      expect(
        state.playbackDetailSubtitleStyle,
        PlaybackDetailSubtitleStyle.compact,
      );
      expect(state.coverImageDisplayMode, CoverImageDisplayMode.fill);
      expect(state.preferEmbeddedAudioCover, isTrue);
      expect(state.blurPlayerBackgroundEnabled, isTrue);
    });

    test(
      'video playback setting defaults on, publishes and persists',
      () async {
        final state = SettingsState();
        final repository = SettingsRepository();
        addTearDown(repository.dispose);

        expect(state.allowVideoPlayback, isTrue);
        expect(repository.allowVideoPlayback, isTrue);

        await repository.setAllowVideoPlayback(false);

        expect(repository.slice.state.allowVideoPlayback, isFalse);
        final saved =
            json.decode(
                  (await SharedPreferences.getInstance()).getString(
                    'playback_settings_v1',
                  )!,
                )
                as Map<String, dynamic>;
        expect(saved['allowVideoPlayback'], isFalse);

        final restored = SettingsRepository();
        addTearDown(restored.dispose);
        await restored.loadPersistedState();
        expect(restored.allowVideoPlayback, isFalse);
      },
    );

    test('blurred player background setting publishes and persists', () async {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.setBlurPlayerBackgroundEnabled(false);

      expect(repository.slice.state.blurPlayerBackgroundEnabled, isFalse);
      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect(saved['blurPlayerBackgroundEnabled'], isFalse);

      final restored = SettingsRepository();
      addTearDown(restored.dispose);
      await restored.loadPersistedState();
      expect(restored.blurPlayerBackgroundEnabled, isFalse);
    });

    test(
      'playback detail subtitle style persists with safe fallback',
      () async {
        final repository = SettingsRepository();
        addTearDown(repository.dispose);

        await repository.setPlaybackDetailSubtitleStyle(
          PlaybackDetailSubtitleStyle.timeline,
        );

        final saved =
            json.decode(
                  (await SharedPreferences.getInstance()).getString(
                    'playback_settings_v1',
                  )!,
                )
                as Map<String, dynamic>;
        expect(
          saved['playbackDetailSubtitleStyle'],
          PlaybackDetailSubtitleStyle.timeline.name,
        );

        final restored = SettingsRepository();
        addTearDown(restored.dispose);
        await restored.loadPersistedState();
        expect(
          restored.playbackDetailSubtitleStyle,
          PlaybackDetailSubtitleStyle.timeline,
        );

        SharedPreferences.setMockInitialValues(<String, Object>{
          'playback_settings_v1': json.encode(<String, Object?>{
            'playbackDetailSubtitleStyle': 'unknown',
          }),
        });
        final invalid = SettingsRepository();
        addTearDown(invalid.dispose);
        await invalid.loadPersistedState();
        expect(
          invalid.playbackDetailSubtitleStyle,
          PlaybackDetailSubtitleStyle.compact,
        );
      },
    );

    test('cover display mode persists with safe fallback', () async {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.setCoverImageDisplayMode(CoverImageDisplayMode.tile);

      final restored = SettingsRepository();
      addTearDown(restored.dispose);
      await restored.loadPersistedState();
      expect(restored.coverImageDisplayMode, CoverImageDisplayMode.tile);

      SharedPreferences.setMockInitialValues(<String, Object>{
        'playback_settings_v1': json.encode(<String, Object?>{
          'coverImageDisplayMode': 'unknown',
        }),
      });
      final invalid = SettingsRepository();
      addTearDown(invalid.dispose);
      await invalid.loadPersistedState();
      expect(invalid.coverImageDisplayMode, CoverImageDisplayMode.fill);
    });

    test('portrait lock persists and defaults to disabled', () async {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      expect(repository.portraitLockEnabled, isFalse);
      await repository.setPortraitLockEnabled(true);
      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect(saved['portraitLockEnabled'], isTrue);

      final restored = SettingsRepository();
      addTearDown(restored.dispose);
      await restored.loadPersistedState();
      expect(restored.portraitLockEnabled, isTrue);
    });

    test('ASMR.ONE download conflict policy defaults to overwrite', () {
      final state = SettingsState();
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      expect(
        state.asmrDownloadConflictPolicy,
        AsmrDownloadConflictPolicy.overwrite,
      );
      repository.syncSlice();
      expect(
        repository.slice.state.asmrDownloadConflictPolicy,
        AsmrDownloadConflictPolicy.overwrite,
      );
    });

    test('ASMR download metadata and folder name settings persist', () async {
      final state = SettingsState();
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      expect(state.asmrDownloadSaveMetadata, isTrue);
      expect(
        state.asmrDownloadFolderNameFields,
        kDefaultAsmrDownloadFolderNameFields,
      );

      await repository.setAsmrDownloadSaveMetadata(false);
      await repository.setAsmrDownloadFolderNameFields(const [
        AsmrDownloadFolderNameField.rjCode,
        AsmrDownloadFolderNameField.voiceActors,
        AsmrDownloadFolderNameField.workTitle,
      ]);

      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect(saved['asmrDownloadSaveMetadata'], isFalse);
      expect(saved['asmrDownloadFolderNameFields'], [
        'rjCode',
        'voiceActors',
        'workTitle',
      ]);

      final restored = SettingsRepository();
      addTearDown(restored.dispose);
      await restored.loadPersistedState();
      expect(restored.asmrDownloadSaveMetadata, isFalse);
      expect(restored.asmrDownloadFolderNameFields, const [
        AsmrDownloadFolderNameField.rjCode,
        AsmrDownloadFolderNameField.voiceActors,
        AsmrDownloadFolderNameField.workTitle,
      ]);
    });

    test('invalid ASMR folder name fields fall back to work title', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'playback_settings_v1': json.encode(<String, Object?>{
          'asmrDownloadFolderNameFields': <String>['unknown', 'unknown'],
        }),
      });
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.loadPersistedState();

      expect(
        repository.asmrDownloadFolderNameFields,
        kDefaultAsmrDownloadFolderNameFields,
      );
    });

    test('ASMR download destination publishes and persists', () async {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.setAsmrDownloadDestinationRoot('  /downloads/asmr  ');
      await repository.setAsmrDownloadDestinationRoot('/downloads/asmr');

      expect(repository.asmrDownloadDestinationRoot, '/downloads/asmr');
      expect(
        repository.slice.state.asmrDownloadDestinationRoot,
        '/downloads/asmr',
      );
      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect(saved['asmrDownloadDestinationRoot'], '/downloads/asmr');
    });

    test('ASMR.ONE playback cache defaults to disabled', () {
      final state = SettingsState();
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      expect(state.asmrPlaybackCacheEnabled, isFalse);
      repository.syncSlice();
      expect(repository.slice.state.asmrPlaybackCacheEnabled, isFalse);
    });

    test('converter settings validate, publish, and persist once', () async {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.setConverterSettings(format: 'flac', bitrate: '192k');
      await repository.setConverterSettings(format: 'invalid');

      expect(repository.converterFormat, 'flac');
      expect(repository.converterBitrate, '192k');
      expect(repository.slice.state.converterFormat, 'flac');
      expect(repository.slice.state.converterBitrate, '192k');
      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'converter_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect(saved, <String, dynamic>{'format': 'flac', 'bitrate': '192k'});
    });

    test('card info fields normalize, publish, and persist', () async {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      await repository.setCardInfoFields(const <CardInfoField>[
        CardInfoField.rjCode,
        CardInfoField.rjCode,
        CardInfoField.voiceActors,
      ]);

      expect(repository.cardInfoFields, const <CardInfoField>[
        CardInfoField.rjCode,
        CardInfoField.voiceActors,
      ]);
      expect(repository.slice.state.cardInfoFields, repository.cardInfoFields);
      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect(saved['cardInfoFields'], <String>['rjCode', 'voiceActors']);
    });

    test(
      'owned settings commands publish and persist only on change',
      () async {
        final repository = SettingsRepository();
        addTearDown(repository.dispose);

        await repository.setStartupPage(StartupPage.playlist);
        await repository.setAutoPlayAddedSessions(false);
        await repository.setAutoPlayAddedSessions(false);
        await repository.setAsmrPlaybackCacheEnabled(true);

        expect(repository.slice.state.startupPage, StartupPage.playlist);
        expect(repository.slice.state.autoPlayAddedSessions, isFalse);
        expect(repository.slice.state.asmrPlaybackCacheEnabled, isTrue);
        final saved =
            json.decode(
                  (await SharedPreferences.getInstance()).getString(
                    'playback_settings_v1',
                  )!,
                )
                as Map<String, dynamic>;
        expect(saved['startupPage'], 'playlist');
        expect(saved['autoPlayAddedSessions'], isFalse);
        expect(saved['asmrPlaybackCacheEnabled'], isTrue);
      },
    );
  });

  group('TimerService', () {
    test('syncSlice includes runtime and draft state', () {
      final service = TimerService();
      addTearDown(service.dispose);

      service
        ..timerMode = TimerMode.trigger
        ..timerDuration = const Duration(minutes: 20)
        ..timerDraftMode = TimerMode.manual
        ..timerDraftDuration = const Duration(minutes: 45)
        ..timerActive = true
        ..timerRemaining = const Duration(minutes: 12)
        ..autoResumeEnabled = true
        ..autoResumeHour = 8
        ..autoResumeMinute = 30
        ..pausedByTimerSessionIds.add('session-a');
      service.syncSlice(isInitialized: true);

      expect(
        service.slice.state,
        isA<TimerStateSliceData>()
            .having((state) => state.mode, 'mode', TimerMode.trigger)
            .having(
              (state) => state.duration,
              'duration',
              const Duration(minutes: 20),
            )
            .having(
              (state) => state.draftDuration,
              'draft duration',
              const Duration(minutes: 45),
            )
            .having((state) => state.active, 'active', isTrue)
            .having(
              (state) => state.remaining,
              'remaining',
              const Duration(minutes: 12),
            )
            .having((state) => state.autoResumeEnabled, 'auto resume', isTrue)
            .having((state) => state.autoResumeHour, 'hour', 8)
            .having((state) => state.autoResumeMinute, 'minute', 30)
            .having(
              (state) => state.pausedByTimerSessionIds,
              'paused session ids',
              orderedEquals(['session-a']),
            ),
      );
    });

    test('syncSlice publishes detached paused session snapshots', () async {
      final service = TimerService();
      addTearDown(service.dispose);

      service.pausedByTimerSessionIds.add('session-a');
      service.syncSlice(isInitialized: true);
      final firstState = service.slice.state;
      final nextStateFuture = service.slice.stream
          .skip(1)
          .first
          .timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      service.pausedByTimerSessionIds.clear();
      expect(firstState.pausedByTimerSessionIds, <String>['session-a']);

      service.syncSlice(isInitialized: true);
      final nextState = await nextStateFuture;

      expect(nextState, isNot(same(firstState)));
      expect(nextState.pausedByTimerSessionIds, isEmpty);
      expect(firstState.pausedByTimerSessionIds, <String>['session-a']);
    });
  });

  group('PlaybackSessionService', () {
    test('registerSession places newly added sessions first', () {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);

      final first = PlaybackSession(
        id: 's1',
        currentTrackPath: '/tracks/one.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.9,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.ready),
      );
      final second = PlaybackSession(
        id: 's2',
        currentTrackPath: '/tracks/two.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.8,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(false, ProcessingState.ready),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      service.registerSession(first);
      service.registerSession(second);

      expect(service.sessionOrder, <String>['s2', 's1']);
      expect(service.activeSessions.map((session) => session.id), ['s2', 's1']);
    });

    test('activeSessions respects session order and playingSessionCount', () {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);

      final first = PlaybackSession(
        id: 's1',
        currentTrackPath: '/tracks/one.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.9,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.ready),
      );
      final second = PlaybackSession(
        id: 's2',
        currentTrackPath: '/tracks/two.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.8,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(true, ProcessingState.ready),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      service.sessions['s1'] = first;
      service.sessions['s2'] = second;
      service.sessionOrder.add('s2');

      final ordered = service.activeSessions;
      expect(ordered.map((session) => session.id), ['s2', 's1']);
      expect(service.playingSessionCount, 1);

      service.markActiveSessionsDirty();
      service.sessionOrder
        ..clear()
        ..add('s1');
      expect(service.activeSessions.map((session) => session.id), ['s1', 's2']);
    });

    test('syncSlice publishes focused session and mode flags', () {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);

      final session = PlaybackSession(
        id: 'focus',
        currentTrackPath: '/tracks/focus.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.8,
        createdAt: DateTime(2026, 1, 3),
        state: PlayerState(true, ProcessingState.ready),
      );
      addTearDown(session.dispose);

      service.syncSlice(
        activeSessions: [session],
        playingSessionCount: 1,
        focusedSessionId: 'focus',
        multiThreadPlaybackEnabled: true,
        coverGeneration: 2,
        isInitialized: true,
      );

      expect(
        service.slice.state,
        isA<PlaybackStateSliceData>()
            .having(
              (state) => state.activeSessions.single.id,
              'session id',
              'focus',
            )
            .having((state) => state.playingSessionCount, 'count', 1)
            .having((state) => state.focusedSessionId, 'focus', 'focus')
            .having(
              (state) => state.multiThreadPlaybackEnabled,
              'multi-thread',
              isTrue,
            )
            .having((state) => state.coverGeneration, 'cover gen', 2),
      );
    });
  });

  group('LibraryService', () {
    MusicTrack track(
      String path, {
      required String groupKey,
      DateTime? modifiedAt,
    }) {
      return MusicTrack(
        path: path,
        displayName: path.split('/').last,
        groupKey: groupKey,
        groupTitle: groupKey.split('/').last,
        groupSubtitle: groupKey,
        isSingle: false,
        modifiedAt: modifiedAt,
      );
    }

    test('addWatchedFolder persists once', () {
      final service = LibraryService();
      addTearDown(service.dispose);
      var persistCount = 0;
      service.library.add(
        track('/music/album/01.mp3', groupKey: '/music/album'),
      );

      expect(
        service.addWatchedFolder('/music', onPersist: () => persistCount++),
        isTrue,
      );

      expect(service.watchedFolders, <String>['/music']);
      expect(persistCount, 1);

      expect(
        service.addWatchedFolder('/music', onPersist: () => persistCount++),
        isFalse,
      );
      expect(persistCount, 1);
    });

    test('watched SAF folders dedupe equivalent tree and document uris', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      const albumTree =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic%2FAlbum';
      const albumDocument =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum';

      expect(service.addWatchedFolder(albumTree), isTrue);
      expect(service.addWatchedFolder(albumDocument), isFalse);
      expect(service.watchedFolders, <String>[albumTree]);
    });

    test(
      'libraryEntryDisplayNameForPath uses normalized O(1) entry lookup',
      () {
        final service = LibraryService();
        addTearDown(service.dispose);

        const libraryPath = '/library';
        const trackPath = '/library/Album/01.mp3';
        service.replaceLibraryEntries(const <LibraryEntry>[
          LibraryEntry(
            libraryPath: libraryPath,
            path: trackPath,
            kind: LibraryEntryKind.track,
            state: LibraryEntryState.active,
            displayName: '  Saved title  ',
          ),
        ]);

        expect(
          service.libraryEntryDisplayNameForPath(
            libraryPath,
            '/library/Album/../Album/01.mp3',
          ),
          'Saved title',
        );
        expect(
          service.libraryEntryDisplayNameForPath(libraryPath, '/missing.mp3'),
          isNull,
        );
      },
    );

    test('library exclusion matcher handles tracks and folder ancestors', () {
      final matcher = LibraryExclusionMatcher(
        libraryPath: '/Music',
        excludedTrackPaths: <String>['/Music/Singles/skip.mp3'],
        excludedFolderPaths: <String>['/Music/Albums/Muted'],
      );

      expect(matcher.isExcluded('/Music/Singles/skip.mp3'), isTrue);
      expect(matcher.isExcluded('/Music/Albums/Muted/01.mp3'), isTrue);
      expect(matcher.isExcluded('/Music/Albums/Muted'), isTrue);
      expect(matcher.isExcluded('/Music/Albums/Active/01.mp3'), isFalse);
    });

    test('library exclusion matcher handles synthetic content URI folders', () {
      const root =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      final matcher = LibraryExclusionMatcher(
        libraryPath: root,
        excludedFolderPaths: <String>['$root::Album/Muted'],
        excludedTrackPaths: <String>['$root::Singles/skip.mp3'],
      );

      expect(matcher.isExcluded('$root::Singles/skip.mp3'), isTrue);
      expect(matcher.isExcluded('$root::Album/Muted/01.mp3'), isTrue);
      expect(matcher.isExcluded('$root::Album/Active/01.mp3'), isFalse);
    });

    test(
      'library entry snapshot filters unchanged entries and remembers updates',
      () {
        final existingTrack = LibraryEntry.track(
          libraryPath: '/library/root',
          track: track(
            '/library/root/Album/01.mp3',
            groupKey: '/library/root/Album',
            modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1000001),
          ),
          parentPath: '/library/root/Album',
          state: LibraryEntryState.active,
        );
        final snapshot = LibraryEntrySnapshot(
          libraryPath: '/library/root',
          entries: <LibraryEntry>[existingTrack],
        );

        expect(snapshot.entryNeedsRefresh(existingTrack), isFalse);
        expect(
          snapshot.entryNeedsRefresh(
            LibraryEntry.track(
              libraryPath: '/library/root',
              track: track(
                '/library/root/Album/01.mp3',
                groupKey: '/library/root/Album',
                modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1000999),
              ),
              parentPath: '/library/root/Album',
              state: LibraryEntryState.active,
            ),
          ),
          isFalse,
        );

        final renamed = LibraryEntry.track(
          libraryPath: '/library/root',
          track: MusicTrack(
            path: '/library/root/Album/01.mp3',
            displayName: '01 renamed.mp3',
            groupKey: '/library/root/Album',
            groupTitle: 'Album',
            groupSubtitle: '/library/root/Album',
            isSingle: false,
          ),
          parentPath: '/library/root/Album',
          state: LibraryEntryState.active,
        );

        expect(snapshot.entryNeedsRefresh(renamed), isTrue);
        snapshot.remember(<LibraryEntry>[renamed]);
        expect(snapshot.entryNeedsRefresh(renamed), isFalse);
      },
    );

    test('removeLibrary clears SAF child folders and exclusions', () async {
      final service = LibraryService();
      addTearDown(service.dispose);

      const root =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      const albumTree =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic%2FAlbum';
      const albumDocument =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum';

      service
        ..watchedLibraries.add(root)
        ..watchedFolders.add(albumTree)
        ..excludedLibraryFolders[root] = <String>{albumDocument}
        ..excludedLibraryTracks[root] = <String>{
          '$albumDocument/document/primary%3AMusic%2FAlbum%2F01.mp3',
        };

      final removal = service.removeLibrary(root);

      expect(removal.removedFolderPaths, <String>[albumTree]);
      expect(removal.changed, isTrue);
      expect(service.watchedFolders, isEmpty);
      expect(service.watchedLibraries, isEmpty);
      expect(service.excludedLibraryFolders, isEmpty);
      expect(service.excludedLibraryTracks, isEmpty);
    });

    test('folder exclusion reports changed entry paths with one revision', () {
      final service = LibraryService();
      addTearDown(service.dispose);
      const root = '/library/root';
      const folder = '$root/work';
      const trackPath = '$folder/01.mp3';
      service.replaceLibraryEntries(<LibraryEntry>[
        LibraryEntry.folder(
          libraryPath: root,
          path: folder,
          displayName: 'work',
          parentPath: root,
          state: LibraryEntryState.active,
        ),
        LibraryEntry.track(
          libraryPath: root,
          track: MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: folder,
            groupTitle: 'work',
            groupSubtitle: folder,
            isSingle: false,
          ),
          parentPath: folder,
          state: LibraryEntryState.active,
        ),
      ]);
      final beforeRevision = service.structureRevision;

      final mutation = service.setLibraryFolderExcluded(root, folder, true);

      expect(mutation.changed, isTrue);
      expect(mutation.affectedEntryPaths, <String>[folder, trackPath]);
      expect(service.structureRevision, beforeRevision + 1);
    });

    test('library entry pruning retains normalized equivalent file paths', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      const root = '/library/root';
      const trackPath = '$root/track.mp3';
      service.replaceLibraryEntries(<LibraryEntry>[
        LibraryEntry.track(
          libraryPath: root,
          track: MusicTrack(
            path: trackPath,
            displayName: 'track',
            groupKey: root,
            groupTitle: 'root',
            groupSubtitle: root,
            isSingle: false,
          ),
          parentPath: root,
          state: LibraryEntryState.active,
        ),
      ]);

      final removed = service.removeLibraryEntriesMissingFromFolderScan(
        root,
        root,
        const <String>{'$root/album/../track.mp3'},
      );

      expect(removed, isEmpty);
      expect(service.libraryEntriesForLibrary(root), hasLength(1));
    });

    test('syncSlice reflects scan and structure metadata', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      service
        ..library.addAll([])
        ..watchedFolders.add('/music')
        ..watchedLibraries.add('/library')
        ..isScanning = true
        ..isBackgroundScanning = true
        ..scanCurrentFolder = '/music/album'
        ..scanFoundCount = 4
        ..scanDuplicateCount = 1
        ..scanFailureCount = 2;
      service.markStructureChanged();
      service.syncSlice(isInitialized: true, detailRevision: 0);

      expect(
        service.slice.state,
        isA<LibraryState>()
            .having((state) => state.watchedFolderCount, 'folders', 1)
            .having((state) => state.watchedLibraryCount, 'libraries', 1)
            .having((state) => state.isScanning, 'scanning', isTrue)
            .having(
              (state) => state.isBackgroundScanning,
              'background scanning',
              isTrue,
            )
            .having(
              (state) => state.scanCurrentFolder,
              'current folder',
              '/music/album',
            )
            .having((state) => state.scanFoundCount, 'found', 4)
            .having((state) => state.scanDuplicateCount, 'duplicates', 1)
            .having((state) => state.scanFailureCount, 'failures', 2)
            .having((state) => state.structureRevision, 'revision', 1),
      );
    });

    test('replacing library entries does not invalidate the main tree', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      expect(service.structureRevision, 0);

      service.replaceLibraryEntries([
        LibraryEntry.folder(
          libraryPath: '/library/root',
          path: '/library/root/Album',
          displayName: 'Album',
          parentPath: '/library/root',
          state: LibraryEntryState.active,
        ),
      ]);

      expect(service.structureRevision, 0);
    });

    test('removing stale library entries leaves tree revision untouched', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      service.replaceLibraryEntries([
        LibraryEntry.track(
          libraryPath: '/library/root',
          track: track(
            '/library/root/Album/01.mp3',
            groupKey: '/library/root/Album',
          ),
          parentPath: '/library/root/Album',
          state: LibraryEntryState.active,
        ),
      ]);

      final beforeRevision = service.structureRevision;
      final removedPaths = service.removeLibraryEntriesMissingFromFolderScan(
        '/library/root',
        '/library/root/Album',
        const <String>{},
      );

      expect(removedPaths, ['/library/root/Album/01.mp3']);
      expect(service.structureRevision, beforeRevision);
    });
  });
}
