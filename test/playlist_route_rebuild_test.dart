import 'dart:async';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:flutter/services.dart';

import 'package:doujin_audio/app/presentation/browse_page_scroll.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final count in [1, 80]) {
    testWidgets(
      'played hidden playlist retains its content across routes ($count sessions)',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel(NotificationsChannel.name);
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'ok': true, 'value': null},
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final index = ValueNotifier(0);
        addTearDown(index.dispose);
        final tracks = List.generate(
          count,
          (i) => testMusicTrack(
            name: 'Track $i',
            path: '/music/$i.mp3',
            groupKey: '/music/$i',
            groupTitle: 'Work $i',
          ),
        );
        fixture.library.addTracks(tracks, persist: false);
        final sessions = [
          for (final track in tracks)
            fixture.playback.createTrackSession(track),
        ];
        fixture.playbackService.syncSlice(
          activeSessions: sessions,
          playingSessionCount: 0,
          focusedSessionId: sessions.first.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pumpWidget(
          fixture.build(
            AppFadeThroughIndexedStack.lazy(
              indexListenable: index,
              itemCount: 2,
              itemBuilder: (_, i) => i == 0
                  ? PlaylistTab(tabIndex: 0, activeTabIndexListenable: index)
                  : const Center(child: Text('settings-root')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The same structural notification that starting playback publishes.
        sessions.first.lastPlayedAt = DateTime.now();
        fixture.playbackService.publishSession(sessions.first);
        await tester.pumpAndSettle();
        index.value = 1;
        await tester.pumpAndSettle();
        final playlist = tester.element(
          find.byType(PlaylistTab, skipOffstage: false),
        );
        final content = tester.widget<BrowsePageScroll>(
          find.byType(BrowsePageScroll, skipOffstage: false),
        );
        var rebuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (identical(element, playlist)) rebuilds++;
        };
        try {
          final context = tester.element(find.text('settings-root'));
          final navigator = Navigator.of(context);
          for (var depth = 0; depth < 2; depth++) {
            unawaited(
              navigator.push(
                buildAppPageRoute<void>(
                  context: context,
                  child: Scaffold(body: Text('child-$depth')),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          for (var depth = 0; depth < 2; depth++) {
            navigator.pop();
            await tester.pumpAndSettle();
          }
          expect(rebuilds, 0);
          expect(
            tester.widget<BrowsePageScroll>(
              find.byType(BrowsePageScroll, skipOffstage: false),
            ),
            same(content),
          );
        } finally {
          debugOnRebuildDirtyWidget = previous;
        }
        index.value = 0;
        await tester.pumpAndSettle();
        expect(find.byType(PlaylistTab), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}
