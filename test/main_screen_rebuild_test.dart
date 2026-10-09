import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets(
    'sidebar animation reuses main navigation while content keeps resizing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture(
        configureSettingsRepository: (settings) {
          settings.showAsmrOne = false;
          settings.showLocalLibrary = false;
        },
      );
      addTearDown(fixture.dispose);
      fixture.settings.syncSlice(isInitialized: true);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      fixture.playbackService.syncSlice(
        activeSessions: [],
        playingSessionCount: 0,
        focusedSessionId: null,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(
          const MainScreen(),
          overrides: [
            settingsStateProvider.overrideWithValue(
              AsyncData(fixture.settings.slice.state),
            ),
            mainOverlayUiProvider.overrideWithValue(
              const MainOverlayUiState(
                overlaySessions: [],
                playingSessionCount: 0,
                hasPlayingAudioSession: false,
                activeSessionCount: 0,
                isInitialized: true,
                startupReady: true,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final navigation = tester.element(find.byType(DesktopMainNavigation));
      final content = find.byKey(const ValueKey('main_content_region'));
      final expandedContentWidth = tester.getSize(content).width;
      await tester.tap(find.byIcon(Icons.menu_open_rounded));
      await tester.pump();

      var navigationBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (identical(element, navigation)) navigationBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final movingContentWidth = tester.getSize(content).width;
      expect(movingContentWidth, greaterThan(expandedContentWidth));
      expect(movingContentWidth, lessThan(1200));
      expect(navigationBuilds, 0);
      debugOnRebuildDirtyWidget = previous;
      await tester.pumpAndSettle();
      expect(tester.getSize(content).width, 1200);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
