part of 'asmr_one_settings_test.dart';

void registerAsmrControllerStateTests({
  required Future<void> Function([Map<String, Object> values]) resetPrefs,
  required AsmrPreferencesStore Function() preferencesStore,
  required TestPersistenceRepository Function() persistenceRepository,
}) {
  late AsmrPreferencesStore preferences;
  setUp(() => preferences = preferencesStore());

  test(
    'catalog compute keeps failed saves atomic and rejects a reload during preparation',
    () async {
      await resetPrefs();
      final store = _CatalogFailingPreferencesStore(
        repository: persistenceRepository(),
      );
      final api = _VoiceCatalogApi()..fail = false;
      final controller = createTestAsmrController(
        preferencesStore: store,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      addTearDown(controller.dispose);
      await controller.ensureTagInterests();
      final before = controller.voiceActorInterests;
      store.failCatalogSave = true;
      await controller.ensureVoiceActorCatalog();
      expect(controller.voiceActorCatalogError, isStateError);
      expect(controller.voiceActorCatalogComplete, isFalse);
      expect(controller.allVoiceActors, isEmpty);
      expect(controller.voiceActorInterests, same(before));
      expect((await store.loadVoiceActorPreferences()).tags, isEmpty);
      store.failCatalogSave = false;
      api.pending = Completer<List<AsmrTag>>();
      final loading = controller.ensureVoiceActorCatalog(force: true);
      await api.started.future;
      api.pending!.complete([
        for (var i = 0; i < 20000; i++)
          AsmrTag(key: 'online:$i', name: 'Voice $i'),
      ]);
      await Future<void>.delayed(Duration.zero);
      await controller.reloadPersistedState();
      await loading;
      expect(controller.voiceActorCatalogComplete, isFalse);
      expect(controller.allVoiceActors, isEmpty);
      expect((await store.loadVoiceActorPreferences()).tags, isEmpty);
    },
  );

  test(
    'interest snapshots and provider emissions ignore unrelated controller changes',
    () async {
      await resetPrefs();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(),
      );
      addTearDown(controller.dispose);
      await controller.ensureTagInterests();
      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);
      final publications = <List<AsmrTagInterest>>[];
      container.listen(asmrTagInterestsProvider, (_, next) {
        final value = next.value;
        if (value != null) publications.add(value);
      });
      await Future<void>.delayed(Duration.zero);
      UiInteractionCoordinator.instance.flushPendingCommitsForTest();
      await Future<void>.delayed(Duration.zero);
      final tags = controller.interestTags;
      final voices = controller.voiceActorInterests;
      final circles = controller.circleInterests;
      final daily = controller.dailyRecommendations;
      final initialPublications = publications.length;
      expect(initialPublications, 1);
      await controller.setVisibleCategories([AsmrCategoryType.release]);
      UiInteractionCoordinator.instance.flushPendingCommitsForTest();
      await Future<void>.delayed(Duration.zero);
      expect(controller.interestTags, same(tags));
      expect(controller.voiceActorInterests, same(voices));
      expect(controller.circleInterests, same(circles));
      expect(controller.dailyRecommendations, same(daily));
      expect(publications, hasLength(initialPublications));
      expect(() => tags.clear(), throwsUnsupportedError);
      expect(() => daily.clear(), throwsUnsupportedError);
      await controller.recordTagListeningBatch(
        batchId: 'snapshot:1',
        contributions: [
          (tags: ['New tag'], duration: const Duration(minutes: 1)),
        ],
      );
      UiInteractionCoordinator.instance.flushPendingCommitsForTest();
      await Future<void>.delayed(Duration.zero);
      expect(controller.interestTags.single.tag.name, 'New tag');
      expect(controller.interestTags, isNot(same(tags)));
      expect(controller.voiceActorInterests, same(voices));
      expect(publications, hasLength(initialPublications + 1));
    },
  );
  test(
    'circle preferences derive real creator names and persist twenty ranks independently',
    () async {
      await resetPrefs();
      await preferences.saveFavoriteWorks([
        _work(id: 1, title: 'Favorite work', circleName: 'Favorite circle'),
      ]);
      await preferences.saveHistoryWorks([
        _work(id: 2, title: 'History work', circleName: 'History circle'),
      ]);
      final repository = _InterestTracksRepository(
        () async => [
          _track(
            groupTitle: 'A work title, not a circle',
            tags: [],
          ).copyWith(remoteMetadata: {'circleName': 'Local circle'}),
          _track(groupTitle: 'Another work title', tags: []).copyWith(
            remoteMetadata: {
              'circleName': ' ',
              'circle': {'name': ' Nested circle '},
            },
          ),
          _track(groupTitle: 'String creator metadata', tags: []).copyWith(
            remoteMetadata: {'circleName': '', 'circle': ' String circle '},
          ),
          _track(groupTitle: 'No creator metadata', tags: []),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      addTearDown(controller.dispose);
      await controller.ensureTagInterests();
      expect(controller.allCircles.map((tag) => tag.name), [
        'Favorite circle',
        'History circle',
        'Local circle',
        'Nested circle',
        'String circle',
      ]);
      expect(controller.circleInterests, isEmpty);
      await expectLater(
        controller.applyCircleSelections(
          changes: {'local:local circle': true, 'missing': true},
        ),
        throwsArgumentError,
      );
      expect(controller.manualInterestCircleKeys, isEmpty);
      await controller.recordCircleListeningBatch(
        batchId: 'creator:1',
        contributions: [
          for (var i = 0; i < 25; i++)
            (tags: ['Circle $i'], duration: Duration(minutes: i + 1)),
        ],
      );
      await controller.recordCircleListeningBatch(
        batchId: 'creator:1',
        contributions: [
          (tags: ['Circle 24'], duration: const Duration(minutes: 100)),
        ],
      );
      await controller.applyCircleSelections(
        changes: {'local:local circle': true},
      );
      await controller.recordVoiceActorListeningBatch(
        batchId: 'creator:1',
        contributions: [
          (tags: ['Independent voice'], duration: const Duration(minutes: 5)),
        ],
      );
      expect(controller.listenedCircleInterests, hasLength(20));
      expect(controller.circleInterests.first.tag.name, 'Circle 24');
      expect(controller.circleInterests.first.weight, 25);
      expect(controller.listenedVoiceActorInterests.single.weight, 5);
      await controller.reloadPersistedState();
      expect(controller.circleInterests, hasLength(20));
      expect(controller.circleInterests.first.weight, 25);
      expect(controller.manualInterestCircleKeys, {'local:local circle'});
      expect((await preferences.loadCirclePreferences()).limit, 20);
    },
  );

  test(
    'circle catalog merges local choices, retains cache on failure and rejects stale restores',
    () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      final key = state.resolve('Known circle');
      state.setInterested(key, true);
      state.excluded.add(key);
      state.learned[key] = 6;
      await preferences.saveCirclePreferences(state);
      final api = _CircleCatalogApi();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      addTearDown(controller.dispose);
      await controller.ensureCircleCatalog();
      expect(controller.circleCatalogComplete, isFalse);
      expect(controller.circleCatalogError, isStateError);
      expect(controller.manualInterestCircleKeys, {key});
      api.fail = false;
      await controller.ensureCircleCatalog(force: true);
      expect(controller.circleCatalogComplete, isTrue);
      expect(controller.manualInterestCircleKeys, {'online:circle-id'});
      expect(controller.excludedCircleKeys, {'online:circle-id'});
      expect(controller.listenedCircleInterests.single.weight, 6);
      final pending = Completer<List<AsmrTag>>();
      api.pending = pending;
      final stale = controller.ensureCircleCatalog(force: true);
      await api.started.future;
      expect(controller.isLoadingCircleCatalog, isTrue);
      await controller.reloadPersistedState();
      pending.complete([AsmrTag(key: 'online:stale', name: 'Stale')]);
      await stale;
      expect(controller.isLoadingCircleCatalog, isFalse);
      expect(
        controller.allCircles.map((tag) => tag.key),
        isNot(contains('online:stale')),
      );
      expect(
        (await preferences.loadCirclePreferences()).tags,
        isNot(contains('online:stale')),
      );
      expect(controller.excludedCircleKeys, {'online:circle-id'});
    },
  );

  for (final voice in [false, true]) {
    test(
      'creator exclusion filters categories and daily cache, restores raw works: voice=$voice',
      () async {
        await resetPrefs();
        final state = AsmrTagPreferences();
        state.mergeTag(
          AsmrTag(
            key: 'online:creator',
            name: 'Excluded creator',
            aliases: ['Excluded alias'],
          ),
        );
        if (voice) {
          await preferences.saveVoiceActorPreferences(state);
        } else {
          await preferences.saveCirclePreferences(state);
        }
        final blocked = AsmrWork.fromJson({
          ..._work(
            id: 100,
            title: 'Blocked',
            circleName: voice ? 'Allowed circle' : 'Excluded alias',
          ).toJson(),
          'voiceActors': voice ? ['Excluded alias'] : <String>[],
        });
        final allowed = _work(
          id: 101,
          title: 'Allowed',
          circleName: 'Allowed circle',
        );
        final day = DateTime(2026, 10, 25);
        await preferences.saveDailyRecommendations(
          language: AsmrContentLanguage.zh,
          date: '2026-10-25',
          works: [blocked, allowed],
        );
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          persistenceRepository: persistenceRepository(),
          apiService: _FakeAsmrApiService(
            recommendationWorks: [blocked, allowed],
          ),
        );
        addTearDown(controller.dispose);
        await controller.ensureCategoryLoaded(AsmrCategoryType.release);
        await controller.ensureDailyRecommendations(now: day);
        final original = controller.worksFor(AsmrCategoryType.release);
        Future<void> select(Map<String, bool> changes) => voice
            ? controller.applyVoiceActorSelections(
                excluded: true,
                changes: changes,
              )
            : controller.applyCircleSelections(
                excluded: true,
                changes: changes,
              );
        await expectLater(
          select({'online:creator': true, 'missing': true}),
          throwsArgumentError,
        );
        expect(
          voice
              ? controller.excludedVoiceActorKeys
              : controller.excludedCircleKeys,
          isEmpty,
        );
        await select({'online:creator': true});
        expect(
          controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
          [101],
        );
        expect(controller.dailyRecommendations.map((work) => work.id), [101]);
        await controller.reloadPersistedState();
        expect(
          voice
              ? controller.excludedVoiceActorKeys
              : controller.excludedCircleKeys,
          {'online:creator'},
        );
        await controller.ensureCategoryLoaded(AsmrCategoryType.release);
        expect(
          controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
          [101],
        );
        await select({'online:creator': false});
        expect(
          controller.worksFor(AsmrCategoryType.release).map((work) => work.id),
          original.map((work) => work.id),
        );
      },
    );
  }

  test(
    'circle selections refresh an already loaded recommendation page',
    () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      state.resolve('First circle');
      state.resolve('Second circle');
      await preferences.saveCirclePreferences(state);
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(
          recommendationWorks: [
            _work(id: 100, title: 'First', circleName: 'First circle'),
            _work(id: 101, title: 'Second', circleName: 'Second circle'),
          ],
        ),
      );
      addTearDown(controller.dispose);
      await controller.ensureCategoryLoaded(AsmrCategoryType.recommendation);
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.id,
        100,
      );
      await controller.applyCircleSelections(
        changes: {'local:second circle': true},
      );
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.id,
        101,
      );
    },
  );

  test(
    'complete interest catalogs retain alphabetical pickers',
    () async {
      await resetPrefs();
      final tags = AsmrTagPreferences();
      for (final tag in [
        AsmrTag(key: 'online:a', name: 'A'),
        AsmrTag(key: 'local:private', name: 'Local only'),
        AsmrTag(key: 'online:b', name: 'B'),
        AsmrTag(key: 'online:c', name: 'C'),
        AsmrTag(key: 'online:d', name: 'D'),
        AsmrTag(key: 'online:z', name: 'Z'),
      ]) {
        tags.mergeTag(tag);
      }
      await preferences.saveTagPreferences(tags);
      await preferences.saveVoiceActorPreferences(tags);
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(),
      );
      await controller.initializeForVisiblePage();
      expect(controller.allTags.map((tag) => tag.name), [
        'A',
        'B',
        'C',
        'D',
        'Local only',
        'Z',
      ]);
      expect(controller.allVoiceActors.map((tag) => tag.name), [
        'A',
        'B',
        'C',
        'D',
        'Local only',
        'Z',
      ]);
    },
  );

  test(
    'voice interests persist twenty listening ranks and unlimited manual choices independently',
    () async {
      await resetPrefs();
      final repository = _InterestTracksRepository(
        () async => [
          _track(groupTitle: 'Known voices', tags: ['sleep']).copyWith(
            remoteMetadata: {
              'voiceActors': [for (var i = 0; i < 25; i++) 'Voice $i'],
            },
          ),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      await controller.ensureTagInterests();
      expect(controller.allVoiceActors, hasLength(25));
      expect(controller.voiceActorInterests, isEmpty);
      await expectLater(
        controller.applyVoiceActorSelections(
          changes: {'local:voice 0': true, 'missing': true},
        ),
        throwsArgumentError,
      );
      expect(controller.manualInterestVoiceActorKeys, isEmpty);
      await controller.applyVoiceActorSelections(
        changes: {for (var i = 0; i < 25; i++) 'local:voice $i': true},
      );
      expect(controller.manualInterestVoiceActorKeys, hasLength(25));
      expect(controller.voiceActorInterests, isEmpty);
      final contributions = [
        for (var i = 0; i < 25; i++)
          (tags: ['Voice $i'], duration: Duration(minutes: i + 1)),
      ];
      await controller.recordVoiceActorListeningBatch(
        batchId: 'voice:1',
        contributions: contributions,
      );
      await controller.recordVoiceActorListeningBatch(
        batchId: 'voice:1',
        contributions: contributions,
      );
      await controller.recordTagListeningBatch(
        batchId: 'voice:1',
        contributions: [
          (tags: ['sleep'], duration: const Duration(minutes: 5)),
        ],
      );
      expect(controller.listenedVoiceActorInterests, hasLength(20));
      expect(controller.voiceActorInterests.first.tag.name, 'Voice 24');
      expect(controller.voiceActorInterests.first.weight, 25);
      expect(controller.interestTags.single.weight, 5);
      await controller.reloadPersistedState();
      expect(controller.voiceActorInterests.first.weight, 25);
      expect(controller.manualInterestVoiceActorKeys, hasLength(25));
      expect((await preferences.loadVoiceActorPreferences()).limit, 20);
    },
  );

  test(
    'saved ten-slot voice preferences load twenty without losing state',
    () async {
      await resetPrefs();
      final voices = AsmrTagPreferences(limit: 10);
      for (var i = 0; i < 25; i++) {
        final key = voices.resolve('Voice $i');
        voices.setInterested(key, true);
        voices.learned[key] = i + 1;
      }
      voices.consumedSequences['voice'] = 7;
      voices.catalogComplete = true;
      await preferences.saveVoiceActorPreferences(voices);
      final restored = await preferences.loadVoiceActorPreferences();
      expect(restored.limit, 20);
      expect(restored.interests, hasLength(20));
      expect(restored.interests.first.tag.name, 'Voice 24');
      expect(restored.manualInterests, voices.manualInterests);
      expect(restored.learned, voices.learned);
      expect(restored.consumedSequences, voices.consumedSequences);
      expect(restored.catalogComplete, isTrue);
    },
  );

  test(
    'voice catalog retains cached choices on failure and discards stale restore requests',
    () async {
      await resetPrefs();
      final api = _VoiceCatalogApi();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.ensureVoiceActorCatalog();
      expect(controller.voiceActorCatalogComplete, isFalse);
      expect(controller.voiceActorCatalogError, isStateError);
      api.fail = false;
      await controller.ensureVoiceActorCatalog(force: true);
      expect(controller.voiceActorCatalogComplete, isTrue);
      await controller.applyVoiceActorSelections(
        changes: {'online:voice-id': true},
      );
      final pending = Completer<List<AsmrTag>>();
      api.pending = pending;
      final stale = controller.ensureVoiceActorCatalog(force: true);
      await api.started.future;
      await controller.reloadPersistedState();
      pending.complete([AsmrTag(key: 'online:stale', name: 'Stale')]);
      await stale;
      expect(
        controller.allVoiceActors.map((e) => e.key),
        isNot(contains('online:stale')),
      );
      expect(
        controller.manualInterestVoiceActorKeys,
        contains('online:voice-id'),
      );
      expect(
        (await preferences.loadVoiceActorPreferences()).tags,
        isNot(contains('online:stale')),
      );
    },
  );

  test(
    'daily discovery upgrades old cache with creator interests and restores it',
    () async {
      await resetPrefs();
      final repository = persistenceRepository();
      final state = AsmrTagPreferences();
      state.learned[state.resolve('listened')] = 60;
      state.setInterested(state.resolve('manual'), true);
      await preferences.saveCirclePreferences(state);
      await preferences.saveDailyRecommendations(
        language: AsmrContentLanguage.zh,
        date: '2026-10-24',
        works: [_work(id: 9000, title: 'Old daily pick')],
      );
      const cacheKey = 'asmr_daily_discovery_v1_zh';
      final oldCache = (await repository.loadSetting(
        cacheKey,
      ))!.replaceFirst('"version":3,', '"version":2,');
      await repository.saveSetting(cacheKey, oldCache);
      final api = _FakeAsmrApiService(
        pagedSearchWorks: true,
        recommendationWorks: List.generate(
          100,
          (i) => _work(
            id: 5000 + i,
            title: 'Daily $i',
            circleName: i < 20
                ? 'listened'
                : i < 40
                ? 'manual'
                : 'Other $i',
          ),
        ),
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: api,
      );
      addTearDown(controller.dispose);
      final day = DateTime(2026, 10, 24);
      await controller.ensureDailyRecommendations(now: day);
      final picks = controller.dailyRecommendations;
      expect(picks, hasLength(20));
      expect(
        picks.where(
          (w) => w.circleName == 'listened' || w.circleName == 'manual',
        ),
        hasLength(20),
      );
      expect(picks.any((w) => w.circleName == 'listened'), isTrue);
      expect(picks.any((w) => w.circleName == 'manual'), isTrue);
      expect(
        (await preferences.loadDailyRecommendations(
          AsmrContentLanguage.zh,
        ))!.version,
        AsmrPreferencesStore.dailyRecommendationsVersion,
      );
      final requests = api.searchWorkRequests.length;
      expect(requests, greaterThan(0));
      expect(api.searchKeywords.toSet(), {'listened', 'manual'});
      expect(api.fetchWorkRequests, isEmpty);
      final restored = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: api,
      );
      addTearDown(restored.dispose);
      await restored.ensureDailyRecommendations(now: day);
      expect(
        restored.dailyRecommendations.map((w) => w.workKey),
        picks.map((w) => w.workKey),
      );
      expect(api.searchWorkRequests.length, requests);
    },
  );

  test(
    'daily discovery searches creators, samples older pages and refreshes changed interests',
    () async {
      await resetPrefs();
      final voices = AsmrTagPreferences();
      voices.setInterested(voices.resolve('Voice A'), true);
      final circles = AsmrTagPreferences();
      circles.setInterested(circles.resolve('Circle B'), true);
      circles.resolve('Circle C');
      await preferences.saveVoiceActorPreferences(voices);
      await preferences.saveCirclePreferences(circles);
      final api = _DailyCreatorApi();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      addTearDown(controller.dispose);
      final day = DateTime(2026, 10, 25);
      await controller.ensureDailyRecommendations(now: day);
      expect(api.requests.toSet(), {
        'voice a:1',
        'voice a:10',
        'circle b:1',
        'circle b:10',
      });
      expect(api.fetchWorkRequests, isEmpty);
      expect(controller.dailyRecommendations.map((w) => w.id).take(2), [1, 2]);
      expect(controller.dailyRecommendations, hasLength(4));
      expect(controller.dailyRecommendations.any((w) => w.id == 999), isFalse);
      final count = api.requests.length;
      await controller.ensureDailyRecommendations(now: day);
      expect(api.requests, hasLength(count));
      await controller.applyVoiceActorSelections(
        changes: {'local:voice a': false},
      );
      expect(
        controller.dailyRecommendations.every(
          (w) => w.circleName == 'Circle B',
        ),
        isTrue,
      );
      await controller.applyCircleSelections(
        changes: {'local:circle b': false, 'local:circle c': true},
      );
      expect(api.requests, containsAll(['circle c:1', 'circle c:10']));
      expect(
        controller.dailyRecommendations.every(
          (w) => w.circleName == 'Circle C',
        ),
        isTrue,
      );
      expect(controller.dailyRecommendations, hasLength(2));
      final restored = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      addTearDown(restored.dispose);
      final savedCount = api.requests.length;
      await restored.ensureDailyRecommendations(now: day);
      expect(api.requests, hasLength(savedCount));
      expect(
        restored.dailyRecommendations.map((w) => w.id),
        controller.dailyRecommendations.map((w) => w.id),
      );
    },
  );

  test(
    'daily discovery replaces a pending request when listening adds a creator',
    () async {
      await resetPrefs();
      final circles = AsmrTagPreferences();
      circles.setInterested(circles.resolve('Circle B'), true);
      await preferences.saveCirclePreferences(circles);
      final started = Completer<void>();
      final gate = Completer<void>();
      final api = _DailyCreatorApi(
        beforeFetchSearchResponse: (_) async {
          if (!started.isCompleted) started.complete();
          await gate.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      final day = DateTime(2026, 10, 25);
      final previous = controller.ensureDailyRecommendations(now: day);
      await started.future;
      await controller.recordVoiceActorListeningBatch(
        batchId: 'daily:1',
        contributions: [
          (tags: ['Voice A'], duration: const Duration(minutes: 1)),
        ],
      );
      gate.complete();
      await previous;
      await controller.ensureDailyRecommendations(now: day);
      expect(
        controller.dailyRecommendations.any(
          (w) => w.voiceActors.contains('Voice A'),
        ),
        isTrue,
      );
      expect(controller.dailyRecommendations, hasLength(4));
      final requests = api.requests.length;
      await controller.recordVoiceActorListeningBatch(
        batchId: 'daily:2',
        contributions: [
          (tags: ['Voice A'], duration: const Duration(minutes: 1)),
        ],
      );
      await controller.ensureDailyRecommendations(now: day);
      expect(api.requests, hasLength(requests));
    },
  );

  test(
    'daily discovery failed save is retryable and language/day races cannot overwrite cache',
    () async {
      await resetPrefs();
      final repository = persistenceRepository();
      final store = _DailyFailingPreferencesStore(repository: repository);
      var gate = Completer<void>()..complete();
      var started = Completer<void>();
      final api = _FakeAsmrApiService(
        recommendationWorks: List.generate(
          60,
          (i) => _work(id: 4000 + i, title: 'Daily $i'),
        ),
        beforeFetchWorkResponse: (_) {
          if (!started.isCompleted) started.complete();
          return gate.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: store,
        persistenceRepository: repository,
        apiService: api,
      );
      final day = DateTime(2026, 10, 24);
      await controller.ensureDailyRecommendations(now: day);
      expect(controller.dailyRecommendationsError, isNotNull);
      expect(controller.dailyRecommendationsDate, isNull);
      expect(
        await store.loadDailyRecommendations(AsmrContentLanguage.zh),
        isNull,
      );
      store.failDailySave = false;
      await controller.ensureDailyRecommendations(now: day);
      expect(controller.dailyRecommendationsDate, '2026-10-24');
      gate = Completer<void>();
      started = Completer<void>();
      final old = controller.ensureDailyRecommendations(
        now: DateTime(2026, 10, 25),
      );
      await started.future;
      final rollover = controller.ensureDailyRecommendations(
        now: DateTime(2026, 10, 26),
      );
      await controller.setContentLanguage(AsmrContentLanguage.ja);
      final japanese = controller.ensureDailyRecommendations(
        now: DateTime(2026, 10, 26),
      );
      gate.complete();
      await Future.wait([old, rollover, japanese]);
      expect(controller.dailyRecommendationsDate, '2026-10-26');
      expect(
        (await store.loadDailyRecommendations(AsmrContentLanguage.zh))!.date,
        '2026-10-24',
      );
      expect(
        (await store.loadDailyRecommendations(AsmrContentLanguage.ja))!.date,
        '2026-10-26',
      );
    },
  );

  test(
    'daily discovery persists a stable twenty, rolls over, and refills exclusions',
    () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      state.resolve('blocked');
      await preferences.saveTagPreferences(state);
      final api = _FakeAsmrApiService(
        recommendationWorks: List.generate(
          80,
          (i) => _work(
            id: 1000 + i,
            title: 'Daily $i',
            tags: [i.isEven ? 'blocked' : 'other'],
          ),
        ),
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      final day = DateTime(2026, 10, 24);
      final pending = controller.ensureDailyRecommendations(now: day);
      expect(controller.ensureDailyRecommendations(now: day), same(pending));
      await pending;
      expect(controller.dailyRecommendations, hasLength(20));
      final first = controller.dailyRecommendations
          .map((w) => w.workKey)
          .toList();
      final requests = api.fetchWorkRequests.length;
      expect(
        api.fetchWorkOrders.toSet(),
        containsAll([
          'create_date:desc',
          'dl_count:desc',
          'rate_average_2dp:desc',
          'release:desc',
        ]),
      );
      await controller.ensureDailyRecommendations(now: day);
      expect(api.fetchWorkRequests.length, requests);
      final restored = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await restored.ensureDailyRecommendations(now: day);
      expect(restored.dailyRecommendations.map((w) => w.workKey), first);
      expect(api.fetchWorkRequests.length, requests);
      await restored.setTagExcluded('local:blocked', true);
      expect(restored.dailyRecommendations, hasLength(20));
      expect(
        restored.dailyRecommendations.every((w) => !w.tags.contains('blocked')),
        isTrue,
      );
      expect(api.fetchWorkRequests.length, requests);
      await controller.ensureDailyRecommendations(now: DateTime(2026, 10, 25));
      expect(controller.dailyRecommendationsDate, '2026-10-25');
      expect(
        controller.dailyRecommendations.map((w) => w.workKey),
        isNot(first),
      );
      expect(api.fetchWorkRequests.length, greaterThan(requests));
    },
  );

  test(
    'daily discovery offline keeps last picks and can retry without saving a fresh date',
    () async {
      await resetPrefs();
      final yesterday = List.generate(
        20,
        (i) => _work(id: 2000 + i, title: 'Yesterday $i'),
      );
      await preferences.saveDailyRecommendations(
        language: AsmrContentLanguage.zh,
        date: '2026-10-23',
        works: yesterday,
      );
      final api = _FakeAsmrApiService(
        failingFetchOrders: {
          'create_date',
          'dl_count',
          'rate_average_2dp',
          'release',
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.ensureDailyRecommendations(now: DateTime(2026, 10, 24));
      expect(controller.dailyRecommendations, hasLength(20));
      expect(controller.dailyRecommendationsDate, '2026-10-23');
      expect(controller.dailyRecommendationsError, isNotNull);
      expect(controller.isLoadingDailyRecommendations, isFalse);
      expect(
        (await preferences.loadDailyRecommendations(
          AsmrContentLanguage.zh,
        ))!.date,
        '2026-10-23',
      );
      api.failingFetchOrders.clear();
      await controller.ensureDailyRecommendations(now: DateTime(2026, 10, 24));
      expect(controller.dailyRecommendationsDate, '2026-10-24');
      expect(controller.dailyRecommendationsError, isNull);
    },
  );

  test(
    'daily discovery late requests obey current exclusions and restore boundaries',
    () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      state.resolve('blocked');
      await preferences.saveTagPreferences(state);
      var gate = Completer<void>();
      var started = Completer<void>();
      final api = _FakeAsmrApiService(
        recommendationWorks: List.generate(
          60,
          (i) => _work(
            id: 3000 + i,
            title: 'Race $i',
            tags: [i.isEven ? 'blocked' : 'other'],
          ),
        ),
        beforeFetchWorkResponse: (_) {
          if (!started.isCompleted) started.complete();
          return gate.future;
        },
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      final first = controller.ensureDailyRecommendations(
        now: DateTime(2026, 10, 24),
      );
      await started.future;
      await controller.setTagExcluded('local:blocked', true);
      gate.complete();
      await first;
      expect(controller.dailyRecommendations, hasLength(20));
      expect(
        controller.dailyRecommendations.every(
          (w) => !w.tags.contains('blocked'),
        ),
        isTrue,
      );
      gate = Completer<void>();
      started = Completer<void>();
      final late = controller.ensureDailyRecommendations(
        now: DateTime(2026, 10, 25),
      );
      await started.future;
      await controller.reloadPersistedState();
      gate.complete();
      await late;
      expect(controller.dailyRecommendations, isEmpty);
      expect(
        (await preferences.loadDailyRecommendations(
          AsmrContentLanguage.zh,
        ))!.date,
        '2026-10-24',
      );
      await controller.ensureDailyRecommendations(now: DateTime(2026, 10, 24));
      expect(controller.dailyRecommendations, hasLength(20));
    },
  );

  test(
    'interest provider loads known tags without inventing listening or selections',
    () async {
      await resetPrefs();
      final repository = _InterestTracksRepository(
        () async => [
          _track(groupTitle: 'Local', tags: ['sleep']),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      final ready = Completer<void>();
      controller.addListener(() {
        if (controller.allTags.isNotEmpty && !ready.isCompleted) {
          ready.complete();
        }
      });
      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);
      final published = Completer<List<AsmrTagInterest>>();
      container.listen(asmrTagInterestsProvider, (_, next) {
        final interests = next.asData?.value;
        if (interests != null && !published.isCompleted) {
          published.complete(interests);
        }
      }, fireImmediately: true);
      await ready.future.timeout(const Duration(seconds: 5));
      UiInteractionCoordinator.instance.flushPendingCommitsForTest();
      final interests = await published.future.timeout(
        const Duration(seconds: 5),
      );
      expect(interests, isEmpty);
      expect(controller.manualInterestTagKeys, isEmpty);
      expect(controller.allTags.map((tag) => tag.key), contains('local:sleep'));
      expect(repository.reads, 1);
    },
  );

  test(
    'cancelled recommendation does not seed from pending local tracks',
    () async {
      await resetPrefs();
      final local = Completer<List<MusicTrack>>();
      final started = Completer<void>();
      final repository = _InterestTracksRepository(() {
        started.complete();
        return local.future;
      });
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      controller.beginSearchSession();
      final task = controller.ensureCategoryLoaded(
        AsmrCategoryType.recommendation,
        searchQuery: 'old',
        searchSession: true,
      );
      await started.future;
      controller.endSearchSession();
      await task.timeout(const Duration(seconds: 1));
      local.complete([
        _track(groupTitle: 'Old', tags: ['old']),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect((await preferences.loadTagPreferences()).tags, isEmpty);
    },
  );

  test(
    'visible initialization and release page do not read local interests',
    () async {
      await resetPrefs();
      final repository = _InterestTracksRepository(
        () async => throw StateError('unused'),
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      await controller.initializeForVisiblePage();
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      expect(repository.reads, 0);
      expect((await preferences.loadTagPreferences()).tags, isEmpty);
    },
  );

  test(
    'recommendations reuse local tracks and failed reads leave interests retryable',
    () async {
      await resetPrefs();
      var fail = true;
      final repository = _InterestTracksRepository(() async {
        if (fail) throw StateError('local library unavailable');
        return [
          _track(groupTitle: 'Local', tags: ['sleep']),
        ];
      });
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.recommendation);
      expect(repository.reads, 1);
      expect((await preferences.loadTagPreferences()).tags, isEmpty);
      fail = false;
      await controller.reloadPersistedState();
      await controller.ensureCategoryLoaded(AsmrCategoryType.recommendation);
      expect(repository.reads, 2);
      expect((await preferences.loadTagPreferences()).tags, isNotEmpty);
      expect(controller.allTags.map((tag) => tag.key), contains('local:sleep'));
      await controller.ensureTagInterests();
      expect(repository.reads, 2);
    },
  );

  test(
    'failed interest initialization can retry and shares concurrent requests',
    () async {
      await resetPrefs();
      var fail = true;
      final repository = _InterestTracksRepository(() async {
        if (fail) throw StateError('read failed');
        return [
          _track(groupTitle: 'Local', tags: ['sleep']),
        ];
      });
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      await expectLater(controller.ensureTagInterests(), throwsStateError);
      expect((await preferences.loadTagPreferences()).tags, isEmpty);
      fail = false;
      await Future.wait([
        controller.ensureTagInterests(),
        controller.ensureTagInterests(),
      ]);
      expect(repository.reads, 2);
      expect(controller.allTags.map((tag) => tag.key), contains('local:sleep'));
    },
  );

  test(
    'reload discards pending interest input and reads the new library',
    () async {
      await resetPrefs();
      final oldRead = Completer<List<MusicTrack>>();
      final started = Completer<void>();
      var first = true;
      final repository = _InterestTracksRepository(() {
        if (first) {
          first = false;
          started.complete();
          return oldRead.future;
        }
        return Future.value([
          _track(groupTitle: 'New', tags: ['new']),
        ]);
      });
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: repository,
        apiService: _FakeAsmrApiService(),
      );
      final oldTask = controller.ensureTagInterests();
      await started.future;
      await controller.reloadPersistedState();
      await controller.ensureTagInterests();
      oldRead.complete([
        _track(groupTitle: 'Old', tags: ['old']),
      ]);
      await oldTask;
      final saved = await preferences.loadTagPreferences();
      expect(repository.reads, 2);
      expect(saved.tags.keys, contains('local:new'));
      expect(saved.tags.keys, isNot(contains('local:old')));
    },
  );

  test(
    'tag exclusion caches visible lists and restores raw cached works',
    () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      state.resolve('sleep');
      await preferences.saveTagPreferences(state);
      final api = _FakeAsmrApiService(
        recommendationWorks: [
          _work(id: 100, title: 'Sleep', tags: ['sleep']),
          _work(id: 101, title: 'Other', tags: ['other']),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      final original = controller.worksFor(AsmrCategoryType.release);
      expect(controller.worksFor(AsmrCategoryType.release), same(original));
      await controller.setTagExcluded('local:sleep', true);
      final filtered = controller.worksFor(AsmrCategoryType.release);
      expect(filtered.map((work) => work.id), [101]);
      expect(controller.worksFor(AsmrCategoryType.release), same(filtered));
      await controller.setTagExcluded('local:sleep', false);
      expect(controller.worksFor(AsmrCategoryType.release), same(original));
    },
  );

  for (final excluded in [false, true]) {
    test('tag editor commits a batch atomically: excluded=$excluded', () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      final first = state.resolve('first');
      final second = state.resolve('second');
      await preferences.saveTagPreferences(state);
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: _FakeAsmrApiService(),
      );
      await controller.ensureTagInterests();
      await expectLater(
        controller.applyTagSelections(
          excluded: excluded,
          changes: {first: true, 'missing': true},
        ),
        throwsArgumentError,
      );
      expect(controller.interestTags, isEmpty);
      expect(controller.excludedTagKeys, isEmpty);
      final failed = await preferences.loadTagPreferences();
      expect(failed.manualInterests, isEmpty);
      expect(failed.excluded, isEmpty);
      await controller.applyTagSelections(
        excluded: excluded,
        changes: {first: true, second: true},
      );
      final saved = await preferences.loadTagPreferences();
      expect(
        excluded ? saved.excluded : saved.manualInterests,
        unorderedEquals([first, second]),
      );
      expect(saved.interests, isEmpty);
    });
  }

  test(
    'adding interest updates already loaded recommendation ordering',
    () async {
      await resetPrefs();
      final state = AsmrTagPreferences();
      state.resolve('first');
      state.resolve('second');
      await preferences.saveTagPreferences(state);
      final api = _FakeAsmrApiService(
        recommendationWorks: [
          _work(id: 100, title: 'First', tags: ['first']),
          _work(id: 101, title: 'Second', tags: ['second']),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.recommendation);
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.id,
        100,
      );
      await controller.setTagInterested('local:second', true);
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.id,
        101,
      );
    },
  );

  test(
    'voice selections refresh an already loaded recommendation page',
    () async {
      await resetPrefs();
      final voices = AsmrTagPreferences(limit: 10);
      voices.resolve('First voice');
      voices.resolve('Second voice');
      await preferences.saveVoiceActorPreferences(voices);
      final api = _FakeAsmrApiService(
        recommendationWorks: [
          AsmrWork.fromJson({
            ..._work(id: 100, title: 'First').toJson(),
            'voiceActors': const ['First voice'],
          }),
          AsmrWork.fromJson({
            ..._work(id: 101, title: 'Second').toJson(),
            'voiceActors': const ['Second voice'],
          }),
        ],
      );
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      await controller.ensureCategoryLoaded(AsmrCategoryType.recommendation);
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.id,
        100,
      );
      await controller.applyVoiceActorSelections(
        changes: {'local:second voice': true},
      );
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.id,
        101,
      );
    },
  );

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
        await controller.ensureCategoryLoaded(
          AsmrCategoryType.favorites,
          searchQuery: 'even',
        );
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
        await controller.ensureCategoryLoaded(
          AsmrCategoryType.favorites,
          searchQuery: 'EVEN',
        );
        expect(
          controller
              .filteredWorksFor(AsmrCategoryType.favorites, searchQuery: 'EVEN')
              .map((work) => work.id),
          filtered.map((work) => work.id),
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
    'local search reads snapshots and prepares normalized fields off the UI isolate',
    () async {
      await resetPrefs();
      final first = _CountingSearchWork(1);
      final second = _CountingSearchWork(2);
      var works = <AsmrWork>[first, second];
      final services = createTestAsmrServices(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
      );
      const context = (
        authEpoch: 0,
        token: null,
        contentEpoch: 0,
        language: AsmrContentLanguage.en,
        scope: 'local-search-test',
      );
      final catalog = AsmrCategoryCatalog(
        remoteCatalogService: services.remoteCatalogService,
        onChanged: () {},
        isContextCurrent: (_) => true,
        currentContext: () => context,
        localWorks: (_) => works,
        favoriteIds: () => const <String>{},
      );
      List<AsmrWork> filter(String query) => catalog.filteredWorksFor(
        AsmrCategoryType.favorites,
        searchQuery: query,
        searchSession: true,
      );
      Future<void> search(String query) async {
        catalog.setSearchQuery(query, AsmrCategoryType.favorites);
        await catalog.refresh(
          AsmrCategoryType.favorites,
          searchQuery: query,
          searchSession: true,
          context: context,
        );
      }

      expect(filter('Sleep Induction'), isEmpty);
      expect(
        catalog
            .viewState(
              AsmrCategoryType.favorites,
              searchQuery: 'Sleep Induction',
              searchSession: true,
            )
            .hasAttemptedLoad,
        isFalse,
      );
      expect([first.titleReads, second.titleReads], [0, 0]);
      await search('Sleep Induction');
      final initial = filter('Sleep Induction');
      expect(initial.map((work) => work.id), [1, 2]);
      for (final query in ['CIRCLE demo', 'Gentle Sound', 'VOICE Actor']) {
        await search(query);
        expect(filter(query).map((work) => work.id), [1, 2]);
      }
      await search('RJ0001');
      expect(filter('RJ0001').map((work) => work.id), [1]);
      await search('sleep circle');
      expect(filter('sleep circle'), isEmpty);
      await search('Sleep Induction, CIRCLE demo, VOICE Actor');
      expect(
        filter(
          'Sleep Induction, CIRCLE demo, VOICE Actor',
        ).map((work) => work.id),
        [1, 2],
      );
      await search('Sleep Induction, RJ0001');
      expect(filter('Sleep Induction, RJ0001').map((work) => work.id), [1]);
      await search('Sleep Induction, Missing');
      expect(filter('Sleep Induction, Missing'), isEmpty);
      expect([first.titleReads, second.titleReads], [0, 0]);
      catalog.clearSearchQueries();
      expect(filter('Sleep Induction'), isEmpty);
      expect([first.titleReads, second.titleReads], [0, 0]);

      works = [second];
      await search('Sleep Induction');
      expect(filter('Sleep Induction').map((work) => work.id), [2]);
      expect([first.titleReads, second.titleReads], [0, 0]);
      works = [
        _work(id: 2, title: 'Changed metadata', tags: ['New tag']),
      ];
      expect(filter('Sleep Induction'), isEmpty);
      catalog.bumpRevision(AsmrCategoryType.favorites);
      await Future<void>.delayed(Duration.zero);
      await catalog.pendingRefresh(
        AsmrCategoryType.favorites,
        searchQuery: 'Sleep Induction',
        searchSession: true,
      );
      expect(filter('Sleep Induction'), isEmpty);
      expect(
        catalog
            .viewState(
              AsmrCategoryType.favorites,
              searchQuery: 'Sleep Induction',
              searchSession: true,
            )
            .hasAttemptedLoad,
        isTrue,
      );
      await search('New tag');
      expect(filter('New tag').map((work) => work.id), [2]);
      works = [];
      catalog.bumpRevision(AsmrCategoryType.favorites);
      expect(filter('New tag'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      await catalog.pendingRefresh(
        AsmrCategoryType.favorites,
        searchQuery: 'New tag',
        searchSession: true,
      );
      expect(filter('New tag'), isEmpty);
    },
  );

  test(
    'local search replaces pending preparation after its source changes',
    () async {
      await resetPrefs();
      final services = createTestAsmrServices(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
      );
      const context = (
        authEpoch: 0,
        token: null,
        contentEpoch: 0,
        language: AsmrContentLanguage.en,
        scope: 'local-source-swap',
      );
      var works = [_work(id: 1, title: 'Sleep old')];
      final catalog = AsmrCategoryCatalog(
        remoteCatalogService: services.remoteCatalogService,
        onChanged: () {},
        isContextCurrent: (_) => true,
        currentContext: () => context,
        localWorks: (_) => works,
        favoriteIds: () => const <String>{},
      );
      catalog.setSearchQuery('sleep', AsmrCategoryType.favorites);
      Future<void>? pending() => catalog.pendingRefresh(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
        searchSession: true,
      );
      final first = catalog.refresh(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
        searchSession: true,
        context: context,
      );
      final original = pending();
      expect(original, isNotNull);
      // Replace the source synchronously, before the worker can return its result.
      works = [_work(id: 2, title: 'Sleep new')];
      catalog.refreshLocalSearch();
      await Future<void>.value();
      final replacement = pending();
      expect(replacement, isNotNull);
      expect(replacement, isNot(same(original)));
      await Future.wait([first, replacement!]);
      final state = catalog.viewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
        searchSession: true,
      );
      expect(state.works.map((work) => work.id), [2]);
      expect(state.isLoading, isFalse);
      expect(state.hasAttemptedLoad, isTrue);
      expect(state.lastError, isNull);
    },
  );

  test(
    'local history search reports preparation errors and can retry',
    () async {
      await resetPrefs();
      final services = createTestAsmrServices(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
      );
      const context = (
        authEpoch: 0,
        token: null,
        contentEpoch: 0,
        language: AsmrContentLanguage.en,
        scope: 'local-error',
      );
      var works = <AsmrWork>[_FailingSearchWork()];
      final catalog = AsmrCategoryCatalog(
        remoteCatalogService: services.remoteCatalogService,
        onChanged: () {},
        isContextCurrent: (_) => true,
        currentContext: () => context,
        localWorks: (_) => works,
        favoriteIds: () => const <String>{},
      );
      Future<void> refresh() => catalog.refresh(
        AsmrCategoryType.history,
        searchQuery: 'sleep',
        context: context,
      );
      await refresh();
      final failed = catalog.viewState(
        AsmrCategoryType.history,
        searchQuery: 'sleep',
      );
      expect(failed.lastError, isA<StateError>());
      expect(failed.isLoading, isFalse);
      expect(failed.hasAttemptedLoad, isTrue);
      works = [_work(id: 1, title: 'Sleep')];
      await refresh();
      final retried = catalog.viewState(
        AsmrCategoryType.history,
        searchQuery: 'sleep',
      );
      expect(retried.lastError, isNull);
      expect(retried.works.map((work) => work.id), [1]);
    },
  );

  test('local search rejects superseded queries and content epochs', () async {
    await resetPrefs();
    final services = createTestAsmrServices(
      preferencesStore: preferences,
      persistenceRepository: persistenceRepository(),
    );
    var context = (
      authEpoch: 0,
      token: null as String?,
      contentEpoch: 0,
      language: AsmrContentLanguage.en,
      scope: 'local-cancellation',
    );
    final works = [_work(id: 1, title: 'old'), _work(id: 2, title: 'new')];
    final catalog = AsmrCategoryCatalog(
      remoteCatalogService: services.remoteCatalogService,
      onChanged: () {},
      isContextCurrent: (request) => request == context,
      currentContext: () => context,
      localWorks: (_) => works,
      favoriteIds: () => const <String>{},
    );
    Future<void> search(String query) {
      catalog.setSearchQuery(query, AsmrCategoryType.favorites);
      return catalog.refresh(
        AsmrCategoryType.favorites,
        searchQuery: query,
        searchSession: true,
        context: context,
      );
    }

    final old = search('old');
    final newest = search('new');
    await Future.wait([old, newest]);
    expect(
      catalog
          .viewState(
            AsmrCategoryType.favorites,
            searchQuery: 'old',
            searchSession: true,
          )
          .works,
      isEmpty,
    );
    expect(
      catalog
          .viewState(
            AsmrCategoryType.favorites,
            searchQuery: 'new',
            searchSession: true,
          )
          .works
          .map((work) => work.id),
      [2],
    );
    final stale = search('old');
    context = (
      authEpoch: 0,
      token: null,
      contentEpoch: 1,
      language: AsmrContentLanguage.ja,
      scope: 'local-cancellation',
    );
    catalog.invalidateForContentChange();
    await stale;
    expect(
      catalog
          .viewState(
            AsmrCategoryType.favorites,
            searchQuery: 'old',
            searchSession: true,
          )
          .works,
      isEmpty,
    );
    await search('old');
    expect(
      catalog
          .viewState(
            AsmrCategoryType.favorites,
            searchQuery: 'old',
            searchSession: true,
          )
          .works
          .map((work) => work.id),
      [1],
    );
  });

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
    'cold category ensures share a request and repeated returns reuse results',
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
        apiService: api,
        persistenceRepository: persistenceRepository(),
      );
      final first = controller.ensureCategoryLoaded(AsmrCategoryType.release);
      final concurrent = controller.ensureCategoryLoaded(
        AsmrCategoryType.release,
      );
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
      await Future.wait([first, concurrent, repeated]);
      expect(repeatedCompleted, isTrue);
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        isNotEmpty,
      );
      final loaded = controller.categoryViewState(AsmrCategoryType.release);
      for (var visit = 0; visit < 10; visit++) {
        await controller.initializeForVisiblePage();
        await controller.ensureCategoryLoaded(AsmrCategoryType.release);
      }
      expect(api.fetchWorkRequests, hasLength(1));
      expect(
        controller.categoryViewState(AsmrCategoryType.release).works,
        same(loaded.works),
      );
      await controller.refreshCategory(AsmrCategoryType.release);
      expect(api.fetchWorkRequests, hasLength(2));
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

  test('ASMR mapping serializes shared work metadata once', () {
    final work = _IsolateReportingWork();
    final tracks = flattenAsmrPlayableTracks(work, [
      for (var i = 0; i < 2000; i++) _trackFile('track$i.mp3', 'track$i.mp3'),
    ]);
    expect(work.serializations, 1);
    expect(tracks, hasLength(2000));
    expect(tracks.first.remoteMetadata?['trackRelativePath'], 'track0.mp3');
    expect(tracks.last.remoteMetadata?['trackRelativePath'], 'track1999.mp3');
    expect(
      () => tracks.first.remoteMetadata!['title'] = 'changed',
      throwsUnsupportedError,
    );
    expect(tracks.last.remoteMetadata?['title'], work.title);
  });

  test(
    'ASMR cold playable mapping runs off the caller isolate and shares concurrent results',
    () async {
      await resetPrefs();
      final work = _IsolateReportingWork();
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        apiService: _FakeAsmrApiService(
          trackTree: [
            _trackFile('track1.mp3', 'track1.mp3'),
            _trackFile('track2.mp3', 'track2.mp3'),
          ],
        ),
        persistenceRepository: persistenceRepository(),
      );
      final results = await Future.wait([
        controller.loadPlayableTracks(work),
        controller.loadPlayableTracks(work),
      ]);
      expect(results.first, same(results.last));
      expect(results.first, hasLength(2));
      expect(
        results.first.first.remoteMetadata?['mappingIsolate'],
        isNot(Isolate.current.debugName),
      );
      expect(work.serializations, 0);
      expect(await controller.loadPlayableTracks(work), same(results.first));
      await controller.ensureTrackTree(work, forceRefresh: true);
      expect(
        await controller.loadPlayableTracks(work),
        isNot(same(results.first)),
      );
    },
  );

  test('ASMR playable loading rejects a disposed owner', () async {
    await resetPrefs();
    final controller = createTestAsmrController(
      preferencesStore: preferences,
      apiService: _FakeAsmrApiService(),
      persistenceRepository: persistenceRepository(),
    );
    await controller.initializeForVisiblePage();
    controller.dispose();
    await expectLater(
      controller.loadPlayableTracks(_work(id: 1, title: 'Work')),
      throwsStateError,
    );
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

    final first = controller.trackTreeViewState(work.workKey);
    final second = controller.trackTreeViewState(work.workKey);

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

      final loading = controller.trackTreeViewState(work.workKey);
      expect(loading.isLoading, isTrue);
      expect(loading.tree, isNull);
      expect(loading.operationError, isNull);

      release.complete();
      await request;

      final loaded = controller.trackTreeViewState(work.workKey);
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

      final failed = controller.trackTreeViewState(work.workKey);
      expect(failed.isLoading, isFalse);
      expect(failed.tree, isNull);
      expect(failed.operationError, isA<SocketException>());

      await controller.ensureTrackTree(work);

      final empty = controller.trackTreeViewState(work.workKey);
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
    expect(trees.last, same(trees.first));
    expect(api.trackCancellationTokens.single!.isCancelled, isFalse);
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
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);

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
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);

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
      expect(controller.trackTreeFor('code:RJ000072'), isNull);
      expect(controller.trackTreeViewState('code:RJ000072').isLoading, isTrue);
      controller.clearRuntimeCaches();
      await rejected;
      expect(controller.trackTreeFor('code:RJ000072'), isNull);
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
        expect(controller.trackTreeFor('code:RJ000072'), isNull);
        final authUpdate = accountChange
            ? controller.logoutAsmrAccount()
            : null;
        if (!accountChange) controller.setPageLanguage(AppLanguage.en);
        await replacementStarted.future;
        await authUpdate;
        expect(controller.trackTreeFor('code:RJ000072'), isNull);
        replacementReleased.complete();
        final tree = await request;
        expect(tree.single.title, 'Track 2.mp3');
        expect(controller.trackTreeFor('code:RJ000072'), same(tree));
        expect(api.trackFetchWorkIds, [72, 72]);
      },
    );
  }

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'runtime clearing'} cancels pending file trees without starting a replacement request',
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
        final request = controller.ensureTrackTree(
          _work(id: 72, title: 'Work'),
        );
        await started.future;
        final rejected = expectLater(request, throwsStateError);
        if (dispose) {
          controller.dispose();
        } else {
          controller.clearRuntimeCaches();
        }
        await rejected.timeout(const Duration(seconds: 2));
        expect(api.trackCancellationTokens.single!.isCancelled, isTrue);
        expect(api.trackFetchWorkIds, [72]);
        expect(controller.trackTreeFor('code:RJ000072'), isNull);
        release.complete();
      },
    );
  }

  for (final accountChange in [false, true]) {
    test(
      '${accountChange ? 'account' : 'language'} changes cancel a shared pending tree and redirect its callers',
      () async {
        await resetPrefs();
        final started = Completer<void>();
        final releaseOldTree = Completer<void>();
        var fetches = 0;
        final api = _FakeAsmrApiService(
          trackTree: [_trackFile('Current.mp3', 'Current.mp3')],
          beforeFetchTrackTree: (_) async {
            if (++fetches == 1) {
              started.complete();
              await releaseOldTree.future;
            }
          },
        );
        final controller = createTestAsmrController(
          preferencesStore: preferences,
          apiService: api,
          persistenceRepository: persistenceRepository(),
        );
        await controller.initializeForVisiblePage();
        if (accountChange) {
          await controller.loginAsmrAccount('alice', 'password');
        }
        final work = _work(id: 73, title: 'Shared cancellation');
        final first = controller.ensureTrackTree(work);
        final second = controller.ensureTrackTree(work);
        expect(second, same(first));
        await started.future;
        if (accountChange) {
          await controller.logoutAsmrAccount();
        } else {
          controller.setPageLanguage(AppLanguage.en);
        }
        final trees = await Future.wait([
          first,
          second,
        ]).timeout(const Duration(seconds: 2));
        expect(api.trackFetchWorkIds, [73, 73]);
        expect(api.trackFetchTokens.last, isNull);
        expect(api.trackCancellationTokens.first!.isCancelled, isTrue);
        expect(api.trackCancellationTokens.last!.isCancelled, isFalse);
        expect(trees.last, same(trees.first));
        expect(controller.trackTreeFor('code:RJ000073'), same(trees.first));
        releaseOldTree.complete();
      },
    );
  }

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

  test('page preparation preserves concurrent favorite changes', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(largeRecommendationPool: true);
    addTearDown(api.close);
    final services = createTestAsmrServices(
      preferencesStore: preferences,
      persistenceRepository: persistenceRepository(),
      apiService: api,
    );
    const context = (
      authEpoch: 0,
      token: null,
      contentEpoch: 0,
      language: AsmrContentLanguage.en,
      scope: 'page-preparation-test',
    );
    var favorites = const <String>{};
    Completer<void>? preparationStarted;
    final catalog = AsmrCategoryCatalog(
      remoteCatalogService: services.remoteCatalogService,
      onChanged: () {},
      isContextCurrent: (_) => true,
      currentContext: () => context,
      localWorks: (_) => const <AsmrWork>[],
      favoriteIds: () {
        final started = preparationStarted;
        if (started != null && !started.isCompleted) started.complete();
        return favorites;
      },
    );
    await catalog.refresh(
      AsmrCategoryType.release,
      searchQuery: '',
      context: context,
    );
    final untouched = catalog.worksFor(AsmrCategoryType.release)[1];
    preparationStarted = Completer<void>();
    final pagination = catalog.loadMore(
      AsmrCategoryType.release,
      searchQuery: '',
      context: context,
    );
    await preparationStarted.future;
    favorites = const <String>{'code:RJ003001', 'code:RJ003041'};
    catalog.updateFavorites({'code:RJ003001': true});
    await pagination;

    final works = catalog.worksFor(AsmrCategoryType.release);
    expect(works, hasLength(80));
    expect(works[1], same(untouched));
    expect(works.where((work) => work.isFavorite).map((work) => work.id), [
      3001,
      3041,
    ]);
    expect(catalog.isLoadingMore(AsmrCategoryType.release), isFalse);
  });

  for (final append in [false, true]) {
    test('cancellation during ${append ? "pagination" : "refresh"} preparation '
        'retains the completed page and permits retry', () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(largeRecommendationPool: true);
      addTearDown(api.close);
      final services = createTestAsmrServices(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository(),
        apiService: api,
      );
      const context = (
        authEpoch: 0,
        token: null,
        contentEpoch: 0,
        language: AsmrContentLanguage.en,
        scope: 'cancel-page-preparation-test',
      );
      Completer<void>? preparationStarted;
      final catalog = AsmrCategoryCatalog(
        remoteCatalogService: services.remoteCatalogService,
        onChanged: () {},
        isContextCurrent: (_) => true,
        currentContext: () => context,
        localWorks: (_) => const <AsmrWork>[],
        favoriteIds: () {
          final started = preparationStarted;
          if (started != null && !started.isCompleted) started.complete();
          return const <String>{};
        },
      );
      Future<void> load() => append
          ? catalog.loadMore(
              AsmrCategoryType.release,
              searchQuery: '',
              context: context,
            )
          : catalog.refresh(
              AsmrCategoryType.release,
              searchQuery: '',
              context: context,
            );
      await catalog.refresh(
        AsmrCategoryType.release,
        searchQuery: '',
        context: context,
      );
      final before = catalog.worksFor(AsmrCategoryType.release);
      preparationStarted = Completer<void>();
      final pending = load();
      await preparationStarted.future;
      catalog.cancelRequests();
      await pending;
      expect(catalog.worksFor(AsmrCategoryType.release), same(before));
      expect(catalog.isLoading(AsmrCategoryType.release), isFalse);
      expect(catalog.isLoadingMore(AsmrCategoryType.release), isFalse);
      expect(catalog.errorFor(AsmrCategoryType.release), isNull);

      preparationStarted = null;
      await load();
      final after = catalog.worksFor(AsmrCategoryType.release);
      expect(after, hasLength(append ? 80 : 40));
      if (append) expect(after.first, same(before.first));
    });
  }

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
      await controller.ensureCategoryLoaded(AsmrCategoryType.release);

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

