part of 'asmr_one_settings_test.dart';

void registerAsmrAccountSyncTests({
  required Future<void> Function([Map<String, Object> values]) resetPrefs,
  required AsmrPreferencesStore Function() preferencesStore,
}) {
  late AsmrPreferencesStore preferences;
  setUp(() => preferences = preferencesStore());

  test('ASMR auth service stores restores and clears token', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final tokenStore = _MemoryAsmrTokenStore();
    final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);

    final session = await auth.login('alice', 'password');

    expect(session.token, 'token-alice');
    expect(tokenStore.token, 'token-alice');
    expect((await auth.restoreSession())?.userName, 'alice');

    await auth.logout();

    expect(tokenStore.token, isNull);
    expect(await auth.restoreSession(), isNull);
  });

  test(
    'ASMR auth restore uses saved account name when session check omits it',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(emptyCheckSessionUserName: true);
      final tokenStore = _MemoryAsmrTokenStore();
      await tokenStore.writeToken('cached-token');
      await tokenStore.writeCredentials('alice', 'password');
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);

      final session = await auth.restoreSession();

      expect(session?.token, 'cached-token');
      expect(session?.userName, 'alice');
      expect(tokenStore.token, 'cached-token');
    },
  );

  test(
    'ASMR auth provider emits completed state when first watched after restore',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(emptyCheckSessionUserName: true);
      final tokenStore = _MemoryAsmrTokenStore();
      await tokenStore.writeToken('cached-token');
      await tokenStore.writeCredentials('alice', 'password');
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.zh);
      await controller.restoreAsmrAccountSession();
      expect(controller.authViewState.isRestoring, isFalse);
      expect(controller.authViewState.isLoggedIn, isTrue);
      expect(controller.authViewState.userName, 'alice');

      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(asmrAuthStateProvider, (_, _) {});
      addTearDown(subscription.close);

      final state = await container
          .read(asmrAuthStateProvider.future)
          .timeout(const Duration(milliseconds: 200));

      expect(state, isNotNull);
      expect(state!.isRestoring, isFalse);
      expect(state.isLoggedIn, isTrue);
      expect(state.userName, 'alice');
    },
  );

  test(
    'ASMR persisted state reload waits for updated secure account state',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(emptyCheckSessionUserName: true);
      final tokenStore = _MemoryAsmrTokenStore();
      await tokenStore.writeToken('current-token');
      await tokenStore.writeCredentials('current-user', 'current-password');
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize(defaultLanguage: AsmrContentLanguage.zh);
      await controller.restoreAsmrAccountSession();
      expect(controller.authViewState.userName, 'current-user');

      await tokenStore.writeToken('updated-token');
      await tokenStore.writeCredentials('updated-user', 'updated-password');

      await controller.reloadPersistedState();

      expect(controller.authViewState.isRestoring, isFalse);
      expect(controller.authViewState.isLoggedIn, isTrue);
      expect(controller.authViewState.userName, 'updated-user');
    },
  );

  test(
    'ASMR account sync maps favorites to marked review progress and retries',
    () async {
      await resetPrefs();
      final local = _work(id: 71, title: 'Local Favorite');
      final remote = _work(id: 72, title: 'Remote Favorite');
      await preferences.saveFavoriteWorks(<AsmrWork>[local]);
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: remote,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ],
        failPutReviewCount: 1,
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.loginAsmrAccount('alice', 'password');

      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.syncViewState.phase, AsmrSyncPhase.failed);
      expect(controller.syncViewState.pendingCount, 1);
      expect(
        controller.worksFor(AsmrCategoryType.favorites).map((work) => work.id),
        <int>[71],
      );
      expect(api.calls.where((call) => call.startsWith('fetch:')), isEmpty);

      await controller.syncAsmrAccount(force: true);

      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(controller.syncViewState.pendingCount, 0);
      expect(api.reviewPuts, <String>['71:marked']);
      expect(
        controller.worksFor(AsmrCategoryType.favorites).map((work) => work.id),
        containsAll(<int>[71, 72]),
      );
    },
  );

  test(
    'ASMR account sync removes remote marked progress when unfavorited',
    () async {
      await resetPrefs();
      final work = _work(id: 82, title: 'Marked Favorite');
      await preferences.saveFavoriteWorks(<AsmrWork>[work]);
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: work,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.loginAsmrAccount('alice', 'password');
      await controller.toggleFavorite(work.copyWith(isFavorite: true));
      await controller.syncAsmrAccount();

      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(controller.syncViewState.pendingCount, 0);
      expect(api.deletedReviewWorkIds, <int>[82]);
      expect(controller.worksFor(AsmrCategoryType.favorites), isEmpty);
    },
  );

  test(
    'ASMR account sync keeps marked favorites from history downgrade',
    () async {
      await resetPrefs();
      final work = _work(id: 83, title: 'Marked Favorite');
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: work,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.loginAsmrAccount('alice', 'password');
      await controller.recordHistory(work);
      await controller.syncAsmrAccount(force: true);

      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(controller.syncViewState.pendingCount, 0);
      expect(api.reviewPuts.where((call) => call == '83:listening'), isEmpty);
    },
  );

  test(
    'favorite metadata remains authoritative in history after reload',
    () async {
      await resetPrefs();
      final service = AsmrAccountSyncService(
        authService: AsmrAuthService(
          apiService: _FakeAsmrApiService(),
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        apiService: _FakeAsmrApiService(),
        preferencesStore: preferences,
      );
      await service.initialize();
      final history = _work(id: 84, title: 'History metadata');
      final favorite = _work(id: 84, title: 'Favorite metadata');

      await service.recordHistory(history);
      await service.toggleFavorite(favorite);

      final reloaded = AsmrAccountSyncService(
        authService: AsmrAuthService(
          apiService: _FakeAsmrApiService(),
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        apiService: _FakeAsmrApiService(),
        preferencesStore: preferences,
      );
      final snapshot = await reloaded.initialize();
      expect(snapshot.favoriteWorks.single.title, 'Favorite metadata');
      expect(snapshot.historyWorks.single.title, 'Favorite metadata');
      expect(snapshot.favoriteWorks.single.isFavorite, isTrue);
      expect(snapshot.historyWorks.single.isFavorite, isTrue);
    },
  );

  test(
    'failed account state write leaves the in-memory snapshot unchanged',
    () async {
      await resetPrefs();
      final failingPreferences = _FailingAsmrPreferencesStore(
        repository: TestPersistenceRepository(),
      );
      final service = AsmrAccountSyncService(
        authService: AsmrAuthService(
          apiService: _FakeAsmrApiService(),
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        apiService: _FakeAsmrApiService(),
        preferencesStore: failingPreferences,
      );
      await service.initialize();

      await expectLater(
        service.toggleFavorite(_work(id: 85, title: 'Rejected favorite')),
        throwsA(isA<FileSystemException>()),
      );

      expect(service.snapshot.favoriteWorks, isEmpty);
      expect(service.snapshot.historyWorks, isEmpty);
      expect(service.snapshot.pendingOperations, isEmpty);

      await expectLater(
        service.recordHistory(_work(id: 86, title: 'Rejected history')),
        throwsA(isA<FileSystemException>()),
      );
      expect(service.snapshot.favoriteWorks, isEmpty);
      expect(service.snapshot.historyWorks, isEmpty);
      expect(service.snapshot.pendingOperations, isEmpty);
    },
  );

  test(
    'recording history retains favorite and unchanged work identities',
    () async {
      await resetPrefs();
      await preferences.saveFavoriteWorks([
        for (var id = 1; id <= 1000; id++) _work(id: id, title: 'Favorite $id'),
      ]);
      await preferences.saveHistoryWorks([
        for (var id = 1001; id <= 1060; id++)
          _work(id: id, title: 'History $id'),
      ]);
      final service = AsmrAccountSyncService(
        authService: AsmrAuthService(
          apiService: _FakeAsmrApiService(),
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        apiService: _FakeAsmrApiService(),
        preferencesStore: preferences,
      );
      final before = await service.initialize();
      final after = await service.recordHistory(
        _work(id: 1000, title: 'Stale title'),
      );
      expect(after.favoriteWorks, same(before.favoriteWorks));
      expect(after.favoriteWorks.last, same(before.favoriteWorks.last));
      expect(after.historyWorks.first, same(before.favoriteWorks.last));
      expect(after.historyWorks[1], same(before.historyWorks.first));
      expect(after.historyWorks, hasLength(60));
      expect(after.historyWorks.map((item) => item.id), [
        1000,
        ...List.generate(59, (index) => 1001 + index),
      ]);
      final reloaded = await preferences.loadHistoryWorks();
      expect(reloaded.first.title, 'Favorite 1000');
      expect(
        reloaded.map((item) => item.id),
        after.historyWorks.map((item) => item.id),
      );
    },
  );

  test(
    'ASMR account sync refreshes expired token with saved credentials',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await controller.loginAsmrAccount('alice', 'password');

      final loginCountBefore = api.loginCount;
      api.fetchReviewAuthFailuresRemaining = 1;
      api.checkSessionAuthFailuresRemaining = 1;
      await controller.syncAsmrAccount(force: true);

      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.asmrAccountName, 'alice');
      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(api.loginCount, loginCountBefore + 1);
      expect(tokenStore.token, 'token-alice');
    },
  );

  test(
    'ASMR account sync logs out when expired token cannot be recovered',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await controller.loginAsmrAccount('alice', 'password');

      api.fetchReviewAuthFailuresRemaining = 1;
      api.checkSessionAuthFailuresRemaining = 1;
      api.loginFailureStatusCode = HttpStatus.forbidden;
      await controller.syncAsmrAccount(force: true);

      expect(controller.isAsmrAccountLoggedIn, isFalse);
      expect(controller.syncViewState.phase, AsmrSyncPhase.failed);
      expect(controller.syncViewState.lastError, isA<AsmrApiException>());
      expect(tokenStore.token, isNull);
      expect(await tokenStore.readCredentials(), isNull);
    },
  );

  test('ASMR sync pushes local changes before pulling remote state', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.toggleFavorite(_work(id: 91, title: 'Local Favorite'));

    await controller.loginAsmrAccount('alice', 'password');

    final putIndex = api.calls.indexOf('put:91:marked');
    final pullIndex = api.calls.indexWhere((call) => call.startsWith('fetch:'));
    expect(putIndex, greaterThanOrEqualTo(0));
    expect(pullIndex, greaterThan(putIndex));
    expect(controller.syncViewState.pendingCount, 0);
    expect(
      controller.worksFor(AsmrCategoryType.favorites).map((work) => work.id),
      contains(91),
    );
  });

  test('ASMR history preflight never downgrades a remote favorite', () async {
    await resetPrefs();
    final work = _work(id: 92, title: 'Remote Favorite');
    final api = _FakeAsmrApiService(
      remoteReviewRecords: <AsmrReviewRecord>[
        AsmrReviewRecord(
          work: work,
          progress: 'marked',
          updatedAt: DateTime(2026, 6),
        ),
      ],
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.recordHistory(work);

    await controller.loginAsmrAccount('alice', 'password');

    expect(api.reviewPuts, isNot(contains('92:listening')));
    expect(api.calls.first, 'fetch:marked:1');
    expect(controller.syncViewState.pendingCount, 0);
  });

  test('ASMR remote favorites and history are sorted newest first', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(
      remoteReviewRecords: <AsmrReviewRecord>[
        AsmrReviewRecord(
          work: _work(id: 93, title: 'Older Favorite'),
          progress: 'marked',
          updatedAt: DateTime(2026, 5),
        ),
        AsmrReviewRecord(
          work: _work(id: 94, title: 'Newer Favorite'),
          progress: 'marked',
          updatedAt: DateTime(2026, 6),
        ),
        AsmrReviewRecord(
          work: _work(id: 95, title: 'Older History'),
          progress: 'listening',
          updatedAt: DateTime(2026, 4),
        ),
        AsmrReviewRecord(
          work: _work(id: 96, title: 'Newer History'),
          progress: 'listening',
          updatedAt: DateTime(2026, 6, 2),
        ),
      ],
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.loginAsmrAccount('alice', 'password');

    expect(
      controller.worksFor(AsmrCategoryType.favorites).map((work) => work.id),
      <int>[94, 93],
    );
    expect(
      controller.worksFor(AsmrCategoryType.history).map((work) => work.id),
      <int>[96, 95],
    );
  });

  test('ASMR manual refresh synchronizes before loading category', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.loginAsmrAccount('alice', 'password');
    api.calls.clear();

    await controller.refreshCategoryWithSync(AsmrCategoryType.release);

    final pullIndex = api.calls.indexWhere((call) => call.startsWith('fetch:'));
    final categoryIndex = api.calls.indexOf('works:release:desc:1');
    expect(pullIndex, greaterThanOrEqualTo(0));
    expect(categoryIndex, greaterThan(pullIndex));
  });

  test('ASMR sync failure only marks the requested category', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.loginAsmrAccount('alice', 'password');
    api.fetchReviewAuthFailuresRemaining = 1;
    api.checkSessionAuthFailuresRemaining = 1;
    api.loginFailureStatusCode = HttpStatus.forbidden;

    await controller.refreshCategoryWithSync(AsmrCategoryType.release);

    expect(controller.syncViewState.phase, AsmrSyncPhase.failed);
    expect(
      controller.categoryViewState(AsmrCategoryType.release).operationError,
      same(controller.syncViewState.lastError),
    );
    expect(
      controller.categoryViewState(AsmrCategoryType.sales).operationError,
      isNull,
    );
  });

  test(
    'ASMR initialize restores account without blocking category load',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      await tokenStore.writeToken('cached-token');
      await tokenStore.writeCredentials('alice', 'password');
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );

      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      expect(controller.initialized, isTrue);
      expect(api.calls, isEmpty);

      await controller.refreshCategory(AsmrCategoryType.release);

      expect(api.calls, <String>['works:release:desc:1']);
      await controller.restoreAsmrAccountSession();
      expect(controller.isAsmrAccountLoggedIn, isTrue);
    },
  );

  test('ASMR sync drains changes added while a batch is running', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    late final AsmrLibraryController controller;
    controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.toggleFavorite(_work(id: 97, title: 'Favorite'));
    api.onPutReview = (_, _) async {
      await controller.recordHistory(_work(id: 98, title: 'History'));
    };

    await controller.loginAsmrAccount('alice', 'password');

    expect(api.reviewPuts, containsAll(<String>['97:marked', '98:listening']));
    expect(controller.syncViewState.pendingCount, 0);
    expect(
      controller.worksFor(AsmrCategoryType.history).map((work) => work.id),
      contains(98),
    );
  });

  for (final history in [false, true]) {
    test(
      'sync completion drains ${history ? 'history' : 'favorites'} queued during the timestamp write',
      () async {
        await resetPrefs();
        final blockingPreferences = _LastSyncFailurePreferences(
          repository: TestPersistenceRepository(),
        )..failBlockedWrite = false;
        final api = _FakeAsmrApiService();
        final controller = createTestAsmrController(
          preferencesStore: blockingPreferences,
          persistenceRepository: _FakeTestPersistenceRepository(const []),
          apiService: api,
          authService: AsmrAuthService(
            apiService: api,
            tokenStore: _MemoryAsmrTokenStore(),
          ),
        );
        await controller.initialize();
        await controller.loginAsmrAccount('alice', 'password');
        blockingPreferences.blockWrite = true;
        final sync = controller.syncAsmrAccount();
        await blockingPreferences.writeStarted.future;
        final work = _work(id: 407, title: 'Queued during completion');
        if (history) {
          await controller.recordHistory(work);
        } else {
          await controller.toggleFavorite(work);
        }
        expect(api.reviewPuts, isEmpty);
        expect(controller.syncViewState.pendingCount, 1);
        blockingPreferences.releaseWrite.complete();
        await sync.timeout(const Duration(seconds: 2));
        expect(api.reviewPuts, ['407:${history ? 'listening' : 'marked'}']);
        expect(controller.syncViewState.pendingCount, 0);
        expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      },
    );
  }

  for (final history in [false, true]) {
    test(
      'recovered token sync drains ${history ? 'history' : 'favorites'} queued during the timestamp write',
      () async {
        await resetPrefs();
        final blockingPreferences = _LastSyncFailurePreferences(
          repository: TestPersistenceRepository(),
        )..failBlockedWrite = false;
        final api = _FakeAsmrApiService();
        final tokenStore = _MemoryAsmrTokenStore();
        final services = createTestAsmrServices(
          preferencesStore: blockingPreferences,
          persistenceRepository: _FakeTestPersistenceRepository(const []),
          apiService: api,
          authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        );
        final controller = AsmrLibraryController(
          preferencesStore: services.preferencesStore,
          remoteCatalogService: services.remoteCatalogService,
          accountSyncService: services.accountSyncService,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.loginAsmrAccount('alice', 'password');
        api.loginTokenOverride = 'token-alice-renewed';
        api.fetchReviewAuthFailuresRemaining = 1;
        api.checkSessionAuthFailuresRemaining = 1;
        blockingPreferences.blockWrite = true;
        final sync = controller.syncAsmrAccount();
        await blockingPreferences.writeStarted.future;
        expect(tokenStore.token, 'token-alice-renewed');
        final work = _work(id: 410, title: 'Queued after token recovery');
        // Exercise the shared outbox while the controller still owns the old
        // request key; the successful sync must apply and continue the new one.
        if (history) {
          await services.accountSyncService.recordHistory(work);
        } else {
          await services.accountSyncService.toggleFavorite(work);
        }
        expect(controller.syncAsmrAccount(), same(sync));
        expect(api.reviewPuts, isEmpty);
        blockingPreferences.releaseWrite.complete();
        await sync.timeout(const Duration(seconds: 2));
        expect(api.reviewPuts, ['410:${history ? 'listening' : 'marked'}']);
        expect(api.reviewPutTokens, ['token-alice-renewed']);
        expect(controller.syncViewState.pendingCount, 0);
        expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      },
    );
  }

  test(
    'failed sync completion retains new operations without retrying',
    () async {
      await resetPrefs();
      final blockingPreferences = _LastSyncFailurePreferences(
        repository: TestPersistenceRepository(),
      );
      final api = _FakeAsmrApiService();
      final controller = createTestAsmrController(
        preferencesStore: blockingPreferences,
        persistenceRepository: _FakeTestPersistenceRepository(const []),
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
      );
      await controller.initialize();
      await controller.loginAsmrAccount('alice', 'password');
      blockingPreferences.blockWrite = true;
      final sync = controller.syncAsmrAccount();
      await blockingPreferences.writeStarted.future;
      await controller.toggleFavorite(_work(id: 408, title: 'Pending retry'));
      final calls = api.calls.length;
      blockingPreferences.releaseWrite.complete();
      await sync.timeout(const Duration(seconds: 2));
      expect(api.reviewPuts, isEmpty);
      expect(api.calls.length, calls);
      expect(controller.syncViewState.phase, AsmrSyncPhase.failed);
      expect(controller.syncViewState.pendingCount, 1);
    },
  );

  test(
    'logout cancels all pending account reads without requesting another page',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: _FakeTestPersistenceRepository(const []),
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
      );
      await controller.initialize();
      await controller.loginAsmrAccount('alice', 'password');
      api.calls.clear();
      api.reviewCancellationTokens.clear();
      final started = Completer<void>();
      final release = Completer<void>();
      api.beforeFetchReviews = () async {
        if (api.reviewCancellationTokens.length == 5) started.complete();
        await release.future;
      };
      final sync = controller.syncAsmrAccount();
      await started.future;
      await controller.logoutAsmrAccount();
      await sync.timeout(const Duration(seconds: 2));
      expect(api.reviewCancellationTokens, hasLength(5));
      expect(
        api.reviewCancellationTokens.every((token) => token!.isCancelled),
        isTrue,
      );
      expect(api.calls.every((call) => call.endsWith(':1')), isTrue);
      expect(controller.syncViewState.phase, AsmrSyncPhase.idle);
      release.complete();
    },
  );

  test(
    'failed persistent logout preserves the active account and permits retry',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: _FakeTestPersistenceRepository(const []),
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
      );
      await controller.initialize();
      await controller.loginAsmrAccount('alice', 'password');
      tokenStore.failClearToken = true;
      await expectLater(
        controller.logoutAsmrAccount(),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.asmrAccountName, 'alice');
      tokenStore.failClearToken = false;
      await controller.logoutAsmrAccount();
      expect(controller.isAsmrAccountLoggedIn, isFalse);
    },
  );

  test('ASMR local timestamps keep new favorites and history first', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(
      remoteReviewRecords: <AsmrReviewRecord>[
        AsmrReviewRecord(
          work: _work(id: 99, title: 'Older Remote Favorite'),
          progress: 'marked',
          updatedAt: DateTime(2026, 6),
        ),
        AsmrReviewRecord(
          work: _work(id: 100, title: 'Older Remote History'),
          progress: 'listening',
          updatedAt: DateTime(2026, 6),
        ),
      ],
    );
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.toggleFavorite(_work(id: 101, title: 'Local Favorite'));
    await controller.recordHistory(_work(id: 102, title: 'Local History'));
    await controller.loginAsmrAccount('alice', 'password');

    await controller.syncAsmrAccount(force: true);

    expect(controller.worksFor(AsmrCategoryType.favorites).first.id, 101);
    expect(controller.worksFor(AsmrCategoryType.history).first.id, 102);
  });

  test(
    'ASMR sync keeps local favorite first when remote timestamp lags',
    () async {
      await resetPrefs();
      final remoteFavorite = _work(id: 103, title: 'Remote Favorite');
      final localFavorite = _work(id: 104, title: 'Fresh Local Favorite');
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: remoteFavorite,
            progress: 'marked',
            updatedAt: DateTime(2026, 6),
          ),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await controller.loginAsmrAccount('alice', 'password');
      await controller.toggleFavorite(localFavorite);
      await controller.syncAsmrAccount(force: true);

      api.remoteReviewRecords
        ..clear()
        ..addAll(<AsmrReviewRecord>[
          AsmrReviewRecord(
            work: remoteFavorite,
            progress: 'marked',
            updatedAt: DateTime(2026, 7),
          ),
          AsmrReviewRecord(
            work: localFavorite,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ]);

      await controller.syncAsmrAccount(force: true);

      expect(controller.worksFor(AsmrCategoryType.favorites).first.id, 104);
    },
  );

  test('ASMR sync keeps local history when remote pull is stale', () async {
    await resetPrefs();
    final remoteHistory = <AsmrReviewRecord>[
      for (var index = 0; index < 60; index++)
        AsmrReviewRecord(
          work: _work(id: 200 + index, title: 'Remote History $index'),
          progress: 'listening',
          updatedAt: DateTime(2026, 7).subtract(Duration(minutes: index)),
        ),
    ];
    final localHistory = _work(id: 300, title: 'Fresh Local History');
    final api = _FakeAsmrApiService(remoteReviewRecords: remoteHistory);
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.loginAsmrAccount('alice', 'password');
    await controller.recordHistory(localHistory);
    await controller.syncAsmrAccount(force: true);

    api.remoteReviewRecords
      ..clear()
      ..addAll(remoteHistory);

    await controller.syncAsmrAccount(force: true);

    final historyIds = controller
        .worksFor(AsmrCategoryType.history)
        .map((work) => work.id)
        .toList(growable: false);
    expect(historyIds.first, 300);
    expect(historyIds, contains(300));
    expect(historyIds, hasLength(60));
  });

  test(
    'concurrent favorite and history mutations do not lose updates',
    () async {
      await resetPrefs();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      final favorite = _work(id: 401, title: 'Favorite');

      await Future.wait<void>(<Future<void>>[
        controller.toggleFavorite(favorite),
        controller.toggleFavorite(favorite),
      ]);
      expect(controller.worksFor(AsmrCategoryType.favorites), isEmpty);

      await Future.wait<void>(<Future<void>>[
        controller.recordHistory(_work(id: 402, title: 'First')),
        controller.recordHistory(_work(id: 403, title: 'Second')),
      ]);
      expect(
        controller.worksFor(AsmrCategoryType.history).map((work) => work.id),
        containsAll(<int>[402, 403]),
      );
    },
  );

  test(
    'logout waits for a favorite mutation and remains authoritative',
    () async {
      await resetPrefs();
      final blockingPreferences = _BlockingAsmrPreferencesStore(
        repository: TestPersistenceRepository(),
      );
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      final service = AsmrAccountSyncService(
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        apiService: api,
        preferencesStore: blockingPreferences,
      );
      await service.initialize();
      await service.login('alice', 'password');

      final favorite = _work(id: 404, title: 'Queued favorite');
      final favoriteFuture = service.toggleFavorite(favorite);
      await blockingPreferences.saveStarted.future;
      var logoutCompleted = false;
      final logoutFuture = service.logout().then((snapshot) {
        logoutCompleted = true;
        return snapshot;
      });
      await Future<void>.delayed(Duration.zero);

      expect(logoutCompleted, isFalse);
      blockingPreferences.releaseSave.complete();
      await favoriteFuture;
      final snapshot = await logoutFuture;

      expect(snapshot.session, isNull);
      expect(snapshot.favoriteIds, contains(favorite.id));
      expect(tokenStore.token, isNull);
    },
  );

  test(
    'auth epoch suppresses stale favorite completion and old-token sync',
    () async {
      await resetPrefs();
      final blockingPreferences = _BlockingAsmrPreferencesStore(
        repository: TestPersistenceRepository(),
      );
      final api = _FakeAsmrApiService();
      final controller = createTestAsmrController(
        preferencesStore: blockingPreferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        persistenceRepository: _FakeTestPersistenceRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
      await controller.loginAsmrAccount('alice', 'password');
      api.reviewPutTokens.clear();

      final favoriteFuture = controller.toggleFavorite(
        _work(id: 405, title: 'Stale favorite'),
      );
      await blockingPreferences.saveStarted.future;
      final logoutFuture = controller.logoutAsmrAccount();
      blockingPreferences.releaseSave.complete();
      await Future.wait<void>(<Future<void>>[favoriteFuture, logoutFuture]);
      await Future<void>.delayed(Duration.zero);

      expect(controller.isAsmrAccountLoggedIn, isFalse);
      expect(api.reviewPutTokens, isEmpty);
    },
  );

  test('a new account does not reuse an old account sync task', () async {
    await resetPrefs();
    final oldSyncStarted = Completer<void>();
    final releaseOldSync = Completer<void>();
    final api = _FakeAsmrApiService();
    api.onPutReviewWithToken = (workId, progress, token) async {
      if (token == 'token-alice') {
        if (!oldSyncStarted.isCompleted) oldSyncStarted.complete();
        await releaseOldSync.future;
      }
    };
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      persistenceRepository: _FakeTestPersistenceRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.loginAsmrAccount('alice', 'password');
    await controller.toggleFavorite(_work(id: 406, title: 'Account'));
    await oldSyncStarted.future;

    await controller.logoutAsmrAccount();
    await controller.loginAsmrAccount('bob', 'password');
    expect(api.reviewPutTokens, contains('token-bob'));
    expect(controller.asmrAccountName, 'bob');

    releaseOldSync.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.asmrAccountName, 'bob');
    expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
  });

  test('last sync write failure permits retry and logout', () async {
    await resetPrefs();
    final failingPreferences = _LastSyncFailurePreferences(
      repository: TestPersistenceRepository(),
    );
    final api = _FakeAsmrApiService();
    final controller = createTestAsmrController(
      preferencesStore: failingPreferences,
      persistenceRepository: _FakeTestPersistenceRepository(const []),
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
    );
    await controller.initialize();
    await controller.loginAsmrAccount('alice', 'password');
    failingPreferences.rejectWrite = true;
    await controller.syncAsmrAccount(force: true);
    expect(controller.syncViewState.phase, AsmrSyncPhase.failed);
    expect(controller.syncViewState.lastError, isA<FileSystemException>());
    failingPreferences.rejectWrite = false;
    await controller.syncAsmrAccount(force: true);
    expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
    failingPreferences.rejectWrite = true;
    await controller.syncAsmrAccount(force: true);
    await controller.logoutAsmrAccount();
    expect(controller.isAsmrAccountLoggedIn, isFalse);
    expect(controller.syncViewState.phase, AsmrSyncPhase.idle);
  });

  for (final failWrite in [false, true]) {
    test(
      'late sync write ${failWrite ? 'failure' : 'success'} cannot resume the old account sync',
      () async {
        await resetPrefs();
        final failingPreferences = _LastSyncFailurePreferences(
          repository: TestPersistenceRepository(),
        )..failBlockedWrite = failWrite;
        final api = _FakeAsmrApiService();
        final controller = createTestAsmrController(
          preferencesStore: failingPreferences,
          persistenceRepository: _FakeTestPersistenceRepository(const []),
          apiService: api,
          authService: AsmrAuthService(
            apiService: api,
            tokenStore: _MemoryAsmrTokenStore(),
          ),
        );
        await controller.initialize();
        await controller.loginAsmrAccount('alice', 'password');
        failingPreferences.blockWrite = true;
        final oldSync = controller.syncAsmrAccount(force: true);
        await failingPreferences.writeStarted.future;
        await controller.toggleFavorite(
          _work(id: 409, title: 'Account transition'),
        );
        await controller.logoutAsmrAccount();
        await controller.loginAsmrAccount('bob', 'password');
        final calls = api.calls.length;
        failingPreferences.releaseWrite.complete();
        await oldSync;
        expect(api.calls.length, calls);
        expect(api.reviewPutTokens, ['token-bob']);
        expect(controller.asmrAccountName, 'bob');
        expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
        expect(controller.syncViewState.lastError, isNull);
      },
    );
  }
}

class _LastSyncFailurePreferences extends AsmrPreferencesStore {
  _LastSyncFailurePreferences({required super.repository});
  bool rejectWrite = false;
  bool blockWrite = false;
  bool failBlockedWrite = true;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> saveLastSyncAt(DateTime value) async {
    if (blockWrite) {
      blockWrite = false;
      writeStarted.complete();
      await releaseWrite.future;
      if (failBlockedWrite) {
        throw const FileSystemException('late last sync write failure');
      }
    }
    if (rejectWrite) throw const FileSystemException('last sync write failure');
    await super.saveLastSyncAt(value);
  }
}
