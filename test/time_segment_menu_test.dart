import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/time_segment_label.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_time_segments.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_content.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'segment menu targets an unselected label and ignores a stale track on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = platform == TargetPlatform.windows
            ? const Size(1280, 900)
            : const Size(430, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Track with segments',
          path: '/segments/track.mp3',
          groupKey: '/segments',
          groupTitle: 'Segments',
        );
        final nextTrack = testMusicTrack(
          name: 'Another track',
          path: '/segments/next.mp3',
          groupKey: '/segments',
          groupTitle: 'Segments',
        );
        fixture.library.addTracks([track, nextTrack], persist: false);
        final session = fixture.playback.createTrackSession(track);
        session.setOptimisticPosition(const Duration(seconds: 12));
        final trackKey = TimeSegmentLabel.trackKeyFor(track);
        final date = DateTime(2026);
        final first = TimeSegmentLabel(
          id: 'first-segment',
          trackKey: trackKey,
          name: 'First segment',
          start: Duration.zero,
          end: const Duration(seconds: 5),
          colorValue: 0xff607d8b,
          createdAt: date,
          updatedAt: date,
        );
        final second = first.copyWith(
          id: 'second-segment',
          name: 'Second segment',
          start: const Duration(seconds: 10),
          end: const Duration(seconds: 20),
        );
        await tester.runAsync(() async {
          await fixture.persistenceRepository.upsertTimeSegmentLabel(first);
          await fixture.persistenceRepository.upsertTimeSegmentLabel(second);
        });

        final detail = GlobalKey<SessionDetailContentState>();
        await tester.pumpWidget(
          fixture.build(
            Scaffold(
              body: SessionDetailContent(
                key: detail,
                session: PlaybackSessionSnapshot.fromRuntime(session),
                artworkWidget: const SizedBox.shrink(),
                isLandscape: platform == TargetPlatform.windows,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        detail.currentState!.expandSegmentPanel();
        await tester.pumpAndSettle();
        tester
            .widget<SegmentPanelPageHeader>(find.byType(SegmentPanelPageHeader))
            .onSelected(3);
        final firstChip = find.widgetWithText(TimeSegmentChip, first.name);
        final secondChip = find.widgetWithText(TimeSegmentChip, second.name);
        await pumpUntilFound(tester, firstChip);
        await tester.pumpAndSettle();
        await tester.tap(firstChip);
        await tester.pumpAndSettle();

        final nameField = find.byType(TextField);
        final startRow = find.widgetWithText(
          SegmentTimeRow,
          fixture.languageProvider.tr('segment_start'),
        );
        final endRow = find.widgetWithText(
          SegmentTimeRow,
          fixture.languageProvider.tr('segment_end'),
        );
        final nameBounds = tester.getRect(nameField);
        final startBounds = tester.getRect(startRow);
        final endBounds = tester.getRect(endRow);
        expect(nameBounds.bottom, lessThan(startBounds.top));
        expect(startBounds.top, endBounds.top);
        expect(startBounds.left, nameBounds.left);
        expect(endBounds.right, closeTo(nameBounds.right, 0.01));

        if (platform == TargetPlatform.android) {
          final originalSize = tester.view.physicalSize;
          tester.view.physicalSize = const Size(320, 900);
          await tester.pumpAndSettle();
          final narrowStart = tester.getRect(startRow);
          final narrowEnd = tester.getRect(endRow);
          expect(narrowStart.bottom, lessThan(narrowEnd.top));
          expect(narrowStart.left, narrowEnd.left);
          expect(narrowStart.width, narrowEnd.width);
          expect(tester.takeException(), isNull);
          tester.view.physicalSize = originalSize;
          await tester.pumpAndSettle();
        }

        TimeSegmentPanel panel() =>
            tester.widget<TimeSegmentPanel>(find.byType(TimeSegmentPanel));
        final i18n = fixture.languageProvider;
        final edit = find.text(i18n.tr('segment_edit'));
        final loop = find.text(i18n.tr('segment_menu_loop'));
        final stop = find.text(i18n.tr('segment_stop_loop'));
        final remove = find.text(i18n.tr('remove')).last;
        final chipSurface = find.descendant(
          of: secondChip,
          matching: find.byType(Material),
        );
        final menuHighlight = find.ancestor(
          of: secondChip,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.position == DecorationPosition.foreground &&
                widget.decoration is ShapeDecoration,
          ),
        );
        Future<void> openSecondMenu() async {
          await tester.ensureVisible(secondChip);
          await tester.pumpAndSettle();
          if (platform == TargetPlatform.windows) {
            await tester.tap(
              secondChip,
              kind: PointerDeviceKind.mouse,
              buttons: kSecondaryMouseButton,
            );
          } else {
            await tester.longPress(secondChip);
          }
          await tester.pumpAndSettle();
          expect(edit, findsOneWidget);
        }

        await openSecondMenu();
        expect(tester.getRect(menuHighlight), tester.getRect(chipSurface));
        expect(panel().selectedId, first.id);
        await tester.tap(loop);
        await tester.pumpAndSettle();
        expect(panel().loopSegmentId, second.id);
        expect(panel().selectedId, first.id);

        await openSecondMenu();
        await tester.tap(stop);
        await tester.pumpAndSettle();
        expect(panel().loopSegmentId, isNull);
        expect(panel().selectedId, first.id);

        await openSecondMenu();
        await tester.tap(edit);
        await tester.pumpAndSettle();
        expect(panel().selectedId, second.id);
        expect(panel().nameController.text, second.name);
        expect(panel().draftStart, second.start);
        expect(panel().draftEnd, second.end);

        await tester.tap(firstChip);
        await tester.pumpAndSettle();
        await openSecondMenu();
        const pendingName = 'First edited';
        panel().nameController.text = pendingName;
        await tester.tap(remove);
        await pumpUntilNotFound(tester, secondChip);
        expect(panel().selectedId, first.id);
        expect(panel().nameController.text, pendingName);

        final undo = find.textContaining(i18n.tr('undo'));
        await pumpUntilFound(tester, undo);
        await tester.tap(undo);
        await pumpUntilFound(tester, secondChip);
        await tester.pumpAndSettle();
        final persisted = await tester.runAsync(
          () => fixture.persistenceRepository.loadTimeSegmentLabels(trackKey),
        );
        expect(persisted!.map((label) => label.id), [first.id, second.id]);
        expect(persisted.first.name, pendingName);
        expect(panel().selectedId, first.id);
        expect(panel().nameController.text, pendingName);

        await openSecondMenu();
        session.currentTrackPath = nextTrack.path;
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(secondChip, findsOneWidget);
        expect(panel().selectedId, first.id);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