class _CountingSearchWork extends AsmrWork {
  _CountingSearchWork(int id)
    : super(
        id: id,
        title: ' Sleep\n Induction ',
        circleName: ' Circle\tDemo ',
        sourceId: 'RJ${id.toString().padLeft(4, '0')}',
        sourceType: 'DLSITE',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: [' VOICE\t Actor '],
        tags: [' Gentle\n Sound '],
      );
  final _titleReads = <int>[0];
  int get titleReads => _titleReads.single;
  @override
  String get title {
    _titleReads[0]++;
    return super.title;
  }
}

class _FailingSearchWork extends _CountingSearchWork {
  _FailingSearchWork() : super(1);

  @override
  String get title =>
      throw StateError('forced local search preparation failure');
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

class _DailyCreatorApi extends _FakeAsmrApiService {
  _DailyCreatorApi({super.beforeFetchSearchResponse});
  final requests = <String>[];

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    requests.add('$keyword:$page');
    await beforeFetchSearchResponse?.call('$keyword:$page');
    cancellationToken?.throwIfCancelled();
    expect(order, 'release');
    expect(sort, 'desc');
    final id = switch (keyword) {
      'voice a' => 1,
      'circle b' => 2,
      _ => 3,
    };
    return AsmrWorkPage(
      works: [
        AsmrWork.fromJson({
          ..._work(
            id: page == 1 ? id : 100 + id,
            title: 'Creator work',
            circleName: keyword == 'voice a'
                ? 'Other circle'
                : keyword == 'circle b'
                ? 'Circle B'
                : 'Circle C',
            releaseDate: page == 1
                ? DateTime(2026, 10, 26 - id)
                : DateTime(2020),
          ).toJson(),
          'voiceActors': keyword == 'voice a' ? ['Voice A'] : <String>[],
        }),
        for (var i = 1; i < pageSize; i++)
          _work(id: 999, title: 'Keyword match only'),
      ],
      currentPage: page,
      pageSize: pageSize,
      totalCount: 400,
    );
  }
}

