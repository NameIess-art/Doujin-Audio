part of 'asmr_one_settings_test.dart';

void registerAsmrRemoteCatalogTests({
  required Future<void> Function([Map<String, Object> values]) resetPrefs,
  required AsmrPreferencesStore Function() preferencesStore,
}) {
  late AsmrPreferencesStore preferences;
  setUp(() => preferences = preferencesStore());

  test(
    'ASMR controller ranks recommendations from ordinary work lists',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(<MusicTrack>[
          _track(groupTitle: 'Dream Circle', tags: <String>['sleep']),
        ]),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.refreshCategory(AsmrCategoryType.recommendation);
      expect(api.fetchWorkOrders, contains('create_date:desc'));
      expect(api.fetchWorkOrders, contains('dl_count:desc'));
      expect(api.fetchWorkOrders, contains('rate_average_2dp:desc'));
      expect(api.fetchWorkOrders, contains('release:desc'));
      expect(
        controller.hasMoreCategory(AsmrCategoryType.recommendation),
        isFalse,
      );
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.title,
        'Sleep Match',
      );
    },
  );

  test('ASMR recommendation tolerates one failed candidate source', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(
      failingFetchOrders: const <String>{'release'},
    );
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.recommendation);

    expect(controller.lastError, isNull);
    expect(
      controller
          .worksFor(AsmrCategoryType.recommendation)
          .map((work) => work.id),
      containsAll(<int>[9, 10, 11]),
    );
    expect(
      controller
          .worksFor(AsmrCategoryType.recommendation)
          .map((work) => work.id),
      isNot(contains(12)),
    );
  });

  test('ASMR review count category uses review count ordering', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.reviews);

    expect(api.fetchWorkOrders, contains('review_count:desc'));
    expect(
      controller.worksFor(AsmrCategoryType.reviews).map((work) => work.id),
      <int>[13],
    );
  });

  test('ASMR category marks first load attempt before empty state', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    expect(
      controller.categoryViewState(AsmrCategoryType.release).hasAttemptedLoad,
      isFalse,
    );

    await controller.refreshCategory(AsmrCategoryType.release);

    expect(
      controller.categoryViewState(AsmrCategoryType.release).hasAttemptedLoad,
      isTrue,
    );
  });

  test('ASMR category retries transient handshake failures', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(transientFetchFailuresRemaining: 1);
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.release);

    expect(controller.lastError, isNull);
    expect(
      api.fetchWorkRequests.where((request) => request == 'release:desc:1'),
      hasLength(2),
    );
    expect(
      controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
      <int>[12],
    );
  });

  test(
    'ASMR category refresh does not wait for slow account restore',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final auth = _BlockingAsmrAuthService();
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: auth,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );

      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await Future<void>.delayed(Duration.zero);

      expect(controller.initialized, isTrue);
      expect(auth.restoreCount, 1);
      expect(controller.isAsmrAccountLoggedIn, isFalse);
      expect(controller.authViewState.isRestoring, isTrue);

      await controller.refreshCategory(AsmrCategoryType.release);

      expect(api.fetchWorkRequests, <String>['release:desc:1']);
      expect(
        controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
        <int>[12],
      );

      auth.complete(
        const AsmrAuthSession(token: 'token', userName: 'restored'),
      );
      await controller.restoreAsmrAccountSession();

      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.authViewState.isRestoring, isFalse);
    },
  );

  test('ASMR refresh commits business state while interacting', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    final coordinator = UiInteractionCoordinator.instance;
    coordinator.resetForTest();
    final source = Object();
    final notifications = <bool>[];
    controller.addListener(
      () => notifications.add(
        controller.isLoadingCategory(AsmrCategoryType.release),
      ),
    );

    coordinator.beginInteraction(source);
    await controller.refreshCategory(AsmrCategoryType.release);

    expect(notifications, isNotEmpty);
    expect(
      controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
      <int>[12],
    );
    expect(controller.isLoadingCategory(AsmrCategoryType.release), isFalse);

    coordinator.finishInteractionsForTest();

    expect(notifications, isNotEmpty);
    expect(
      controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
      <int>[12],
    );
    expect(controller.isLoadingCategory(AsmrCategoryType.release), isFalse);
    coordinator.resetForTest();
  });

  test('ASMR recommendation search uses ordinary search candidates', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(
      AsmrCategoryType.recommendation,
      searchQuery: 'sleep',
    );

    expect(api.searchKeywords, everyElement('sleep'));
    expect(controller.activeQueryFor(AsmrCategoryType.recommendation), 'sleep');
    expect(
      controller
          .worksFor(AsmrCategoryType.recommendation)
          .map((work) => work.id),
      contains(21),
    );
  });

  test('ASMR recommendation refresh changes full result order', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(largeRecommendationPool: true);
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.recommendation);
    final firstIds = controller
        .worksFor(AsmrCategoryType.recommendation)
        .map((work) => work.id)
        .toList(growable: false);
    expect(firstIds, hasLength(320));

    await controller.refreshCategory(AsmrCategoryType.recommendation);
    final secondIds = controller
        .worksFor(AsmrCategoryType.recommendation)
        .map((work) => work.id)
        .toList(growable: false);

    expect(secondIds, hasLength(firstIds.length));
    expect(firstIds.toSet(), secondIds.toSet());
    expect(firstIds, isNot(secondIds));
  });

  test('ASMR recommendation loads extra candidate pages', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(largeRecommendationPool: true);
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.recommendation);

    expect(api.fetchWorkRequests, contains('create_date:desc:2'));
    expect(api.fetchWorkRequests, contains('dl_count:desc:2'));
    expect(api.fetchWorkRequests, contains('rate_average_2dp:desc:2'));
    expect(api.fetchWorkRequests, contains('release:desc:2'));
  });

  test('ASMR recommendation starts candidate sources concurrently', () async {
    await resetPrefs();
    final firstPageRequests = <String>{
      'create_date:desc:1',
      'dl_count:desc:1',
      'rate_average_2dp:desc:1',
      'release:desc:1',
    };
    final blockers = <String, Completer<void>>{};
    final allFirstPagesStarted = Completer<void>();
    final api = _FakeAsmrApiService(
      largeRecommendationPool: true,
      beforeFetchWorkResponse: (request) async {
        if (!firstPageRequests.contains(request)) {
          return;
        }
        final blocker = Completer<void>();
        blockers[request] = blocker;
        if (blockers.length == firstPageRequests.length &&
            !allFirstPagesStarted.isCompleted) {
          allFirstPagesStarted.complete();
        }
        await blocker.future;
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

    final refresh = controller.refreshCategory(AsmrCategoryType.recommendation);

    try {
      await allFirstPagesStarted.future.timeout(const Duration(seconds: 1));

      expect(api.fetchWorkRequests, containsAll(firstPageRequests));
      expect(api.fetchWorkRequests, isNot(contains('create_date:desc:2')));
      expect(api.fetchWorkRequests, isNot(contains('dl_count:desc:2')));
      expect(api.fetchWorkRequests, isNot(contains('rate_average_2dp:desc:2')));
      expect(api.fetchWorkRequests, isNot(contains('release:desc:2')));
    } finally {
      for (final blocker in blockers.values) {
        if (!blocker.isCompleted) {
          blocker.complete();
        }
      }
    }

    await refresh;
    expect(controller.lastError, isNull);
    expect(api.fetchWorkRequests, contains('create_date:desc:2'));
    expect(api.fetchWorkRequests, contains('dl_count:desc:2'));
    expect(api.fetchWorkRequests, contains('rate_average_2dp:desc:2'));
    expect(api.fetchWorkRequests, contains('release:desc:2'));
  });

  test(
    'ASMR recommendation stops candidate paging after refresh window',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(
        largeRecommendationPool: true,
        recommendationPageCount: 20,
      );
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.refreshCategory(AsmrCategoryType.recommendation);

      expect(api.fetchWorkRequests, contains('create_date:desc:2'));
      expect(api.fetchWorkRequests, isNot(contains('create_date:desc:3')));
      expect(api.fetchWorkRequests, isNot(contains('dl_count:desc:3')));
      expect(api.fetchWorkRequests, isNot(contains('rate_average_2dp:desc:3')));
      expect(api.fetchWorkRequests, isNot(contains('release:desc:3')));
    },
  );

  test(
    'ASMR recommendation hides favorite history and local-owned works',
    () async {
      await resetPrefs();
      final favorite = _work(
        id: 31,
        title: 'Favorite Sleep',
        tags: <String>['sleep'],
      );
      final history = _work(
        id: 32,
        title: 'History Sleep',
        tags: <String>['sleep'],
      );
      await preferences.saveFavoriteWorks(<AsmrWork>[favorite]);
      await preferences.saveHistoryWorks(<AsmrWork>[history]);
      final api = _FakeAsmrApiService(
        recommendationWorks: <AsmrWork>[
          favorite,
          history,
          _work(id: 33, title: 'Local Sleep', tags: <String>['sleep']),
          _work(id: 34, title: 'Visible Sleep', tags: <String>['sleep']),
        ],
      );
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(<MusicTrack>[
          _track(
            groupTitle: 'Local Circle',
            groupSubtitle: 'RJ000033',
            tags: <String>['sleep'],
          ),
        ]),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.refreshCategory(AsmrCategoryType.recommendation);

      expect(
        controller
            .worksFor(AsmrCategoryType.recommendation)
            .map((work) => work.id),
        <int>[34],
      );
    },
  );

  test(
    'ASMR category view state caches local filtered works until revision changes',
    () async {
      final favorite = _work(
        id: 41,
        title: 'Sleep Favorite',
        tags: <String>['sleep'],
      );
      await resetPrefs();
      await preferences.saveFavoriteWorks(<AsmrWork>[favorite]);
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      final first = controller.categoryViewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
      );
      final second = controller.categoryViewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
      );

      expect(first, second);
      expect(identical(first.works, second.works), isTrue);
      expect(first.works.map((work) => work.id), <int>[41]);

      await controller.toggleFavorite(
        _work(id: 42, title: 'Sleep New', tags: <String>['sleep']),
      );
      final third = controller.categoryViewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
      );

      expect(third.revision, greaterThan(first.revision));
      expect(identical(first.works, third.works), isFalse);
      expect(third.works.map((work) => work.id), <int>[42, 41]);
    },
  );

  test(
    'ASMR category provider keeps favorite and history searches isolated',
    () async {
      final favoriteMatch = _work(id: 51, title: 'Sleep Favorite');
      final favoriteMiss = _work(id: 52, title: 'Morning Favorite');
      final historyMatch = _work(id: 53, title: 'Sleep History');
      final historyMiss = _work(id: 54, title: 'Morning History');
      await resetPrefs();
      await preferences.saveFavoriteWorks(<AsmrWork>[
        favoriteMatch,
        favoriteMiss,
      ]);
      await preferences.saveHistoryWorks(<AsmrWork>[historyMatch, historyMiss]);
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);

      Future<List<int>> workIds(
        AsmrCategoryType category,
        String searchQuery,
      ) async {
        final request = (category: category, searchQuery: searchQuery);
        final subscription = container.listen(
          asmrCategoryStateProvider(request),
          (_, _) {},
        );
        final state = await container.read(
          asmrCategoryStateProvider(request).future,
        );
        subscription.close();
        return state!.works.map((work) => work.id).toList(growable: false);
      }

      expect(await workIds(AsmrCategoryType.favorites, 'sleep'), <int>[51]);
      expect(await workIds(AsmrCategoryType.history, 'sleep'), <int>[53]);
      expect(await workIds(AsmrCategoryType.favorites, ''), <int>[51, 52]);
      expect(await workIds(AsmrCategoryType.history, ''), <int>[53, 54]);
    },
  );
}
