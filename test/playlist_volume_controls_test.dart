import 'package:doujin_audio/app/presentation/global_shortcuts.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_transport_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

class _VolumeRepository extends NativePlaybackRepository {
  bool failVolume = false;
  final List<double> volumes = [];

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) async {
    volumes.add(volume);
    return failVolume
        ? const NativeFailure('Volume change failed')
        : const NativeSuccess();
  }
}

void main() {
  AppRuntimeTestFixture.initialize();

  for (final action in ['drag', 'input', 'mute', 'unmute']) {
    for (final failVolume in [false, true]) {
      testWidgets(
        'volume $action follows ${failVolume ? 'failed command rollback' : 'external updates'}',
        (tester) async {
          final repository = _VolumeRepository()
            ..failVolume = failVolume && action != 'unmute';
          final fixture = AppRuntimeWidgetTestFixture(
            providedNativePlaybackRepository: repository,
          );
          addTearDown(fixture.dispose);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            notificationsChannel,
            (_) async => <String, Object?>{'ok': true, 'value': null},
          );
          addTearDown(
            () =>
                messenger.setMockMethodCallHandler(notificationsChannel, null),
          );
          final track = testMusicTrack(
            name: 'Volume test',
            path: '/music/volume.mp3',
            groupKey: '/music',
            groupTitle: 'Music',
          );
          fixture.library.addTracks([track], persist: false);
          final session = fixture.playback.createTrackSession(track)
            ..loadedPath = track.path;
          fixture.playbackService.syncSlice(
            activeSessions: [session],
            playingSessionCount: 0,
            focusedSessionId: session.id,
            coverGeneration: 0,
            isInitialized: true,
          );
          await tester.pumpWidget(
            fixture.build(
              GlobalShortcuts(
                child: TransportPlaybackControlPanel(
                  session: fixture.playback.sessionSnapshotById(session.id)!,
                  playback: fixture.playback,
                  hasSiblings: false,
                  segmentPanelExpanded: false,
                  hasSubtitle: false,
                  subtitleEnabled: false,
                  subtitleGlobalEnabled: false,
                  onShowTrackSwitcher: () {},
                  onToggleSegments: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          ProviderScope.containerOf(
            tester.element(find.byType(TransportPlaybackControlPanel)),
          ).read(activeSessionDetailIdsProvider.notifier).push(session.id);
          await tester.tap(
            find.byKey(const ValueKey('session_volume_button_anchor')),
          );
          await tester.pumpAndSettle();
          final slider = find.byKey(const ValueKey('session_volume_slider'));
          switch (action) {
            case 'drag':
              tester.widget<Slider>(slider).onChanged!(0.5);
              await tester.pump();
              expect(tester.widget<Slider>(slider).value, 0.5);
              expect(find.text('50%'), findsOneWidget);
              tester.widget<Slider>(slider).onChangeEnd!(0.5);
            case 'input':
              await tester.tap(
                find.byKey(const ValueKey('session_volume_percent_text')),
              );
              await tester.pumpAndSettle();
              await tester.enterText(find.byType(TextFormField), '50');
              await tester.tap(
                find.text(fixture.languageProvider.tr('confirm')),
              );
            case 'mute':
              await tester.tap(
                find.byKey(const ValueKey('session_volume_mute_button')),
              );
            case 'unmute':
              await tester.tap(
                find.byKey(const ValueKey('session_volume_mute_button')),
              );
              await tester.pumpAndSettle();
              expect(session.volume, 0);
              repository.failVolume = failVolume;
              await tester.tap(
                find.byKey(const ValueKey('session_volume_mute_button')),
              );
          }
          await tester.pumpAndSettle();
          final requestedVolume = switch (action) {
            'mute' => 0.0,
            'unmute' => 1.0,
            _ => 0.5,
          };
          expect(repository.volumes, contains(requestedVolume));
          final previousVolume = action == 'unmute' ? 0.0 : 1.0;
          expect(session.volume, failVolume ? previousVolume : requestedVolume);
          expect(tester.widget<Slider>(slider).value, session.volume);
          expect(
            find.text('${(session.volume * 100).round()}%'),
            findsOneWidget,
          );
          if (!failVolume) {
            if (defaultTargetPlatform == TargetPlatform.windows) {
              final decrease = action == 'unmute';
              await tester.sendKeyEvent(
                decrease
                    ? LogicalKeyboardKey.arrowDown
                    : LogicalKeyboardKey.arrowUp,
              );
              expect(
                session.volume,
                closeTo(requestedVolume + (decrease ? -0.05 : 0.05), 0.001),
              );
            } else {
              // Acknowledge the pending command before a later native change.
              for (final volume in [requestedVolume, 0.2]) {
                fixture.playback.applyNativeSnapshot(
                  NativePlaybackSnapshot(
                    sessionId: session.id,
                    path: track.path,
                    playing: false,
                    playWhenReady: false,
                    processingState: 'ready',
                    position: Duration.zero,
                    bufferedPosition: Duration.zero,
                    volume: volume,
                    boostGain: 1,
                    channelSwapEnabled: false,
                  ),
                  hasLibraryTrack: (_) => true,
                );
              }
              expect(session.volume, 0.2);
            }
            await tester.pumpAndSettle();
            expect(tester.widget<Slider>(slider).value, session.volume);
            expect(
              find.text('${(session.volume * 100).round()}%'),
              findsOneWidget,
            );
          }
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('session_volume_mute_button')),
                )
                .tooltip,
            fixture.languageProvider.tr(
              session.volume == 0 ? 'unmute' : 'mute',
            ),
          );
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }
  }
}
