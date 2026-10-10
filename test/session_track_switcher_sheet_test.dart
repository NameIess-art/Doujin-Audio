import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_track_switcher_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

MusicTrack _track(String relativePath) => MusicTrack(
  path: '/work/$relativePath',
  displayName: relativePath.split('/').last,
  groupKey: '/work',
  groupTitle: 'Work',
  groupSubtitle: '',
  isSingle: false,
);

PlaybackSessionSnapshot _session(
  List<MusicTrack> tracks, {
  PlaybackQueueDefinition? queue,
  int currentQueueIndex = 0,
  String? currentPath,
}) {
  final session = PlaybackSession(
    id: 'test',
    currentTrackPath: currentPath ?? tracks.first.path,
    currentQueueIndex: currentQueueIndex,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.single,
    volume: 1,
    createdAt: DateTime(2026),
    state: const PlayerState(false, ProcessingState.ready),
    playbackQueue: queue,
  );
  addTearDown(session.shutdown);
  return PlaybackSessionSnapshot.fromRuntime(session);
}

Future<void> _pumpSheet(
  WidgetTester tester,
  List<MusicTrack> tracks, {
  PlaybackQueueDefinition? queue,
  int currentQueueIndex = 0,
  String? currentPath,
  bool reduceAnimations = false,
  ValueChanged<SessionTrackSelection>? onSelected,
}) async {
  SharedPreferences.setMockInitialValues({});
  final language = AppLanguageProvider();
  await language.initialized;
  addTearDown(language.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appLanguageProviderInstanceProvider.overrideWithValue(language),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceAnimations),
          child: child!,
        ),
        home: Scaffold(
          body: SessionTrackSwitcherSheet(
            tracks: tracks,
            session: _session(
              tracks,
              queue: queue,
              currentQueueIndex: currentQueueIndex,
              currentPath: currentPath,
            ),
            workRoot: '/work',
            resolveTrack: (_) => null,
            workRootForTrack: (_) => '/work',
            onSelected: onSelected ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _trackRows() => find.byWidgetPredicate(
  (widget) =>
      widget is Material &&
      widget.key.toString().contains('queue_switcher_track_'),
);

Future<void> _jumpToEnd(WidgetTester tester, ScrollPosition position) async {
  for (var i = 0; i < 4; i++) {
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'switcher keeps 44 pixel rows and centers one or two name lines',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const longFolder = 'A long folder name that needs two lines';
      const longTrack = 'A long audio filename that needs two lines.mp3';
      const nestedTrack =
          'Another long audio filename that needs two lines.mp3';
      final tracks = [
        _track('Short'),
        _track(longTrack),
        _track('Disc/Other'),
        _track('$longFolder/$nestedTrack'),
      ];
      await _pumpSheet(tester, tracks);
      for (final folder in ['Disc', longFolder]) {
        await tester.tap(find.text(folder));
        await tester.pumpAndSettle();
      }
      final rows = find.byType(FileTreeRow);
      expect(rows, findsNWidgets(6));
      for (var index = 0; index < 6; index++) {
        final row = rows.at(index);
        final title = tester.widget<FileTreeRow>(row).title;
        final textFinder = find.descendant(of: row, matching: find.text(title));
        final text = tester.widget<Text>(textFinder);
        final nameRect = tester.getRect(textFinder);
        final rowRect = tester.getRect(row);
        expect(rowRect.height, 44);
        expect(text.maxLines, 2);
        expect(nameRect.center.dy, closeTo(rowRect.center.dy, 0.01));
        final painter = TextPainter(
          text: TextSpan(text: title, style: text.style),
          textDirection: TextDirection.ltr,
          maxLines: 2,
          ellipsis: '…',
        )..layout(maxWidth: nameRect.width);
        expect(painter.computeLineMetrics().length, title.length > 20 ? 2 : 1);
        painter.dispose();
      }
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('switcher icons use local and ASMR work accents', (tester) async {
    final tracks = [
      _track('local.mp3'),
      _track(
        'disc/remote.mp3',
      ).copyWith(remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne),
    ];
    await _pumpSheet(tester, tracks);
    await tester.tap(find.text('disc'));
    await tester.pumpAndSettle();
    final primary = Theme.of(
      tester.element(find.byType(FileTreeRow).first),
    ).colorScheme.primary;
    final expected = {
      'disc': AppDesignTokens.folderIconColor,
      'local.mp3': primary,
      'remote.mp3': AppDesignTokens.light.asmrAccent,
    };
    for (final entry in expected.entries) {
      final row = find.ancestor(
        of: find.text(entry.key),
        matching: find.byType(FileTreeRow),
      );
      final icon = find.descendant(of: row, matching: find.byType(Icon)).first;
      expect(tester.widget<Icon>(icon).color, entry.value);
    }
  });

  for (final reduceAnimations in [false, true]) {
    testWidgets(
      'folder rows have rounded ink and animate both directions (reduced=$reduceAnimations)',
      (tester) async {
        final tracks = [_track('Current'), _track('disc/Other')];
        SessionTrackSelection? selected;
        await _pumpSheet(
          tester,
          tracks,
          reduceAnimations: reduceAnimations,
          onSelected: (value) => selected = value,
        );
        final folder = find.text('disc');
        final folderInk = tester.widget<InkWell>(
          find.ancestor(of: folder, matching: find.byType(InkWell)),
        );
        final folderMaterial = tester.widget<Material>(
          find.ancestor(of: folder, matching: find.byType(Material)).first,
        );
        const radius = BorderRadius.all(Radius.circular(12));
        expect(folderInk.borderRadius, radius);
        expect(folderMaterial.borderRadius, radius);
        expect(folderMaterial.clipBehavior, Clip.antiAlias);

        final leaf = find.byKey(
          ValueKey('queue_switcher_track_${tracks.last.path}'),
        );
        Finder sizeTransition() =>
            find.ancestor(of: leaf, matching: find.byType(SizeTransition));
        Finder fadeTransition() => find
            .ancestor(of: leaf, matching: find.byType(FadeTransition))
            .first;
        expect(leaf, findsNothing);
        await tester.tap(folder);
        await tester.pump();
        if (!reduceAnimations) {
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            tester.widget<SizeTransition>(sizeTransition()).sizeFactor.value,
            inExclusiveRange(0.2, 1),
          );
          expect(
            tester.widget<FadeTransition>(fadeTransition()).opacity.value,
            inExclusiveRange(0, 1),
          );
        }
        await tester.pumpAndSettle();
        expect(leaf, findsOneWidget);
        final rows = find.byType(FileTreeRow);
        for (var index = 0; index < 3; index++) {
          expect(tester.getSize(rows.at(index)).height, 44);
          if (index > 0) {
            expect(
              tester.getRect(rows.at(index)).top,
              tester.getRect(rows.at(index - 1)).bottom,
            );
          }
        }
        expect(
          tester.widget<SizeTransition>(sizeTransition()).sizeFactor.value,
          1,
        );
        await tester.tap(folder);
        await tester.pump();
        if (!reduceAnimations) {
          await tester.pump(const Duration(milliseconds: 80));
          expect(leaf, findsOneWidget);
          expect(
            tester.widget<SizeTransition>(sizeTransition()).sizeFactor.value,
            inExclusiveRange(0.2, 1),
          );
          await tester.tap(leaf, warnIfMissed: false);
          expect(selected, isNull);
        }
        await tester.pumpAndSettle();
        expect(leaf, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'rapid nested folder toggles retain the final rows on $platform',
      (tester) async {
        final tracks = [
          _track('Current'),
          _track('disc/nested/Other'),
          _track('disc/Last'),
        ];
        SessionTrackSelection? selected;
        await _pumpSheet(
          tester,
          tracks,
          onSelected: (value) => selected = value,
        );
        await tester.tap(find.text('disc'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('nested'));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.text('disc'));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.text('disc'));
        await tester.pumpAndSettle();
        expect(find.text('Other'), findsOneWidget);
        expect(find.text('Last'), findsOneWidget);
        await tester.tap(find.text('Other'));
        expect(selected?.queueIndex, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'large selected folder uses lazy rows and preserves queueIndex on $platform',
      (tester) async {
        final tracks = [for (var i = 0; i < 2000; i++) _track('disc/Track $i')];
        SessionTrackSelection? selected;
        await _pumpSheet(
          tester,
          tracks,
          onSelected: (value) => selected = value,
        );
        expect(find.text('disc'), findsOneWidget);
        expect(find.text('Track 0'), findsOneWidget);
        expect(find.text('Track 1999'), findsNothing);
        expect(_trackRows().evaluate().length, lessThan(30));
        void toggleFolder() {
          final ink = tester.widget<InkWell>(
            find
                .ancestor(of: find.text('disc'), matching: find.byType(InkWell))
                .first,
          );
          final baseline = tester.binding.transientCallbackCount;
          ink.onTap!();
          // Isolate expansion from desktop hover and ink animations.
          expect(
            tester.binding.transientCallbackCount - baseline,
            lessThanOrEqualTo(1),
          );
        }

        toggleFolder();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(_trackRows().evaluate().length, lessThan(100));
        await tester.pumpAndSettle();
        expect(_trackRows(), findsNothing);
        toggleFolder();
        await tester.pump();
        expect(_trackRows().evaluate().length, lessThan(100));
        await tester.pumpAndSettle();
        expect(find.text('Track 0'), findsOneWidget);
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        await _jumpToEnd(tester, position);
        expect(find.text('Track 1999'), findsOneWidget);
        expect(_trackRows().evaluate().length, lessThan(30));
        await tester.tap(find.text('Track 1999'));
        expect(selected?.track, same(tracks.last));
        expect(selected?.queueIndex, 1999);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'same-title queue works expand independently and retain natural order',
    (tester) async {
      final tracks = [_track('Track 10'), _track('Track 2')];
      final queue = PlaybackQueueDefinition(
        name: 'Queue',
        entries: [
          for (final id in ['first', 'second'])
            PlaybackQueueEntry(
              id: id,
              kind: PlaybackQueueEntryKind.work,
              title: 'work',
              workRootPath: '/work',
              tracks: tracks,
            ),
        ],
      );
      SessionTrackSelection? selected;
      await _pumpSheet(
        tester,
        queue.expandedTracks,
        queue: queue,
        onSelected: (value) => selected = value,
      );
      expect(find.text('work'), findsNWidgets(2));
      expect(find.text('Track 2'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Track 2')).dy,
        lessThan(tester.getTopLeft(find.text('Track 10')).dy),
      );
      await tester.tap(find.text('work').last);
      await tester.pumpAndSettle();
      expect(find.text('Track 2'), findsNWidgets(2));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is InkWell && widget.onTap == null,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Track 10').last);
      expect(selected?.queueIndex, 2);
      await tester.tap(find.text('Track 2').last);
      expect(selected?.queueIndex, 3);
      await tester.tap(find.text('work').first);
      await tester.pumpAndSettle();
      expect(find.text('Track 2'), findsOneWidget);
      await tester.tap(find.text('Track 2'));
      expect(selected?.queueIndex, 3);
    },
  );

  testWidgets('current queue index selects only its duplicate occurrence', (
    tester,
  ) async {
    final track = _track('same');
    final queue = PlaybackQueueDefinition(
      name: 'Queue',
      entries: [
        for (final id in ['first', 'second'])
          PlaybackQueueEntry(
            id: id,
            kind: PlaybackQueueEntryKind.track,
            title: 'same',
            tracks: [track],
          ),
      ],
    );
    SessionTrackSelection? selected;
    await _pumpSheet(
      tester,
      queue.expandedTracks,
      queue: queue,
      currentQueueIndex: 1,
      onSelected: (value) => selected = value,
    );
    final taps = find.byType(InkWell);
    expect(tester.widget<InkWell>(taps.first).onTap, isNotNull);
    expect(tester.widget<InkWell>(taps.last).onTap, isNull);
    await tester.tap(find.text('same').first);
    expect(selected?.queueIndex, 0);
  });

  testWidgets('remote queue selection survives a refreshed stream URL', (
    tester,
  ) async {
    final track = MusicTrack(
      path: 'https://new.example/track.mp3',
      displayName: 'Remote',
      groupKey: 'asmr-1',
      groupTitle: 'Remote Work',
      groupSubtitle: '',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: {'id': 1, 'trackRelativePath': '01.mp3'},
    );
    final queue = PlaybackQueueDefinition(
      name: 'Queue',
      entries: [
        PlaybackQueueEntry(
          id: 'remote',
          kind: PlaybackQueueEntryKind.track,
          title: 'Remote',
          tracks: [track],
        ),
      ],
    );
    await _pumpSheet(
      tester,
      [track],
      queue: queue,
      currentPath: 'https://old.example/track.mp3',
    );
    expect(find.text('Remote'), findsOneWidget);
    final selected = find.ancestor(
      of: find.text('Remote'),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(selected).onTap, isNull);
  });

  testWidgets('wide directory tree retains folder expansion after scrolling', (
    tester,
  ) async {
    final tracks = [for (var i = 0; i < 1000; i++) _track('Disc $i/Track $i')];
    await _pumpSheet(tester, tracks);
    expect(find.text('Track 0'), findsOneWidget);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    await _jumpToEnd(tester, position);
    expect(find.text('Disc 999'), findsOneWidget);
    await tester.tap(find.text('Disc 999'));
    await tester.pumpAndSettle();
    await _jumpToEnd(tester, position);
    expect(find.text('Track 999'), findsOneWidget);
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Track 0'), findsOneWidget);
    await _jumpToEnd(tester, position);
    expect(find.text('Track 999'), findsOneWidget);
  });
}
