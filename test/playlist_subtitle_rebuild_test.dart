import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

class _CountingSessionCard extends SessionListCard {
  const _CountingSessionCard({
    required super.sessionId,
    required super.track,
    required super.library,
    required super.playback,
    required this.onBuild,
  }) : super(
         coverPath: null,
         coverGeneration: 0,
         coverCacheWidth: null,
         isTemporary: false,
         onOpen: _noop,
       );

  final VoidCallback onBuild;

  static void _noop() {}

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    return super.build(context, ref);
  }
}

void main() {
  testWidgets('subtitle toggle rebuilds only its session card', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final tracks = [
      testMusicTrack(
        name: 'First',
        path: '/music/first.mp3',
        groupKey: '/music/first',
        groupTitle: 'First',
      ),
      testMusicTrack(
        name: 'Second',
        path: '/music/second.mp3',
        groupKey: '/music/second',
        groupTitle: 'Second',
      ),
    ];
    fixture.library.addTracks(tracks, notify: false, persist: false);
    final sessions = [
      for (final track in tracks) fixture.playback.createTrackSession(track),
    ];
    for (final session in sessions) {
      addTearDown(session.shutdown);
    }
    fixture.playbackService.syncSlice(
      activeSessions: sessions,
      playingSessionCount: 0,
      focusedSessionId: sessions.first.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    final builds = <String, int>{};
    await tester.pumpWidget(
      fixture.build(
        ListView(
          children: [
            for (var index = 0; index < sessions.length; index++)
              _CountingSessionCard(
                sessionId: sessions[index].id,
                track: tracks[index],
                library: fixture.library,
                playback: fixture.playback,
                onBuild: () => builds.update(
                  sessions[index].id,
                  (count) => count + 1,
                  ifAbsent: () => 1,
                ),
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(builds.keys, containsAll(sessions.map((session) => session.id)));
    final firstBuilds = builds[sessions.first.id]!;
    final secondBuilds = builds[sessions.last.id]!;

    ProviderScope.containerOf(
          tester.element(find.byType(_CountingSessionCard).first),
        )
        .read(subtitleSettingsProvider.notifier)
        .setGlobalEnabled(sessions.first.id, true);
    await tester.pump();

    expect(builds[sessions.first.id], greaterThan(firstBuilds));
    expect(builds[sessions.last.id], secondBuilds);
  });
}
