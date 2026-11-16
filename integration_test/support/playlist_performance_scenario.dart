part of '../ui_performance_test.dart';

const _playlistScaleSessionId = 'profile_playlist_session_0';
const _playlistScaleEntryPrefix = 'profile_playlist_entry_';
const _playlistSessionOverride = int.fromEnvironment('PERF_PLAYLIST_SESSIONS');
const _playlistTrackOverride = int.fromEnvironment(
  'PERF_PLAYLIST_QUEUE_TRACKS',
);

Future<void> _measureLargePlaylists(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  expect(Platform.isWindows || Platform.isAndroid, isTrue);
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final directory = await Directory.systemTemp.createTemp(
    'doujin_playlist_profile_',
  );
  final separator = Platform.pathSeparator;
  final path = '${directory.path}${separator}playlist.sqlite';
  final seedDatabase = await openDatabase(path);
  await AppDatabase.createSchemaForTest(seedDatabase);
  final seed = TestPersistenceRepository(
    database: AppDatabase.test(seedDatabase),
  );
  const measureQueue = _scenario == 'playlist-queue';
  const sessionCount = measureQueue
      ? 1
      : (_playlistSessionOverride > 0 ? _playlistSessionOverride : 500);
  const queueSize = measureQueue
      ? (_playlistTrackOverride > 0 ? _playlistTrackOverride : 10000)
      : 0;
  final tracks = <MusicTrack>[];
  for (var i = 0; i < 4; i++) {
    final file = File('${directory.path}${separator}Profile audio $i.wav');
    await _writeSilentWave(file, seconds: 120);
    tracks.add(
      MusicTrack(
        path: file.path,
        displayName: 'Profile track $i',
        groupKey: directory.path,
        groupTitle: 'Local playlist profile',
        groupSubtitle: '',
        isSingle: true,
        duration: const Duration(minutes: 2),
      ),
    );
  }
  await seed.upsertTracks(tracks);
  for (var i = 0; i < sessionCount; i++) {
    await seed.upsertSession(
      PersistedPlaybackSession(
        id: 'profile_playlist_session_$i',
        trackPath: tracks[i % tracks.length].path,
        loopModeIndex:
            (measureQueue
                    ? SessionLoopMode.crossSequential
                    : SessionLoopMode.single)
                .index,
        volume: 0.5,
        positionMs: 0,
        durationMs: tracks.first.duration.inMilliseconds,
        customQueueTracks: null,
        playbackQueue: measureQueue
            ? PlaybackQueueDefinition(
                name: 'Profile playlist',
                entries: [
                  for (var index = 0; index < queueSize; index++)
                    PlaybackQueueEntry(
                      id: '$_playlistScaleEntryPrefix$index',
                      kind: PlaybackQueueEntryKind.track,
                      title: 'Profile entry $index',
                      tracks: [tracks[index % tracks.length]],
                    ),
                ],
              )
            : null,
        channelSwapEnabled: false,
        sortOrder: i,
      ),
      includeQueue: measureQueue,
    );
  }
  await seedDatabase.close();
  final database = await openDatabase(path);
  final appDatabase = AppDatabase.test(database);
  AppDatabase.setInstanceForTest(appDatabase);
  final fixture = AppRuntimeWidgetTestFixture(
    providedPlaybackPersistenceRepository: SqlitePlaybackRepository(
      database: appDatabase,
    ),
    providedPersistenceRepository: TestPersistenceRepository(
      database: appDatabase,
    ),
    persistenceEnabled: true,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    if (measureQueue && fixture.playback.hasSession(_playlistScaleSessionId)) {
      await fixture.playback.clearAllSessions();
    }
    await fixture.runtimeGraph.runtime.dispose();
    fixture.dispose();
    AppDatabase.setInstanceForTest(null);
    await database.close();
    await directory.delete(recursive: true);
    UiInteractionNavigatorObserver.instance.resetForTest();
  });
  await fixture.settings.setStartupPage(StartupPage.playlist);

  final samples = <Map<String, Object>>[];
  final report = <String, Object>{
    'scenario': _scenario,
    'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
    'platform': Platform.operatingSystem,
    'framePolicy': binding.framePolicy.name,
    'displayRefreshRateHz': _refreshRate,
    'frameBudgetUs': _frameBudget.inMicroseconds,
    'sessionCount': sessionCount,
    'queueTrackCount': queueSize,
    'startupScope':
        'Isolated file SQLite through the production runtime and playlist page',
    'memoryScope': 'Process RSS sampled every frame during each stage',
    'writeCountScope': 'SQLite total_changes() delta including non-queue rows',
    'samples': samples,
    'measurementStatus': 'incomplete',
  };
  binding.reportData = {'uiPerformance': report};

  Future<void> measure(String phase, Future<void> Function() action) async {
    Future<int> changes() async =>
        (await database.rawQuery('SELECT total_changes() AS n')).single['n']
            as int;
    final initialWrites = await changes();
    final initialRss = ProcessInfo.currentRss;
    var maxRss = initialRss;
    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> frames) => timings.addAll(frames);
    var sampling = true;
    void sampleRss(Duration _) {
      if (!sampling) return;
      final rss = ProcessInfo.currentRss;
      if (rss > maxRss) maxRss = rss;
      WidgetsBinding.instance.addPostFrameCallback(sampleRss);
    }

    WidgetsBinding.instance.addTimingsCallback(collect);
    WidgetsBinding.instance.addPostFrameCallback(sampleRss);
    final started = DateTime.now().microsecondsSinceEpoch;
    late int ready;
    late int ended;
    try {
      debugPrint('PLAYLIST_PROFILE_STAGE $phase');
      await action().timeout(const Duration(seconds: 60));
      ready = DateTime.now().microsecondsSinceEpoch;
      // Capture the first frame after a write and any resulting UI update.
      await tester.pump();
      ended = DateTime.now().microsecondsSinceEpoch;
      sampling = false;
      await Future<void>.delayed(const Duration(seconds: 2));
    } finally {
      sampling = false;
      WidgetsBinding.instance.removeTimingsCallback(collect);
    }
    timings.retainWhere((frame) => _frameStartedWithin(frame, started, ended));
    final frameSummary = _summarizeRound(samples.length + 1, timings);
    final sample = <String, Object>{
      ...frameSummary,
      'phase': phase,
      'readyUs': ready - started,
      'rssBeforeBytes': initialRss,
      'rssPeakBytes': maxRss,
      'sqliteRowsWritten': await changes() - initialWrites,
      'p95WithinFrameBudget':
          timings.isNotEmpty &&
          (frameSummary['uiP95Us'] as int) <= _frameBudget.inMicroseconds &&
          (frameSummary['rasterP95Us'] as int) <= _frameBudget.inMicroseconds,
    };
    samples.add(sample);
    debugPrint('PLAYLIST_PERFORMANCE ${jsonEncode(sample)}');
  }

  final firstCard = measureQueue
      ? find.byKey(
          const ValueKey('playback_queue_row_surface_$_playlistScaleSessionId'),
        )
      : find.byType(SessionListCard);
  await measure('cold-restore-to-first-visible-card', () async {
    await tester.pumpWidget(
      fixture.build(
        const ExcludeSemantics(
          excluding: !_semanticsEnabled,
          child: MainScreen(),
        ),
        navigatorObservers: [UiInteractionNavigatorObserver.instance],
      ),
    );
    await _pumpUntilComplete(tester, fixture.runtimeGraph.runtime.start());
    await _waitForPlaylistProfileFinder(tester, firstCard);
    expect(fixture.playback.sessions.length, sessionCount);
  });
  for (var round = 0; round < 3; round++) {
    await measure('switch-out-of-playlist', () async {
      await _switchMainPage(
        tester,
        MainDestinationType.library,
        duringTransition: () {},
      );
    });
    await measure('switch-back-to-playlist', () async {
      await _switchMainPage(
        tester,
        MainDestinationType.playlist,
        duringTransition: () {},
      );
      await _waitForPlaylistProfileFinder(tester, firstCard);
    });
  }
  if (!measureQueue) {
    await measure(
      'scroll-session-catalog',
      () => _flingPageList<PlaylistTab>(tester),
    );
    await measure('reorder-session-catalog', () async {
      fixture.playback.reorderSessions(0, 3);
      await _pumpUntilComplete(tester, fixture.playback.saveSessionOrder());
    });
  } else {
    const editor = PlaybackQueueAudioEditPage(
      sessionId: _playlistScaleSessionId,
    );
    final firstRow = find.byKey(
      const ValueKey('${_playlistScaleEntryPrefix}0'),
    );
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    await measure('first-queue-editor-open', () async {
      unawaited(
        navigator.push(MaterialPageRoute<void>(builder: (_) => editor)),
      );
      await _waitForPlaylistProfileFinder(tester, firstRow);
    });
    final playback = fixture.playback;
    const id = _playlistScaleSessionId;
    Future<List<String>> entryOrder({int limit = 8}) async => [
      for (final row in await database.query(
        'playback_queue_entries',
        columns: ['entry_id'],
        where: 'session_id = ?',
        whereArgs: [id],
        orderBy: 'sort_order',
        limit: limit,
      ))
        row['entry_id'] as String,
    ];
    Future<void> flush() => _pumpUntilComplete(
      tester,
      playback.flushSessionStatePersistence(sessionId: id),
    );
    Future<void> append() async {
      await _pumpUntilComplete(
        tester,
        playback.addTrackToPlaybackQueue(id, tracks.last),
      );
      await flush();
    }

    await tester.pump(const Duration(milliseconds: 350));
    final beforeDrag = await entryOrder();
    await measure('drag-queue-entry', () async {
      final handles = find.byType(ReorderableDragStartListener).hitTestable();
      expect(handles.evaluate().length, greaterThanOrEqualTo(2));
      final from = tester.getCenter(handles.at(0));
      final to = tester.getCenter(handles.at(1)) + const Offset(0, 10);
      final gesture = await tester.startGesture(
        from,
        kind: Platform.isWindows
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      try {
        for (var step = 1; step <= 8; step++) {
          await gesture.moveTo(Offset.lerp(from, to, step / 8)!);
          await tester.pump(const Duration(milliseconds: 16));
        }
      } finally {
        await gesture.up();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await flush();
    });
    expect(await entryOrder(), isNot(orderedEquals(beforeDrag)));
    await measure(
      'scroll-queue-entries',
      () => _flingPageList<PlaybackQueueAudioEditPage>(tester),
    );
    await measure('rename-queue', () async {
      expect(
        playback.renamePlaybackQueue(id, 'Renamed profile playlist'),
        true,
      );
      await flush();
    });
    await measure('append-track', append);
    await measure('remove-track', () async {
      await _pumpUntilComplete(
        tester,
        playback.removePlaybackQueueEntry(id, '${_playlistScaleEntryPrefix}1'),
      );
      await flush();
    });
    final beforeReorder = await entryOrder(limit: 3);
    await measure('reorder-track', () async {
      await _pumpUntilComplete(
        tester,
        playback.reorderPlaybackQueueEntry(id, 0, 3),
      );
      await flush();
    });
    expect((await entryOrder(limit: 1)).single, beforeReorder[1]);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await measure(
      'start-large-queue-playback',
      () => _toggleRuntimeSession(tester, fixture, id, playing: true),
    );
    await measure('append-track-while-playing', () async {
      await append();
      expect(playback.sessionById(id)!.state.playing, true);
    });
  }
  report['measurementStatus'] = 'complete';
  debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
  if (kProfileMode) {
    expect(
      samples.every((sample) => (sample['frameCount'] as int) > 0),
      isTrue,
      reason: 'Every sampled action must contain real engine frames.',
    );
  }
}

Future<void> _waitForPlaylistProfileFinder(
  WidgetTester tester,
  Finder finder,
) async {
  final visible = finder.hitTestable();
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (visible.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(visible, findsWidgets);
}