class _CatalogFailingPreferencesStore extends AsmrPreferencesStore {
  _CatalogFailingPreferencesStore({required super.repository});
  bool failCatalogSave = false;
  @override
  Future<void> saveVoiceActorPreferences(AsmrTagPreferences value) {
    if (failCatalogSave && value.catalogComplete) throw StateError('save failed');
    return super.saveVoiceActorPreferences(value);
  }
}

class _DailyFailingPreferencesStore extends AsmrPreferencesStore {
  _DailyFailingPreferencesStore({required super.repository});
  bool failDailySave = true;
  @override
  Future<void> saveDailyRecommendations({
    required AsmrContentLanguage language,
    required String date,
    required List<AsmrWork> works,
    String interests = '',
  }) {
    if (failDailySave) throw StateError('save failed');
    return super.saveDailyRecommendations(
      language: language,
      date: date,
      works: works,
      interests: interests,
    );
  }
}

class _InterestTracksRepository extends TestPersistenceRepository {
  _InterestTracksRepository(this.readTracks);
  final Future<List<MusicTrack>> Function() readTracks;
  int reads = 0;

  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() {
    reads++;
    return readTracks();
  }
}

class _VoiceCatalogApi extends _FakeAsmrApiService {
  bool fail = true;
  Completer<List<AsmrTag>>? pending;
  final started = Completer<void>();

  @override
  Future<List<AsmrTag>> fetchVoiceActorCatalog() async {
    if (fail) throw StateError('offline');
    if (pending != null) {
      started.complete();
      return pending!.future;
    }
    return [AsmrTag(key: 'online:voice-id', name: 'Known voice')];
  }
}

class _CircleCatalogApi extends _FakeAsmrApiService {
  bool fail = true;
  Completer<List<AsmrTag>>? pending;
  final started = Completer<void>();

  @override
  Future<List<AsmrTag>> fetchCircleCatalog() async {
    if (fail) throw StateError('offline');
    if (pending != null) {
      started.complete();
      return pending!.future;
    }
    return [AsmrTag(key: 'online:circle-id', name: 'Known circle')];
  }
}
