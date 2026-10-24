import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_persistence_repository.dart';

import 'support/asmr_controller_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({AsmrLibraryController controller, _SuggestionsCatalog catalog}) setup(
    _SuggestionsRepository repository,
  ) {
    final api = AsmrApiService();
    final services = createTestAsmrServices(
      persistenceRepository: repository,
      apiService: api,
    );
    final catalog = _SuggestionsCatalog(api, repository);
    final controller = AsmrLibraryController(
      preferencesStore: services.preferencesStore,
      remoteCatalogService: catalog,
      accountSyncService: services.accountSyncService,
    );
    addTearDown(controller.dispose);
    return (controller: controller, catalog: catalog);
  }

  AsmrSearchSuggestions suggestions(String prefix) => AsmrSearchSuggestions(
    voiceActors: ['$prefix voice'],
    tags: ['$prefix tag'],
  );

  test(
    'first frame has bounded real suggestions without any IO or initialization',
    () async {
      final repository = _SuggestionsRepository();
      final fixture = setup(repository);
      expect(fixture.controller.searchSuggestions.voiceActors, hasLength(30));
      expect(fixture.controller.searchSuggestions.tags, hasLength(30));
      expect(repository.reads, 0);
      final load = fixture.controller.ensureSearchSuggestions();
      expect(fixture.controller.ensureSearchSuggestions(), same(load));
      await fixture.catalog.started.future;
      expect(repository.trackReads, 0);
      expect(fixture.catalog.requests, 1);
      expect(fixture.controller.isLoadingSearchSuggestions, isTrue);
      fixture.catalog.response.complete(suggestions('Live'));
      await load;
      expect(fixture.controller.searchSuggestions.voiceActors, ['Live voice']);
      expect(fixture.controller.isLoadingSearchSuggestions, isFalse);
      final cache = await AsmrPreferencesStore(
        repository: repository,
      ).loadSearchSuggestions();
      expect(cache!.suggestions.tags, ['Live tag']);
      await fixture.controller.ensureSearchSuggestions();
      expect(fixture.catalog.requests, 1);
    },
  );

  test(
    'fresh persisted cache restores without a network request or interest scan',
    () async {
      final repository = _SuggestionsRepository();
      await AsmrPreferencesStore(
        repository: repository,
      ).saveSearchSuggestions(suggestions('Saved'), DateTime.now());
      final fixture = setup(repository);
      await fixture.controller.ensureSearchSuggestions();
      expect(fixture.controller.searchSuggestions.tags, ['Saved tag']);
      expect(fixture.catalog.requests, 0);
      expect(repository.trackReads, 0);
    },
  );

  test(
    'expired cache remains displayed on failure and force retry refreshes it',
    () async {
      final repository = _SuggestionsRepository();
      await AsmrPreferencesStore(repository: repository).saveSearchSuggestions(
        suggestions('Saved'),
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final fixture = setup(repository);
      final load = fixture.controller.ensureSearchSuggestions();
      await fixture.catalog.started.future;
      expect(fixture.controller.searchSuggestions.tags, ['Saved tag']);
      fixture.catalog.response.completeError(StateError('Offline'));
      await load;
      expect(fixture.controller.searchSuggestionsError, isStateError);
      expect(fixture.controller.searchSuggestions.voiceActors, ['Saved voice']);
      fixture.catalog.response = Completer();
      final retry = fixture.controller.ensureSearchSuggestions(force: true);
      await Future<void>.delayed(Duration.zero);
      fixture.catalog.response.complete(suggestions('New'));
      await retry;
      expect(fixture.controller.searchSuggestionsError, isNull);
      expect(fixture.controller.searchSuggestions.tags, ['New tag']);
    },
  );

  test(
    'corrupt cache does not block live suggestions and publication precedes disk write',
    () async {
      final repository = _SuggestionsRepository()
        ..settings['asmr_search_suggestions_v1'] = '{broken'
        ..writeGate = Completer();
      final fixture = setup(repository);
      final load = fixture.controller.ensureSearchSuggestions();
      await fixture.catalog.started.future;
      fixture.catalog.response.complete(suggestions('Live'));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.controller.searchSuggestions.tags, ['Live tag']);
      repository.writeGate!.complete();
      await load;
      expect(fixture.controller.searchSuggestionsError, isNull);
    },
  );

  testWidgets('network deadline preserves seed data and cancels the request', (
    tester,
  ) async {
    final fixture = setup(_SuggestionsRepository());
    final initial = fixture.controller.searchSuggestions;
    final load = fixture.controller.ensureSearchSuggestions();
    await tester.pump();
    expect(fixture.catalog.requests, 1);
    await tester.pump(const Duration(seconds: 5));
    await load;
    expect(fixture.catalog.cancellation!.isCancelled, isTrue);
    expect(fixture.controller.searchSuggestions, same(initial));
    expect(fixture.controller.searchSuggestionsError, isA<TimeoutException>());
    fixture.catalog.response.complete(suggestions('Late'));
    await tester.pump();
    expect(fixture.controller.searchSuggestions, same(initial));
  });

  test('cache reset and disposal reject late responses', () async {
    final repository = _SuggestionsRepository();
    final fixture = setup(repository);
    final load = fixture.controller.ensureSearchSuggestions();
    await fixture.catalog.started.future;
    fixture.controller.clearRuntimeCaches();
    fixture.catalog.response.complete(suggestions('Old'));
    await load;
    expect(fixture.controller.searchSuggestions.tags, isNot(['Old tag']));
    expect(repository.settings, isEmpty);
    fixture.catalog.response = Completer();
    final pending = fixture.controller.ensureSearchSuggestions();
    await Future<void>.delayed(Duration.zero);
    fixture.controller.dispose();
    fixture.catalog.response.complete(suggestions('Disposed'));
    await pending;
    expect(repository.settings, isEmpty);
  });
}

class _SuggestionsRepository implements AsmrPersistenceRepository {
  final settings = <String, String>{};
  int reads = 0;
  int trackReads = 0;
  Completer<void>? writeGate;

  @override
  Future<String?> loadSetting(String key) async {
    reads++;
    return settings[key];
  }

  @override
  Future<void> saveSetting(String key, String? value) async {
    await writeGate?.future;
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }

  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() {
    trackReads++;
    throw StateError('Search suggestions must not scan local tracks');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected initialization: ${invocation.memberName}');
}

class _SuggestionsCatalog extends AsmrRemoteCatalogService {
  _SuggestionsCatalog(AsmrApiService api, AsmrPersistenceRepository repository)
    : super(apiService: api, persistenceRepository: repository);

  Completer<AsmrSearchSuggestions> response = Completer();
  final started = Completer<void>();
  int requests = 0;
  AsmrRequestCancellationToken? cancellation;

  @override
  Future<AsmrSearchSuggestions> loadSearchSuggestions({
    AsmrRequestCancellationToken? cancellationToken,
  }) {
    requests++;
    cancellation = cancellationToken;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}
