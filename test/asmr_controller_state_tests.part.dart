part of 'asmr_one_settings_test.dart';

void registerAsmrControllerStateTests({
  required Future<void> Function([Map<String, Object> values]) resetPrefs,
  required AsmrPreferencesStore Function() preferencesStore,
}) {
  late AsmrPreferencesStore preferences;
  setUp(() => preferences = preferencesStore());

  test(
    'ASMR visible categories default to requested five categories',
    () async {
      await resetPrefs();

      expect(
        await preferences.loadVisibleCategories(),
        kDefaultVisibleAsmrCategories,
      );
    },
  );

  test('ASMR visible categories are sanitized and capped at five', () async {
    await resetPrefs();
    await preferences.saveVisibleCategories(const <AsmrCategoryType>[
      AsmrCategoryType.sales,
      AsmrCategoryType.rating,
      AsmrCategoryType.release,
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
      AsmrCategoryType.collected,
    ]);

    if (Platform.isWindows) {
      expect(await preferences.loadVisibleCategories(), <AsmrCategoryType>[
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
        AsmrCategoryType.favorites,
        AsmrCategoryType.history,
        AsmrCategoryType.collected,
      ]);
    } else {
      expect(await preferences.loadVisibleCategories(), <AsmrCategoryType>[
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
        AsmrCategoryType.favorites,
        AsmrCategoryType.history,
      ]);
    }
  });

  test(
    'ASMR content language defaults from app language and persists',
    () async {
      await resetPrefs();

      expect(
        await preferences.loadContentLanguage(AsmrContentLanguage.en),
        AsmrContentLanguage.en,
      );

      await preferences.saveContentLanguage(AsmrContentLanguage.ja);

      expect(
        await preferences.loadContentLanguage(AsmrContentLanguage.en),
        AsmrContentLanguage.ja,
      );
    },
  );

  test('ASMR work parser uses selected locale for localizable tag names', () {
    final work = AsmrWork.fromJson(const <String, dynamic>{
      'id': 1,
      'title': 'Original',
      'tags': <Map<String, Object>>[
        <String, Object>{
          'name': '默认',
          'i18n': <String, Object>{
            'en-us': <String, Object>{'name': 'English tag'},
            'ja-jp': <String, Object>{'name': '日本語タグ'},
          },
        },
      ],
    }, language: AsmrContentLanguage.en);

    expect(work.tags, <String>['English tag']);
  });

  test('ASMR single-track playback keeps the complete work tree', () async {
    await resetPrefs();
    final first = _trackFile('first.mp3', 'root/part-a/first.mp3');
    final target = _trackFile('target.mp3', 'root/part-b/target.mp3');
    final last = _trackFile('last.mp3', 'root/part-c/last.mp3');
    final api = _FakeAsmrApiService(
      trackTree: <AsmrTrackFile>[
        _trackFolder(
          'root',
          'root',
          children: <AsmrTrackFile>[
            _trackFolder(
              'part-a',
              'root/part-a',
              children: <AsmrTrackFile>[first],
            ),
            _trackFolder(
              'part-b',
              'root/part-b',
              children: <AsmrTrackFile>[target],
            ),
            _trackFolder(
              'part-c',
              'root/part-c',
              children: <AsmrTrackFile>[last],
            ),
          ],
        ),
      ],
    );
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
    );

    final tracks = await controller.loadPlayableTracksStartingAt(
      _work(id: 1, title: 'Work'),
      target,
    );

    expect(tracks, hasLength(3));
    expect(tracks.map((track) => track.displayName), <String>[
      'target',
      'last',
      'first',
    ]);
    expect(
      tracks.map((track) => track.remoteMetadata?['trackRelativePath']),
      <String>[
        'root/part-b/target.mp3',
        'root/part-c/last.mp3',
        'root/part-a/first.mp3',
      ],
    );
  });

  test(
    'ASMR playback prefers signed API media endpoints over raw URLs',
    () async {
      await resetPrefs();
      const rawUrl =
          'https://raw.kiko-play-niptan.one/media/stream/work/track.mp3';
      const node = AsmrTrackFile(
        hash: '1/2',
        title: 'track.mp3',
        type: 'audio',
        streamUrl: rawUrl,
        downloadUrl: null,
        lowQualityUrl: null,
        duration: Duration(minutes: 1),
        size: 1024,
        children: <AsmrTrackFile>[],
        workId: 1,
        workTitle: 'Work',
        sourceId: 'RJ000001',
        relativePath: 'track.mp3',
      );
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(trackTree: const <AsmrTrackFile>[node]),
      );

      final tracks = await controller.loadPlayableTracks(
        _work(id: 1, title: 'Work'),
      );

      expect(
        tracks.single.path,
        'https://api.asmr-300.com/api/media/stream/1/2',
      );
      expect(tracks.single.remoteMetadata?['playbackUrls'], contains(rawUrl));
    },
  );

  test('ASMR detail cache keeps the most recently used 128 works', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
    );
    final works = <AsmrWork>[
      for (var id = 1; id <= 129; id++) _work(id: id, title: 'Work $id'),
    ];

    for (final work in works.take(128)) {
      await controller.loadWorkDetail(work);
    }
    await controller.loadWorkDetail(works.first);
    await controller.loadWorkDetail(works.last);
    await controller.loadWorkDetail(works.first);
    await controller.loadWorkDetail(works[1]);

    expect(api.detailFetchWorkIds.where((id) => id == 1), hasLength(1));
    expect(api.detailFetchWorkIds.where((id) => id == 2), hasLength(2));
  });

  test('ASMR track cache keeps the most recently used 32 works', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(
      trackTree: <AsmrTrackFile>[_trackFile('track.mp3', 'track.mp3')],
    );
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
    );
    final works = <AsmrWork>[
      for (var id = 1; id <= 33; id++) _work(id: id, title: 'Work $id'),
    ];

    for (final work in works.take(32)) {
      await controller.ensureTrackTree(work);
    }
    await controller.ensureTrackTree(works.first);
    await controller.ensureTrackTree(works.last);
    await controller.ensureTrackTree(works.first);
    await controller.ensureTrackTree(works[1]);

    expect(api.trackFetchWorkIds.where((id) => id == 1), hasLength(1));
    expect(api.trackFetchWorkIds.where((id) => id == 2), hasLength(2));
  });

  test('ASMR track tree view state caches visible browsable nodes', () async {
    await resetPrefs();
    final work = _work(id: 51, title: 'Tree Work');
    final api = _FakeAsmrApiService(
      trackTree: <AsmrTrackFile>[
        _trackFolder(
          'Disc',
          'Disc',
          children: <AsmrTrackFile>[_trackFile('Track.mp3', 'Disc/Track.mp3')],
        ),
        _trackFile('notes.txt', 'notes.txt', type: 'text'),
      ],
    );
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.ensureTrackTree(work);

    final first = controller.trackTreeViewState(work.id);
    final second = controller.trackTreeViewState(work.id);

    expect(first, second);
    expect(identical(first.visibleTree, second.visibleTree), isTrue);
    expect(first.visibleTree?.map((node) => node.title), <String>['Disc']);
  });

  test('detail and track tree requests are single flight', () async {
    await resetPrefs();
    final detailStarted = Completer<void>();
    final detailRelease = Completer<void>();
    final trackStarted = Completer<void>();
    final trackRelease = Completer<void>();
    final api = _FakeAsmrApiService(
      beforeFetchWorkDetail: (_, _) async {
        if (!detailStarted.isCompleted) detailStarted.complete();
        await detailRelease.future;
      },
      beforeFetchTrackTree: (_) async {
        if (!trackStarted.isCompleted) trackStarted.complete();
        await trackRelease.future;
      },
    );
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    final work = _work(id: 404, title: 'Single flight');

    final details = <Future<AsmrWorkDetail>>[
      controller.loadWorkDetail(work),
      controller.loadWorkDetail(work),
    ];
    await detailStarted.future;
    expect(api.detailFetchWorkIds, <int>[404]);
    detailRelease.complete();
    await Future.wait(details);

    final trees = <Future<List<AsmrTrackFile>>>[
      controller.ensureTrackTree(work),
      controller.ensureTrackTree(work),
    ];
    await trackStarted.future;
    expect(api.trackFetchWorkIds, <int>[404]);
    trackRelease.complete();
    await Future.wait(trees);
  });

  test('language changes discard an in-flight detail result', () async {
    await resetPrefs();
    final started = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    final api = _FakeAsmrApiService(
      beforeFetchWorkDetail: (_, _) async {
        calls++;
        if (calls == 1) {
          started.complete();
          await release.future;
        }
      },
    );
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    final future = controller.loadWorkDetail(_work(id: 405, title: 'Language'));
    await started.future;
    await controller.setContentLanguage(AsmrContentLanguage.ja);
    release.complete();

    final detail = await future;
    expect(detail.work.title, startsWith('ja:'));
    expect(api.detailFetchWorkIds, <int>[405, 405]);
  });
}
