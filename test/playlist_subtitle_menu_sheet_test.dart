import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_menu_sheet.dart';

PlaybackSessionSnapshot _createSnapshot({required String trackPath}) {
  return PlaybackSessionSnapshot(
    id: 'test-session',
    createdAt: DateTime(2026),
    lastPlayedAt: null,
    currentTrackPath: trackPath,
    loadedPath: trackPath,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.crossSequential,
    volume: 1,
    channelSwapEnabled: false,
    position: Duration.zero,
    duration: const Duration(minutes: 1),
    bufferedPosition: Duration.zero,
    speed: 1,
    audioEffects: AudioEffectsState.flat,
    eqCapabilities: EqCapabilities.unsupported,
    state: const PlaybackStatus(
      playing: true,
      processing: PlaybackProcessingStatus.ready,
    ),
    effectivePlaying: true,
    playbackRequested: true,
    isLoading: false,
    isPlaybackLoading: false,
    playbackError: null,
    currentQueueIndex: 0,
    playbackQueue: null,
    customQueueTracks: null,
    positionStream: const Stream<Duration>.empty(),
    durationStream: const Stream<Duration?>.empty(),
    bufferedPositionStream: const Stream<Duration>.empty(),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'SubtitleMenuSheet disables and greys out switches and sync controls when no subtitle',
    (tester) async {
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      final session = _createSnapshot(trackPath: '/path/to/no_subtitle_audio.mp3');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              AppLanguageProvider(),
            ),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: session,
                onToggleGlobalSubtitle: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find both SwitchListTiles
      final switchTiles = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList(growable: false);
      expect(switchTiles.length, 2);

      // Both switch tiles should be disabled (onChanged == null)
      expect(switchTiles[0].onChanged, isNull);
      expect(switchTiles[1].onChanged, isNull);

      // Verify sync buttons are all disabled (onPressed == null)
      final buttons = tester
          .widgetList<OutlinedButton>(find.byType(OutlinedButton))
          .toList(growable: false);
      // There are 5 sync control buttons
      expect(buttons.length, 5);
      for (final button in buttons) {
        expect(button.onPressed, isNull);
      }
    },
  );

  testWidgets(
    'SubtitleMenuSheet enables switches and sync controls when subtitle is present',
    (tester) async {
      const audioPath = '/path/to/has_subtitle_audio.mp3';
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (trackPath, track) async => SubtitleTrack(
          sourcePath: 'sub.lrc',
          cues: const [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 5),
              text: 'test lyric',
            ),
          ],
        ),
      );

      await service.load(audioPath);

      final session = _createSnapshot(trackPath: audioPath);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              AppLanguageProvider(),
            ),
            playbackSubtitleServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleMenuSheet(
                session: session,
                onToggleGlobalSubtitle: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find both SwitchListTiles
      final switchTiles = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList(growable: false);
      expect(switchTiles.length, 2);

      // Both switch tiles should be enabled (onChanged != null)
      expect(switchTiles[0].onChanged, isNotNull);
      expect(switchTiles[1].onChanged, isNotNull);

      // Verify step sync buttons (-0.5s, -0.1s, +0.1s, +0.5s) are enabled
      final buttons = tester
          .widgetList<OutlinedButton>(find.byType(OutlinedButton))
          .toList(growable: false);
      expect(buttons.length, 5);
      expect(buttons[0].onPressed, isNotNull); // -0.5s
      expect(buttons[1].onPressed, isNotNull); // -0.1s
      // buttons[2] is reset, offset is zero so reset is null
      expect(buttons[3].onPressed, isNotNull); // +0.1s
      expect(buttons[4].onPressed, isNotNull); // +0.5s
    },
  );
}
