part of 'asmr_one_settings_test.dart';

void registerAsmrControllerStateTests({
  required Future<void> Function([Map<String, Object> values]) resetPrefs,
  required AsmrPreferencesStore Function() preferencesStore,
  required TestPersistenceRepository Function() persistenceRepository,
}) {
  late AsmrPreferencesStore preferences;
  setUp(() => preferences = preferencesStore());

  for (final clearQuery in [true, false]) {
    test(
      '${clearQuery ? 'clearing' : 'closing'} search cancels requests and retains root pages',
      () async {
        await resetPrefs();
        final started = Completer<void>();
        final release = Completer<void>();
        final api = _FakeAsmrApiService(
          beforeFetchSearchResponse: (_) async {
            started.complete();
            await release.future;
          },
        );
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          apiService: api,
          persistenceRepository: persistenceRepository(),
        );
        addTearDown(controller.dispose);
        await controller.ensureCategoryLoaded(AsmrCategoryType.release);
        final root = controller.worksFor(AsmrCategoryType.release);
        controller.beginSearchSession();
        final pending = controller.ensureCategoryLoaded(
          AsmrCategoryType.release,
          searchQuery: 'old',
          searchSession: true,
        );
        await started.future;
        if (clearQuery) {
          controller.setSearchQuery('', AsmrCategoryType.release);
        } else {
          controller.endSearchSession();
        }
        await pending.timeout(const Duration(seconds: 1));
        expect(release.isCompleted, isFalse);
        expect(controller.worksFor(AsmrCategoryType.release), same(root));
        expect(
          controller
              .categoryViewState(AsmrCategoryType.release, searchSession: true)
              .works,
          same(root),
        );
        expect(
          controller
              .categoryViewState(
                AsmrCategoryType.release,
                searchQuery: 'old',
                searchSession: true,
              )
              .hasAttemptedLoad,
          isFalse,
        );
        release.complete();
      },
    );
  }

  test(
    'changing search keywords cancels pending work and discards old results',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      final api = _FakeAsmrApiService(
        beforeFetchSearchResponse: (_) async {
          if (++calls == 1) {
            started.complete();
            await release.future;
          }
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      addTearDown(controller.dispose);
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      final root = controller.worksFor(AsmrCategoryType.release);
      controller.beginSearchSession();
      final pending = controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'old',
        searchSession: true,
      );
      await started.future;
      controller.setSearchQuery('new', AsmrCategoryType.release);
      await pending.timeout(const Duration(seconds: 1));
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        controller
            .categoryViewState(
              AsmrCategoryType.release,
              searchQuery: 'old',
              searchSession: true,
            )
            .hasAttemptedLoad,
        isFalse,
      );
      expect(controller.worksFor(AsmrCategoryType.release), same(root));
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'new',
        searchSession: true,
      );
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'old',
        searchSession: true,
      );
      expect(api.searchKeywords, ['old', 'new', 'old']);
    },
  );

  test(
    'switching search categories cancels pagination and preserves completed pages',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      var pageTwoCalls = 0;
      final api = _FakeAsmrApiService(
        largeRecommendationPool: true,
        pagedSearchWorks: true,
        beforeFetchSearchResponse: (request) async {
          if (request == 'release:desc:2' && ++pageTwoCalls == 1) {
            started.complete();
            await release.future;
          }
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      addTearDown(controller.dispose);
      controller.beginSearchSession();
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      final before = controller
          .categoryViewState(
            AsmrCategoryType.release,
            searchQuery: 'sleep',
            searchSession: true,
          )
          .works;
      final pending = controller.loadMoreCategory(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      await started.future;
      controller.setSearchQuery('sleep', AsmrCategoryType.collected);
      await pending.timeout(const Duration(seconds: 1));
      final cancelled = controller.categoryViewState(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      expect(cancelled.works, same(before));
      expect(cancelled.isLoadingMore, isFalse);
      expect(cancelled.needsLoadMoreRetry, isFalse);
      expect(cancelled.lastError, isNull);
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      expect(api.searchWorkRequests, ['release:desc:1', 'release:desc:2']);
      await controller.loadMoreCategory(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        controller
            .categoryViewState(
              AsmrCategoryType.release,
              searchQuery: 'sleep',
              searchSession: true,
            )
            .works,
        hasLength(80),
      );
    },
  );

  test(
    'returning to a cancelled first search load starts a replacement request',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      final api = _FakeAsmrApiService(
        beforeFetchSearchResponse: (_) async {
          if (++calls == 1) {
            started.complete();
            await release.future;
          }
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      addTearDown(controller.dispose);
      controller.beginSearchSession();
      final pending = controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      await started.future;
      controller.setSearchQuery('sleep', AsmrCategoryType.collected);
      await pending.timeout(const Duration(seconds: 1));
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      release.complete();
      expect(api.searchKeywords, ['sleep', 'sleep']);
      final state = controller.categoryViewState(
        AsmrCategoryType.release,
        searchQuery: 'sleep',
        searchSession: true,
      );
      expect(state.works, hasLength(1));
      expect(state.isLoading, isFalse);
      expect(state.lastError, isNull);
    },
  );

  for (final count in [100, 1000, 5000]) {
    test(
      '$count category works preserve order and filtered cache identity',
      () async {
        await resetPrefs();
        final works = [
          for (var id = 1; id <= count; id++)
            _work(id: id, title: '${id.isEven ? 'Even' : 'Odd'} work $id'),
        ];
        await preferences.saveFavoriteWorks(works);
        final api = _FakeAsmrApiService(worksByToken: {'': works});
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          persistenceRepository: persistenceRepository(),
          apiService: api,
        );
        await controller.initializeForVisiblePage();
        await controller.refreshCategory(AsmrCategoryType.release);

        final remote = controller.worksFor(AsmrCategoryType.release);
        final favorites = controller.worksFor(AsmrCategoryType.favorites);
        final filtered = controller.filteredWorksFor(
          AsmrCategoryType.favorites,
          searchQuery: 'even',
        );
        expect(remote.map((work) => work.id), works.map((work) => work.id));
        expect(filtered.map((work) => work.id), [
          for (var id = 2; id <= count; id += 2) id,
        ]);
        expect(
          controller.filteredWorksFor(
            AsmrCategoryType.favorites,
            searchQuery: ' even ',
          ),
          same(filtered),
        );
        expect(
          controller.filteredWorksFor(
            AsmrCategoryType.favorites,
            searchQuery: 'EVEN',
          ),
          orderedEquals(filtered),
        );
        await controller.refreshCategory(AsmrCategoryType.history);
        expect(controller.worksFor(AsmrCategoryType.release), same(remote));
        expect(
          controller.worksFor(AsmrCategoryType.favorites),
          same(favorites),
        );
        expect(
          controller.filteredWorksFor(
            AsmrCategoryType.favorites,
            searchQuery: 'even',
          ),
          same(filtered),
        );
        expect(api.fetchWorkRequests, ['release:desc:1']);
      },
    );
  }

  test(
    'category state preserves untouched and empty-query load semantics',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      final api = _FakeAsmrApiService(
        beforeFetchWorkResponse: (_) async {
          if (!started.isCompleted) started.complete();
          await release.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.initialize();
      const category = AsmrCategoryType.release;
      final initial = controller.categoryViewState(category);
      expect(initial.hasAttemptedLoad, isFalse);
      expect(initial.totalCount, 0);
      expect(initial.hasMore, isFalse);
      final first = controller.refreshCategory(category);
      await started.future;
      final repeated = controller.refreshCategory(category);
      await Future<void>.delayed(Duration.zero);
      expect(api.fetchWorkRequests, hasLength(1));
      expect(controller.categoryViewState(category).isLoading, isTrue);
      expect(
        controller.categoryViewState(AsmrCategoryType.rating).hasAttemptedLoad,
        isFalse,
      );
      release.complete();
      await Future.wait([first, repeated]);
      final loaded = controller.categoryViewState(category);
      expect(loaded.hasAttemptedLoad, isTrue);
      expect(loaded.activeQuery, '');
      expect(loaded.isLoading, isFalse);
      expect(controller.categoryViewState(category).works, same(loaded.works));
    },
  );

  test(
    'failed first category load retries only on an explicit refresh',
    () async {
      await resetPrefs();
      var fail = true;
      final api = _FakeAsmrApiService(
        beforeFetchWorkResponse: (_) async {
          if (fail) throw const SocketException('offline');
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(
        controller.categoryViewState(AsmrCategoryType.release).operationError,
        isA<SocketException>(),
      );
      final firstAttempts = api.fetchWorkRequests.length;
      expect(firstAttempts, greaterThan(0));
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(api.fetchWorkRequests, hasLength(firstAttempts));
      fail = false;
      await controller.refreshCategory(AsmrCategoryType.release);
      expect(api.fetchWorkRequests, hasLength(firstAttempts + 1));
      expect(
        controller.categoryViewState(AsmrCategoryType.release).operationError,
        isNull,
      );
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        isNotEmpty,
      );
    },
  );

  test(
    'concurrent first category ensures await the shared in-flight request',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      final api = _FakeAsmrApiService(
        beforeFetchWorkResponse: (_) async {
          started.complete();
          await release.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.initializeForVisiblePage();
      final first = controller.ensureCategoryLoaded(AsmrCategoryType.release);
      await started.future;
      var repeatedCompleted = false;
      final repeated = controller
          .ensureCategoryLoaded(AsmrCategoryType.release)
          .then((_) {
            repeatedCompleted = true;
          });
      await Future<void>.delayed(Duration.zero);
      expect(repeatedCompleted, isFalse);
      expect(api.fetchWorkRequests, hasLength(1));
      release.complete();
      await Future.wait([first, repeated]);
      expect(repeatedCompleted, isTrue);
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        isNotEmpty,
      );
    },
  );

  test('disposed catalog does not dispatch refresh or pagination', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      persistenceRepository: persistenceRepository(),
      apiService: api,
    );
    await controller.initialize();
    controller.dispose();
    await controller.refreshCategory(AsmrCategoryType.release);
    await controller.loadMoreCategory(AsmrCategoryType.release);
    expect(api.fetchWorkRequests, isEmpty);
  });

  test(
    'disposing the controller prevents an in-flight category commit',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final api = _FakeAsmrApiService(
        beforeFetchWorkResponse: (_) async {
          if (++requests == 2) {
            started.complete();
            await release.future;
          }
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.initializeForVisiblePage();
      await controller.refreshCategory(AsmrCategoryType.release);
      final pending = controller.refreshCategory(AsmrCategoryType.release);
      await started.future;
      final previous = controller.categoryViewState(AsmrCategoryType.release);
      controller.dispose();
      release.complete();
      await pending;
      final current = controller.categoryViewState(AsmrCategoryType.release);
      expect(current.works, same(previous.works));
      expect(current.revision, previous.revision);
      expect(current.lastError, isNull);
    },
  );

  for (final failOldPage in [false, true]) {
    test(
      'language change ignores old pagination completion, failure=$failOldPage',
      () async {
        await resetPrefs();
        final started = Completer<void>();
        final release = Completer<void>();
        final api = _FakeAsmrApiService(
          largeRecommendationPool: true,
          beforeFetchWorkResponse: (request) async {
            if (request == 'release:desc:2') {
              started.complete();
              await release.future;
            }
          },
        );
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          persistenceRepository: persistenceRepository(),
          apiService: api,
        );
        await controller.initializeForVisiblePage(
          defaultLanguage: AsmrContentLanguage.en,
        );
        await controller.refreshCategory(AsmrCategoryType.release);
        final pending = controller.loadMoreCategory(AsmrCategoryType.release);
        await started.future;
        expect(controller.setPageLanguage(AppLanguage.ja), isTrue);
        await controller.refreshCategory(AsmrCategoryType.release);
        final previous = controller.categoryViewState(AsmrCategoryType.release);
        var notifications = 0;
        controller.addListener(() => notifications++);
        if (failOldPage) {
          release.completeError(StateError('Old page failed'));
        } else {
          release.complete();
        }
        await pending;
        final current = controller.categoryViewState(AsmrCategoryType.release);
        expect(current.works, same(previous.works));
        expect(current.works, hasLength(40));
        expect(current.revision, previous.revision);
        expect(current.lastError, isNull);
        expect(current.isLoadingMore, isFalse);
        expect(current.needsLoadMoreRetry, isFalse);
        expect(notifications, 0);
      },
    );
  }

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

    expect(await preferences.loadVisibleCategories(), <AsmrCategoryType>[
      AsmrCategoryType.sales,
      AsmrCategoryType.rating,
      AsmrCategoryType.release,
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]);
  });

  test(
    'ASMR content language follows page language unless explicitly set',
    () async {
      await resetPrefs();

      expect(
        await preferences.loadContentLanguagePreference(),
        ContentLanguagePreference.followPage,
      );

      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(),
        persistenceRepository: _FakeTestPersistenceRepository(
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

  test('content language changes refresh loaded remote categories', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.refreshCategory(AsmrCategoryType.release);
    expect(api.fetchWorkRequests, <String>['release:desc:1']);

    await controller.setContentLanguage(AsmrContentLanguage.ja);

    expect(api.fetchWorkRequests, <String>['release:desc:1', 'release:desc:1']);
  });

  test(
    'returning to a content language preserves its previously loaded pages',
    () async {
      await resetPrefs();
      final api = _BrowseChangingApi();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.initializeForVisiblePage();
      await controller.refreshCategory(AsmrCategoryType.release);
      await controller.loadMoreCategory(AsmrCategoryType.release);
      final original = controller
          .categoryViewState(AsmrCategoryType.release)
          .works;
      api.shift = 10;
      await controller.setContentLanguage(AsmrContentLanguage.en);
      expect(
        controller
            .categoryViewState(AsmrCategoryType.release)
            .works
            .map((work) => work.id),
        [11, 12],
      );
      api.shift = 0;
      await controller.setContentLanguage(AsmrContentLanguage.zh);
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        same(original),
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
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: persistenceRepository(),
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
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
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
      final node = AsmrTrackFile(
        hash: '1/2',
        title: 'track.mp3',
        type: 'audio',
        streamUrl: rawUrl,
        downloadUrl: null,
        lowQualityUrl: null,
        duration: const Duration(minutes: 1),
        size: 1024,
        children: const <AsmrTrackFile>[],
        workId: 1,
        workTitle: 'Work',
        sourceId: 'RJ000001',
        relativePath: 'track.mp3',
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(trackTree: <AsmrTrackFile>[node]),
        persistenceRepository: persistenceRepository(),
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

  test(
    'hidden ASMR tracks persist, isolate works and can be restored',
    () async {
      await resetPrefs();
      final node = _trackFile('track.mp3', 'Disc/track.mp3');
      final work = _work(id: 71, title: 'Hidden tracks');
      final tree = [
        _trackFolder('Disc', 'Disc', children: [node]),
      ];
      AsmrLibraryController createController() => createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(trackTree: tree),
      );
      final controller = createController();
      final before = await controller.loadPlayableTracks(work);
      expect(await controller.loadPlayableTracks(work), same(before));
      await controller.setTrackHidden(work.id, node, true);
      expect(controller.trackTreeViewState(work.id).visibleTree, isEmpty);
      expect(await controller.loadPlayableTracks(work), isEmpty);
      expect(
        await controller.loadPlayableTracksStartingAt(work, node),
        isEmpty,
      );
      expect(before, hasLength(1));
      expect(
        await controller.loadPlayableTracks(_work(id: 72, title: 'Other')),
        hasLength(1),
      );
      final restarted = createController();
      expect(await restarted.loadPlayableTracks(work), isEmpty);
      await restarted.setTrackHidden(work.id, node, false);
      expect(await restarted.loadPlayableTracks(work), hasLength(1));
      expect(
        restarted.trackTreeViewState(work.id).visibleTree!.single.children,
        hasLength(1),
      );
    },
  );

  test(
    'hashless hidden tracks retain identity across signed URL changes',
    () async {
      await resetPrefs();
      AsmrTrackFile node(String url) => AsmrTrackFile.fromJson({
        'title': 'clip.mp4',
        'type': 'video',
        'mediaStreamUrl': url,
      }, parentPath: 'Disc');
      final first = node('https://example.test/clip.mp4?token=first');
      final refreshed = node('https://example.test/clip.mp4?token=second');
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(trackTree: [refreshed]),
      );
      final work = _work(id: 73, title: 'Video');
      expect(
        (await controller.loadPlayableTracksStartingAt(
          work,
          refreshed,
        )).single.isVideo,
        isTrue,
      );
      await controller.setTrackHidden(work.id, first, true);
      expect(controller.isTrackHidden(work.id, refreshed), isTrue);
      expect(await controller.loadPlayableTracks(work), isEmpty);
      await controller.reloadPersistedState();
      expect(await controller.loadPlayableTracks(work), isEmpty);
    },
  );

  test(
    'failed hidden-track write preserves visible and playable state',
    () async {
      await resetPrefs();
      final node = _trackFile('track.mp3', 'track.mp3');
      final work = _work(id: 74, title: 'Write failure');
      final controller = createTestAsmrController(
        preferencesStore: _FailingHiddenTrackPreferences(
          repository: persistenceRepository(),
        ),
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(trackTree: [node]),
      );
      final tracks = await controller.loadPlayableTracks(work);
      await expectLater(
        controller.setTrackHidden(work.id, node, true),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.isTrackHidden(work.id, node), isFalse);
      expect(controller.trackTreeViewState(work.id).visibleTree, hasLength(1));
      expect(await controller.loadPlayableTracks(work), same(tracks));
    },
  );

  test(
    'hidden target does not fall through to another playable track',
    () async {
      await resetPrefs();
      final target = _trackFile('a.mp3', 'a.mp3');
      final other = _trackFile('b.mp3', 'b.mp3');
      final work = _work(id: 75, title: 'Removed target');
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(trackTree: [target, other]),
      );
      final initial = await controller.loadPlayableTracks(work);
      expect(initial.first.remoteMetadata?['trackStableKey'], target.stableKey);
      await controller.setTrackHidden(work.id, target, true);
      expect(await controller.loadPlayableTracks(work), hasLength(1));
      expect(
        await controller.loadPlayableTracksStartingAt(work, target),
        isEmpty,
      );
      expect(
        (await controller.loadPlayableTracksStartingAt(
          work,
          other,
        )).single.displayName,
        'b',
      );
    },
  );

  test('ASMR track memory eviction fetches discarded content again', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(
      trackTree: <AsmrTrackFile>[_trackFile('track.mp3', 'track.mp3')],
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: persistenceRepository(),
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
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: _FakeTestPersistenceRepository(
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
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: _FakeTestPersistenceRepository(
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
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: _FakeTestPersistenceRepository(
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

  test('track tree requests are single flight', () async {
    await resetPrefs();
    final trackStarted = Completer<void>();
    final trackRelease = Completer<void>();
    final api = _FakeAsmrApiService(
      beforeFetchTrackTree: (_) async {
        if (!trackStarted.isCompleted) trackStarted.complete();
        await trackRelease.future;
      },
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    final work = _work(id: 404, title: 'Single flight');

    final trees = <Future<List<AsmrTrackFile>>>[
      controller.ensureTrackTree(work),
      controller.ensureTrackTree(work),
    ];
    await trackStarted.future;
    expect(api.trackFetchWorkIds, <int>[404]);
    trackRelease.complete();
    await Future.wait(trees);
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
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: _FakeTestPersistenceRepository(
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
    'loaded root categories retain pagination without automatic requests',
    () async {
      await resetPrefs();
      final api = _BrowseChangingApi();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      await controller.loadMoreCategory(AsmrCategoryType.release);
      final before = controller
          .categoryViewState(AsmrCategoryType.release)
          .works;
      api.shift = 10;
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(api.pages, [1, 2]);
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        same(before),
      );
      final next = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await next.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(api.pages, [1, 2, 1]);
      expect(
        next
            .categoryViewState(AsmrCategoryType.release)
            .works
            .map((work) => work.id),
        [11, 12],
      );
    },
  );

  test(
    'empty search reuses root pagination across search sessions without requests',
    () async {
      await resetPrefs();
      final api = _BrowseChangingApi();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      await controller.loadMoreCategory(AsmrCategoryType.release);
      final root = controller.categoryViewState(AsmrCategoryType.release).works;
      controller.beginSearchSession();
      api.shift = 10;
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: '   ',
        searchSession: true,
      );
      expect(
        controller
            .categoryViewState(AsmrCategoryType.release, searchSession: true)
            .works,
        same(root),
      );
      expect(api.pages, [1, 2]);
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        same(root),
      );
      controller.endSearchSession();
      expect(
        controller
            .categoryViewState(AsmrCategoryType.release, searchSession: true)
            .works,
        same(root),
      );
      controller.beginSearchSession();
      api.shift = 20;
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchSession: true,
      );
      expect(
        controller
            .categoryViewState(AsmrCategoryType.release, searchSession: true)
            .works,
        same(root),
      );
      expect(api.pages, [1, 2]);
      await controller.loadMoreCategory(
        AsmrCategoryType.release,
        searchSession: true,
      );
      expect(api.pages, [1, 2, 3]);
      expect(controller.worksFor(AsmrCategoryType.release), hasLength(6));
      await controller.refreshCategory(
        AsmrCategoryType.release,
        searchSession: true,
      );
      expect(api.pages, [1, 2, 3, 1]);
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        [21, 22],
      );
    },
  );

  test(
    'empty search reuses a successful empty root list until cache clear',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(worksByToken: {'': const []});
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      controller.beginSearchSession();
      final state = controller.categoryViewState(
        AsmrCategoryType.release,
        searchSession: true,
      );
      expect(state.works, isEmpty);
      expect(state.hasAttemptedLoad, isTrue);
      expect(state.isLoading, isFalse);
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchSession: true,
      );
      expect(api.fetchWorkRequests, hasLength(1));
      controller.clearRuntimeCaches();
      await controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchSession: true,
      );
      expect(api.fetchWorkRequests, hasLength(2));
    },
  );

  test(
    'closed search ignores pending requests even after a new session opens',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      final api = _FakeAsmrApiService(
        beforeFetchSearchResponse: (_) async {
          if (!started.isCompleted) started.complete();
          await release.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.initializeForVisiblePage();
      controller.beginSearchSession();
      final pending = controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
        searchQuery: 'old',
        searchSession: true,
      );
      await started.future;
      controller.endSearchSession();
      controller.beginSearchSession();
      release.complete();
      await pending;
      expect(
        controller
            .categoryViewState(
              AsmrCategoryType.release,
              searchQuery: 'old',
              searchSession: true,
            )
            .hasAttemptedLoad,
        isFalse,
      );
      expect(
        controller
            .categoryViewState(
              AsmrCategoryType.release,
              searchQuery: 'old',
              searchSession: true,
            )
            .works,
        isEmpty,
      );
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        isEmpty,
      );
    },
  );

  test(
    'detail tree force refresh refetches while playback reads reuse the runtime tree',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(
        trackTree: [_trackFile('track.mp3', 'track.mp3')],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      final work = _work(id: 72, title: 'Work');
      final initial = await controller.ensureTrackTree(work);
      expect(await controller.ensureTrackTree(work), same(initial));
      await Future.wait([
        controller.ensureTrackTree(work, forceRefresh: true),
        controller.ensureTrackTree(work, forceRefresh: true),
      ]);
      expect(api.trackFetchWorkIds, [72, 72]);
    },
  );

  test(
    'runtime clearing rejects trees while background sorting is pending',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(
        trackTree: [
          for (var i = 2000; i > 0; i--)
            _trackFile('Track $i.mp3', 'Track $i.mp3'),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      final request = controller.ensureTrackTree(_work(id: 72, title: 'Work'));
      final rejected = expectLater(request, throwsStateError);
      // Drain the API's Future continuations without delivering the worker's
      // event-queue response, so invalidation happens during async sorting.
      for (var i = 0; i < 8; i++) {
        await Future<void>.value();
      }
      expect(api.trackFetchWorkIds, [72]);
      expect(controller.trackTreeFor(72), isNull);
      expect(controller.trackTreeViewState(72).isLoading, isTrue);
      controller.clearRuntimeCaches();
      await rejected;
      expect(controller.trackTreeFor(72), isNull);
      expect(api.trackFetchWorkIds, [72]);
    },
  );

  for (final accountChange in [false, true]) {
    test(
      '${accountChange ? 'account' : 'language'} changes discard a sorted tree before caching and reload it',
      () async {
        await resetPrefs();
        final replacementStarted = Completer<void>();
        final replacementReleased = Completer<void>();
        var fetches = 0;
        final api = _FakeAsmrApiService(
          trackTree: [_trackFile('Track 2.mp3', 'Track 2.mp3')],
          beforeFetchTrackTree: (_) async {
            if (++fetches == 2) {
              replacementStarted.complete();
              await replacementReleased.future;
            }
          },
        );
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          apiService: api,
          persistenceRepository: persistenceRepository(),
        );
        await controller.initializeForVisiblePage();
        final request = controller.ensureTrackTree(
          _work(id: 72, title: 'Work'),
        );
        for (var i = 0; i < 8; i++) {
          await Future<void>.value();
        }
        expect(controller.trackTreeFor(72), isNull);
        final authUpdate = accountChange
            ? controller.logoutAsmrAccount()
            : null;
        if (!accountChange) controller.setPageLanguage(AppLanguage.en);
        await replacementStarted.future;
        await authUpdate;
        expect(controller.trackTreeFor(72), isNull);
        replacementReleased.complete();
        final tree = await request;
        expect(tree.single.title, 'Track 2.mp3');
        expect(controller.trackTreeFor(72), same(tree));
        expect(api.trackFetchWorkIds, [72, 72]);
      },
    );
  }

  test(
    'runtime clearing rejects pending file trees without starting a replacement request',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      final api = _FakeAsmrApiService(
        beforeFetchTrackTree: (_) async {
          started.complete();
          await release.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      final request = controller.ensureTrackTree(_work(id: 72, title: 'Work'));
      await started.future;
      final rejected = expectLater(request, throwsStateError);
      controller.clearRuntimeCaches();
      release.complete();
      await rejected;
      expect(api.trackFetchWorkIds, [72]);
      expect(controller.trackTreeFor(72), isNull);
    },
  );

  test(
    'runtime clearing removes root pages and suppresses pending list responses',
    () async {
      await resetPrefs();
      final started = Completer<void>();
      final release = Completer<void>();
      final api = _FakeAsmrApiService(
        beforeFetchWorkResponse: (_) async {
          started.complete();
          await release.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.initializeForVisiblePage();
      final pending = controller.ensureCategoryLoaded(AsmrCategoryType.release);
      await started.future;
      controller.clearRuntimeCaches();
      release.complete();
      await pending;
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        isEmpty,
      );
      expect(controller.hasLoadedCategory(AsmrCategoryType.release), isFalse);
    },
  );

  for (final operation in ['ensure', 'refresh', 'loadMore']) {
    test(
      'search $operation awaiting initialization cannot dispatch into a replacement session',
      () async {
        await resetPrefs();
        final api = _FakeAsmrApiService();
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          apiService: api,
          persistenceRepository: persistenceRepository(),
        );
        await controller.initializeForVisiblePage();
        api.fetchWorkRequests.clear();
        api.searchWorkRequests.clear();
        api.searchKeywords.clear();
        controller.beginSearchSession();
        final pending = switch (operation) {
          'ensure' => controller.ensureCategoryLoaded(
            AsmrCategoryType.release,
            searchQuery: 'old',
            searchSession: true,
          ),
          'refresh' => controller.refreshCategory(
            AsmrCategoryType.release,
            searchQuery: 'old',
            searchSession: true,
          ),
          _ => controller.loadMoreCategory(
            AsmrCategoryType.release,
            searchQuery: 'old',
            searchSession: true,
          ),
        };
        controller.endSearchSession();
        controller.beginSearchSession();
        await pending;
        expect(api.fetchWorkRequests, isEmpty);
        expect(api.searchWorkRequests, isEmpty);
        expect(
          controller
              .categoryViewState(
                AsmrCategoryType.release,
                searchQuery: 'old',
                searchSession: true,
              )
              .hasAttemptedLoad,
          isFalse,
        );
        await controller.ensureCategoryLoaded(
          AsmrCategoryType.release,
          searchQuery: 'new',
          searchSession: true,
        );
        expect(api.searchKeywords, everyElement('new'));
        expect(api.searchKeywords, isNotEmpty);
      },
    );
  }

  test(
    'category entry awaiting initialization ignores a content scope change',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      await controller.initializeForVisiblePage();
      api.fetchWorkRequests.clear();
      final pending = controller.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(controller.setPageLanguage(AppLanguage.en), isTrue);
      await pending;
      expect(api.fetchWorkRequests, isEmpty);
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(api.fetchWorkRequests, hasLength(1));
      expect(controller.contentLanguage, AsmrContentLanguage.en);
    },
  );

  test('pagination data commits despite UI generation changes', () async {
    await resetPrefs();
    final coordinator = UiInteractionCoordinator.instance;
    coordinator.resetForTest();
    addTearDown(coordinator.resetForTest);
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: _FakeAsmrApiService(largeRecommendationPool: true),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.refreshCategory(AsmrCategoryType.release);
    expect(controller.worksFor(AsmrCategoryType.release), hasLength(40));
    final firstPage = controller.worksFor(AsmrCategoryType.release);

    final interactionSource = Object();
    coordinator.beginInteraction(interactionSource);
    await controller.loadMoreCategory(AsmrCategoryType.release);
    expect(controller.isLoadingMoreCategory(AsmrCategoryType.release), isFalse);

    coordinator.beginGeneration();
    coordinator.finishInteractionsForTest();

    expect(controller.worksFor(AsmrCategoryType.release), hasLength(80));
    expect(
      controller.worksFor(AsmrCategoryType.release).first,
      same(firstPage.first),
    );
    expect(controller.isLoadingMoreCategory(AsmrCategoryType.release), isFalse);
  });

  test('category failures stay isolated across concurrent refreshes', () async {
    await resetPrefs();
    final releaseRequestStarted = Completer<void>();
    final releaseRequest = Completer<void>();
    final api = _FakeAsmrApiService(
      beforeFetchWorkResponse: (request) async {
        if (request != 'release:desc:1') return;
        releaseRequestStarted.complete();
        await releaseRequest.future;
        throw const HttpException('Simulated release failure');
      },
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    final failingRefresh = controller.refreshCategory(AsmrCategoryType.release);
    await releaseRequestStarted.future;
    await controller.refreshCategory(AsmrCategoryType.sales);

    expect(
      controller.categoryViewState(AsmrCategoryType.sales).operationError,
      isNull,
    );

    releaseRequest.complete();
    await failingRefresh;

    expect(
      controller.categoryViewState(AsmrCategoryType.release).operationError,
      isA<HttpException>(),
    );
    expect(
      controller.categoryViewState(AsmrCategoryType.sales).operationError,
      isNull,
    );
  });

  test('pagination stops when loaded works reach the reported total', () async {
    await resetPrefs();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: _FakeAsmrApiService(
        recommendationWorks: <AsmrWork>[
          for (var index = 1; index <= 41; index++)
            _work(id: index, title: 'Result $index'),
        ],
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );

    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.refreshCategory(AsmrCategoryType.release);

    expect(controller.worksFor(AsmrCategoryType.release), hasLength(41));
    expect(controller.hasMoreCategory(AsmrCategoryType.release), isFalse);
  });

  test('short pagination pages are treated as the end of the catalog', () {
    final page = AsmrWorkPage(
      works: <AsmrWork>[_work(id: 1, title: 'Only result')],
      currentPage: 1,
      pageSize: 40,
      totalCount: 200,
    );

    expect(page.hasMore, isFalse);
  });

  test('pagination failure waits for manual retry and recovers', () async {
    await resetPrefs();
    var failNextPage = true;
    final api = _FakeAsmrApiService(
      largeRecommendationPool: true,
      recommendationPageCount: 3,
      beforeFetchWorkResponse: (request) async {
        if (request == 'release:desc:2' && failNextPage) {
          throw const HttpException('Simulated pagination failure');
        }
      },
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.refreshCategory(AsmrCategoryType.release);

    await controller.loadMoreCategory(AsmrCategoryType.release);

    expect(
      controller.categoryViewState(AsmrCategoryType.release).needsLoadMoreRetry,
      isTrue,
    );
    expect(controller.worksFor(AsmrCategoryType.release), hasLength(40));

    failNextPage = false;
    await controller.loadMoreCategory(AsmrCategoryType.release);

    final recovered = controller.categoryViewState(AsmrCategoryType.release);
    expect(recovered.needsLoadMoreRetry, isFalse);
    expect(recovered.works, hasLength(80));
  });

  test('pagination with no new works waits for manual retry', () async {
    await resetPrefs();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: _FakeAsmrApiService(
        largeRecommendationPool: true,
        repeatPaginatedWorks: true,
        recommendationPageCount: 3,
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.refreshCategory(AsmrCategoryType.release);

    await controller.loadMoreCategory(AsmrCategoryType.release);

    final state = controller.categoryViewState(AsmrCategoryType.release);
    expect(state.works, hasLength(40));
    expect(state.needsLoadMoreRetry, isTrue);
  });

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
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        persistenceRepository: _FakeTestPersistenceRepository(
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

class _FailingHiddenTrackPreferences extends AsmrPreferencesStore {
  _FailingHiddenTrackPreferences({required super.repository});

  @override
  Future<void> saveHiddenTracks(Set<String> keys) async {
    throw const FileSystemException('forced hidden-track write failure');
  }
}

class _BrowseChangingApi extends AsmrApiService {
  int shift = 0;
  int total = 8;
  final List<int> pages = [];
  @override
  Future<AsmrWorkPage> fetchWorks({
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    pages.add(page);
    return AsmrWorkPage(
      works: [
        for (var id = (page - 1) * 2 + 1; id <= page * 2; id++)
          _work(id: id + shift, title: 'Work ${id + shift}'),
      ],
      currentPage: page,
      pageSize: 2,
      totalCount: total,
    );
  }
}
