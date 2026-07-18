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
    'ASMR content language follows page language unless explicitly set',
    () async {
      await resetPrefs();

      expect(
        await preferences.loadContentLanguagePreference(),
        ContentLanguagePreference.followPage,
      );

      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      expect(
        controller.contentLanguagePreference,
        ContentLanguagePreference.followPage,
      );
      expect(controller.contentLanguage, AsmrContentLanguage.en);
      expect(controller.setPageLanguage(AppLanguage.ja), isTrue);
      expect(controller.contentLanguage, AsmrContentLanguage.ja);

      await controller.setContentLanguage(AsmrContentLanguage.en);
      expect(
        controller.contentLanguagePreference,
        ContentLanguagePreference.en,
      );
      expect(controller.setPageLanguage(AppLanguage.zh), isFalse);
      expect(controller.contentLanguage, AsmrContentLanguage.en);

      expect(
        await preferences.loadContentLanguagePreference(),
        ContentLanguagePreference.en,
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
    final first = _trackFile(
      'first.mp3',
      'root/part-a/first.mp3',
      officialMedia: true,
    );
    final target = _trackFile(
      'target.mp3',
      'root/part-b/target.mp3',
      officialMedia: true,
    );
    final last = _trackFile(
      'last.mp3',
      'root/part-c/last.mp3',
      officialMedia: true,
    );
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
    'ASMR track tree and playable tracks use recursive natural order',
    () async {
      await resetPrefs();
      const sortedTrackTitles = <String>[
        'トラック１',
        'トラック２',
        'トラック３',
        'トラック４',
        'トラック５',
        'トラック６',
        'トラック７',
        'トラック８',
        'トラック９',
        'トラック１０',
        'トラック１１',
      ];
      final sourceTrackTitles = <String>[
        sortedTrackTitles[0],
        sortedTrackTitles[9],
        sortedTrackTitles[10],
        ...sortedTrackTitles.skip(1).take(8),
      ];
      final api = _FakeAsmrApiService(
        trackTree: <AsmrTrackFile>[
          _trackFolder(
            '04',
            '04',
            children: <AsmrTrackFile>[_trackFile('audio.mp3', '04/audio.mp3')],
          ),
          _trackFolder(
            '01',
            '01',
            children: sourceTrackTitles
                .map((title) => _trackFile('$title.mp3', '01/$title.mp3'))
                .toList(growable: false),
          ),
          _trackFolder(
            '03',
            '03',
            children: <AsmrTrackFile>[_trackFile('audio.mp3', '03/audio.mp3')],
          ),
          _trackFolder(
            '02',
            '02',
            children: <AsmrTrackFile>[_trackFile('audio.mp3', '02/audio.mp3')],
          ),
        ],
      );
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
      );
      final work = _work(id: 1, title: 'Work');

      final tree = await controller.ensureTrackTree(work);
      final tracks = await controller.loadPlayableTracks(work);

      expect(tree.map((node) => node.title), <String>['01', '02', '03', '04']);
      expect(
        tree.first.children.map((node) => node.displayTitle),
        sortedTrackTitles,
      );
      expect(
        tracks.take(11).map((track) => track.displayName),
        sortedTrackTitles,
      );
    },
  );

  test('ASMR track tree groups folders before naturally sorted files', () {
    final sorted = sortAsmrTrackTreeNaturally(<AsmrTrackFile>[
      _trackFile('10. track.mp3', '10. track.mp3'),
      _trackFolder('10_folder', '10_folder'),
      _trackFile('2. track.mp3', '2. track.mp3'),
      _trackFolder('2_folder', '2_folder'),
      _trackFile('01. track.mp3', '01. track.mp3'),
      _trackFolder(
        '01_folder',
        '01_folder',
        children: <AsmrTrackFile>[
          _trackFile('11. nested.mp3', '01_folder/11. nested.mp3'),
          _trackFolder('11_nested', '01_folder/11_nested'),
          _trackFile('3. nested.mp3', '01_folder/3. nested.mp3'),
          _trackFolder('3_nested', '01_folder/3_nested'),
          _trackFile('02. nested.mp3', '01_folder/02. nested.mp3'),
          _trackFolder('02_nested', '01_folder/02_nested'),
        ],
      ),
    ]);

    expect(sorted.map((node) => node.title), <String>[
      '01_folder',
      '2_folder',
      '10_folder',
      '01. track.mp3',
      '2. track.mp3',
      '10. track.mp3',
    ]);
    expect(sorted.first.children.map((node) => node.title), <String>[
      '02_nested',
      '3_nested',
      '11_nested',
      '02. nested.mp3',
      '3. nested.mp3',
      '11. nested.mp3',
    ]);
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

  test(
    'ASMR track tree view state exposes loading until request completes',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      final work = _work(id: 52, title: 'Loading Tree Work');
      final api = _FakeAsmrApiService(
        beforeFetchTrackTree: (_) async {
          started.complete();
          await release.future;
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

      final request = controller.ensureTrackTree(work);
      await started.future;

      final loading = controller.trackTreeViewState(work.id);
      expect(loading.isLoading, isTrue);
      expect(loading.tree, isNull);
      expect(loading.operationError, isNull);

      release.complete();
      await request;

      final loaded = controller.trackTreeViewState(work.id);
      expect(loaded.isLoading, isFalse);
      expect(loaded.tree, isEmpty);
      expect(loaded.operationError, isNull);
    },
  );

  test(
    'ASMR track tree failure remains distinct from confirmed empty tree',
    () async {
      await resetPrefs();
      var attempts = 0;
      final work = _work(id: 53, title: 'Retry Tree Work');
      final api = _FakeAsmrApiService(
        beforeFetchTrackTree: (_) async {
          attempts++;
          if (attempts == 1) {
            throw const SocketException('offline');
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

      await expectLater(
        controller.ensureTrackTree(work),
        throwsA(isA<SocketException>()),
      );

      final failed = controller.trackTreeViewState(work.id);
      expect(failed.isLoading, isFalse);
      expect(failed.tree, isNull);
      expect(failed.operationError, isA<SocketException>());

      await controller.ensureTrackTree(work);

      final empty = controller.trackTreeViewState(work.id);
      expect(empty.isLoading, isFalse);
      expect(empty.tree, isEmpty);
      expect(empty.visibleTree, isEmpty);
      expect(empty.operationError, isNull);
    },
  );

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

  test(
    'account changes discard old category responses and refresh with the new token',
    () async {
      await resetPrefs();
      final oldRequestStarted = Completer<void>();
      final releaseOldRequest = Completer<void>();
      final aliceRequestStarted = Completer<void>();
      final releaseAliceRequest = Completer<void>();
      var releaseRequests = 0;
      final api = _FakeAsmrApiService(
        worksByToken: <String, List<AsmrWork>>{
          '': <AsmrWork>[_work(id: 901, title: 'Guest result')],
          'token-alice': <AsmrWork>[_work(id: 902, title: 'Alice result')],
        },
        beforeFetchWorkResponse: (request) async {
          if (request != 'release:desc:1') return;
          releaseRequests++;
          if (releaseRequests == 1) {
            oldRequestStarted.complete();
            await releaseOldRequest.future;
          } else if (releaseRequests == 3) {
            aliceRequestStarted.complete();
            await releaseAliceRequest.future;
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

      final oldRefresh = controller.refreshCategory(AsmrCategoryType.release);
      await oldRequestStarted.future;
      await controller.loginAsmrAccount('alice', 'password');
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (!api.fetchWorkTokens.contains('token-alice') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(api.fetchWorkTokens, contains('token-alice'));
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[902],
      );

      releaseOldRequest.complete();
      await oldRefresh;

      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[902],
      );
      expect(controller.isLoadingCategory(AsmrCategoryType.release), isFalse);

      await Future<void>.delayed(Duration.zero);
      final aliceRefresh = controller.refreshCategory(AsmrCategoryType.release);
      await aliceRequestStarted.future;
      await controller.logoutAsmrAccount();
      final logoutDeadline = DateTime.now().add(const Duration(seconds: 1));
      while (api.fetchWorkTokens.isNotEmpty &&
          api.fetchWorkTokens.last != null &&
          DateTime.now().isBefore(logoutDeadline)) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(api.fetchWorkTokens.last, isNull);
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[901],
      );

      releaseAliceRequest.complete();
      await aliceRefresh;
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[901],
      );
    },
  );

  test(
    'pagination commit is dropped after UI generation changes without leaving loading stuck',
    () async {
      await resetPrefs();
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      addTearDown(coordinator.resetForTest);
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(largeRecommendationPool: true),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await controller.refreshCategory(AsmrCategoryType.release);
      expect(controller.worksFor(AsmrCategoryType.release), hasLength(40));

      final interactionSource = Object();
      coordinator.beginInteraction(interactionSource);
      await controller.loadMoreCategory(AsmrCategoryType.release);
      expect(
        controller.isLoadingMoreCategory(AsmrCategoryType.release),
        isTrue,
      );

      coordinator.beginGeneration();
      coordinator.finishInteractionsForTest();

      expect(controller.worksFor(AsmrCategoryType.release), hasLength(40));
      expect(
        controller.isLoadingMoreCategory(AsmrCategoryType.release),
        isFalse,
      );
    },
  );

  test(
    'restoring a different token invalidates and refreshes a loaded category',
    () async {
      await resetPrefs();
      final oldRequestStarted = Completer<void>();
      final releaseOldRequest = Completer<void>();
      var releaseRequests = 0;
      final tokenStore = _MemoryAsmrTokenStore()..token = 'token-old';
      final api = _FakeAsmrApiService(
        worksByToken: <String, List<AsmrWork>>{
          'token-old': <AsmrWork>[_work(id: 911, title: 'Old account')],
          'token-new': <AsmrWork>[_work(id: 912, title: 'New account')],
        },
        beforeFetchWorkResponse: (request) async {
          if (request != 'release:desc:1') return;
          releaseRequests++;
          if (releaseRequests == 1) {
            oldRequestStarted.complete();
            await releaseOldRequest.future;
          }
        },
      );
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await controller.restoreAsmrAccountSession();

      final oldRefresh = controller.refreshCategory(AsmrCategoryType.release);
      await oldRequestStarted.future;
      tokenStore.token = 'token-new';
      await controller.restoreAsmrAccountSession(force: true);
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (!api.fetchWorkTokens.contains('token-new') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(api.fetchWorkTokens, contains('token-new'));
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[912],
      );

      releaseOldRequest.complete();
      await oldRefresh;
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[912],
      );
    },
  );
}
