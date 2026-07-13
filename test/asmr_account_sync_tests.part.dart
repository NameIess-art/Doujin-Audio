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
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    'ASMR account sync refreshes expired token with saved credentials',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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

  test(
    'ASMR initialize restores account without blocking category load',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final tokenStore = _MemoryAsmrTokenStore();
      await tokenStore.writeToken('cached-token');
      await tokenStore.writeCredentials('alice', 'password');
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(apiService: api, tokenStore: tokenStore),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      apiService: api,
      authService: AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      ),
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
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
}
