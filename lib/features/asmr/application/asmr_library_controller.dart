import '../domain/asmr_tag_interest.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../core/persistence/persisted_state_reloader.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/immutable_collections.dart';
import '../domain/asmr_models.dart';
import '../domain/asmr_search_suggestions.dart';
import '../../../core/media/music_track.dart';
import '../../library/application/work_text_service.dart';
import 'asmr_account_sync_service.dart';
import 'asmr_category_catalog.dart';
import 'asmr_download_manager.dart';
import 'asmr_playback_coordinator.dart';
import 'asmr_preferences.dart';
import 'asmr_search_suggestions_seed.dart';
import 'asmr_remote_catalog_service.dart';
import 'asmr_request_cancellation.dart';
import 'asmr_library_view_state.dart';
import 'asmr_work_content_mapping.dart';
import 'asmr_work_content_store.dart';
import '../../../core/app_language.dart';

export 'asmr_library_view_state.dart';
export '../domain/asmr_tag_interest.dart';
export '../domain/asmr_search_suggestions.dart';
export 'asmr_work_content_mapping.dart' show collectAsmrWorkTextFiles;

enum _CreatorInterest { voiceActor, circle }

typedef _AsmrSyncRequestKey = ({int authEpoch, String token});
typedef _InterestSnapshot = ({
  List<AsmrTagInterest> interests,
  Map<String, double> weights,
});

AsmrTagPreferences _mergeTagCatalog(
  ({AsmrTagPreferences state, List<AsmrTag> entries}) input,
) => AsmrTagPreferences.fromJson(input.state.toJson())
  ..mergeTags(input.entries)
  ..catalogComplete = true;

List<MusicTrack> _buildPlayableTracks(
  ({AsmrWork work, List<AsmrTrackFile> tree}) input,
) => flattenAsmrPlayableTracks(input.work, input.tree);

(AsmrTagPreferences, AsmrTagPreferences, AsmrTagPreferences)
_deriveTagInterests(
  ({
    AsmrTagPreferences state,
    AsmrTagPreferences voices,
    AsmrTagPreferences circles,
    List<MusicTrack> tracks,
    List<AsmrWork> favorites,
    List<AsmrWork> history,
  })
  input,
) {
  final state = AsmrTagPreferences.fromJson(input.state.toJson());
  final voices = AsmrTagPreferences.fromJson(input.voices.toJson());
  final circles = AsmrTagPreferences.fromJson(input.circles.toJson());
  final tagGroups = input.tracks
      .map((track) => track.tags)
      .followedBy(input.favorites.map((work) => work.tags))
      .followedBy(input.history.map((work) => work.tags));
  for (final tags in tagGroups) {
    for (final tag in tags) {
      if (tag.trim().isNotEmpty) state.resolve(tag);
    }
  }
  final voiceGroups = input.tracks
      .map(
        (track) => <String>[
          for (final field in ['voiceActors', 'vas'])
            for (final value in track.remoteMetadata?[field] as List? ?? [])
              if (value is String)
                value
              else if (value is Map && value['name'] is String)
                value['name'] as String,
        ],
      )
      .followedBy(input.favorites.map((work) => work.voiceActors))
      .followedBy(input.history.map((work) => work.voiceActors));
  for (final names in voiceGroups) {
    for (final name in names) {
      if (name.trim().isNotEmpty) voices.resolve(name);
    }
  }
  final circleNames = input.tracks
      .map((track) => track.remoteCircleName)
      .followedBy(input.favorites.map((work) => work.circleName))
      .followedBy(input.history.map((work) => work.circleName));
  for (final name in circleNames) {
    if (name.trim().isNotEmpty) circles.resolve(name);
  }
  return (state, voices, circles);
}

class AsmrLibraryController extends ChangeNotifier
    implements AsmrPlaybackSource, PersistedStateReloader {
  AsmrLibraryController({
    required AsmrPreferencesStore preferencesStore,
    required AsmrRemoteCatalogService remoteCatalogService,
    required AsmrAccountSyncService accountSyncService,
  }) : _preferencesStore = preferencesStore,
       _remoteCatalogService = remoteCatalogService,
       _accountSyncService = accountSyncService {
    _remoteCatalogService.isWorkAllowed = _isWorkAllowed;
    _remoteCatalogService.tagWeights = () =>
        _interestSnapshot(_tagPreferences).weights;
    _remoteCatalogService.voiceActorWeights = () =>
        _interestSnapshot(_voiceActorPreferences).weights;
    _remoteCatalogService.circleWeights = () =>
        _interestSnapshot(_circlePreferences).weights;
    _remoteCatalogService.prepareTagInterests = (tracks) =>
        ensureTagInterests(localTracks: tracks);
  }

  final AsmrPreferencesStore _preferencesStore;
  final AsmrRemoteCatalogService _remoteCatalogService;
  final AsmrAccountSyncService _accountSyncService;
  late final AsmrWorkContentStore _workContent = AsmrWorkContentStore(
    onChanged: notifyListeners,
  );
  late final AsmrCategoryCatalog _catalog = AsmrCategoryCatalog(
    remoteCatalogService: _remoteCatalogService,
    onChanged: notifyListeners,
    isContextCurrent: (context) =>
        !_disposed &&
        context.authEpoch == _authEpoch &&
        context.token == _authSession?.token &&
        context.contentEpoch == _contentEpoch,
    localWorks: (category) =>
        category == AsmrCategoryType.favorites ? _favoriteWorks : _historyWorks,
    favoriteIds: () => _favoriteIds,
    isWorkAllowed: _isWorkAllowed,
    hasExclusions: () =>
        _tagPreferences.excluded.isNotEmpty ||
        _voiceActorPreferences.excluded.isNotEmpty ||
        _circlePreferences.excluded.isNotEmpty,
    currentContext: () => _categoryRequestContext,
  );

  AsmrTagPreferences _tagPreferences = AsmrTagPreferences();
  AsmrTagPreferences _voiceActorPreferences = AsmrTagPreferences();
  AsmrTagPreferences _circlePreferences = AsmrTagPreferences();
  final _interestSnapshots = Expando<_InterestSnapshot>();
  final _sortedCatalogs = Expando<List<AsmrTag>>();

  List<AsmrTag> _sortedCatalog(AsmrTagPreferences preferences) =>
      _sortedCatalogs[preferences] ??= immutableList(
        preferences.tags.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name)),
      );
  _InterestSnapshot _interestSnapshot(AsmrTagPreferences preferences) {
    final cached = _interestSnapshots[preferences];
    if (cached != null) return cached;
    final interests = immutableList(preferences.listenedInterests);
    return _interestSnapshots[preferences] = (
      interests: interests,
      weights: immutableMap(preferences.recommendationWeightsFor(interests)),
    );
  }

  final Map<_CreatorInterest, Future<void>> _creatorCatalogTasks = {};
  final Map<_CreatorInterest, Object> _creatorCatalogErrors = {};
  List<AsmrTagInterest> get voiceActorInterests =>
      _interestSnapshot(_voiceActorPreferences).interests;
  List<AsmrTagInterest> get listenedVoiceActorInterests => voiceActorInterests;
  Set<String> get manualInterestVoiceActorKeys =>
      Set.unmodifiable(_voiceActorPreferences.manualInterests);
  Set<String> get excludedVoiceActorKeys =>
      Set.unmodifiable(_voiceActorPreferences.excluded);
  List<AsmrTag> get allVoiceActors => _sortedCatalog(_voiceActorPreferences);
  bool get voiceActorCatalogComplete => _voiceActorPreferences.catalogComplete;
  bool get isLoadingVoiceActorCatalog =>
      _creatorCatalogTasks.containsKey(_CreatorInterest.voiceActor);
  Object? get voiceActorCatalogError =>
      _creatorCatalogErrors[_CreatorInterest.voiceActor];
  List<AsmrTagInterest> get circleInterests =>
      _interestSnapshot(_circlePreferences).interests;
  List<AsmrTagInterest> get listenedCircleInterests => circleInterests;
  Set<String> get manualInterestCircleKeys =>
      Set.unmodifiable(_circlePreferences.manualInterests);
  Set<String> get excludedCircleKeys =>
      Set.unmodifiable(_circlePreferences.excluded);
  List<AsmrTag> get allCircles => _sortedCatalog(_circlePreferences);
  bool get circleCatalogComplete => _circlePreferences.catalogComplete;
  bool get isLoadingCircleCatalog =>
      _creatorCatalogTasks.containsKey(_CreatorInterest.circle);
  Object? get circleCatalogError =>
      _creatorCatalogErrors[_CreatorInterest.circle];
  Future<void>? _tagInterestsTask;
  bool _tagInterestsReady = false;
  Future<void>? _tagCatalogTask;
  Object? _tagCatalogError;
  List<AsmrTagInterest> get interestTags =>
      _interestSnapshot(_tagPreferences).interests;
  List<AsmrTagInterest> get listenedTagInterests => interestTags;
  Set<String> get manualInterestTagKeys =>
      Set.unmodifiable(_tagPreferences.manualInterests);
  List<AsmrTag> get allTags => _sortedCatalog(_tagPreferences);

  AsmrSearchSuggestions _searchSuggestions = initialAsmrSearchSuggestions;
  AsmrSearchSuggestions get searchSuggestions => _searchSuggestions;
  Object? _searchSuggestionsError;
  Object? get searchSuggestionsError => _searchSuggestionsError;
  Future<void>? _searchSuggestionsTask;
  bool get isLoadingSearchSuggestions => _searchSuggestionsTask != null;
  DateTime? _searchSuggestionsUpdatedAt;
  AsmrRequestCancellationToken? _searchSuggestionsCancellation;
  static const _searchSuggestionsFreshFor = Duration(hours: 6);

  Future<void> ensureSearchSuggestions({bool force = false}) {
    if (_disposed) return Future.value();
    final pending = _searchSuggestionsTask;
    if (pending != null) return pending;
    final age = DateTime.now().difference(
      _searchSuggestionsUpdatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
    if (!force && !age.isNegative && age < _searchSuggestionsFreshFor) {
      return Future.value();
    }
    final cancellation = AsmrRequestCancellationToken();
    _searchSuggestionsCancellation = cancellation;
    final epoch = _runtimeCacheEpoch;
    _searchSuggestionsError = null;
    late final Future<void> task;
    task = _loadSearchSuggestions(epoch, cancellation, force: force)
        .whenComplete(() {
          if (!identical(task, _searchSuggestionsTask)) return;
          _searchSuggestionsTask = null;
          _searchSuggestionsCancellation = null;
          notifyListeners();
        });
    _searchSuggestionsTask = task;
    notifyListeners();
    return task;
  }

  Future<void> _loadSearchSuggestions(
    int epoch,
    AsmrRequestCancellationToken cancellation, {
    required bool force,
  }) async {
    bool isCurrent() =>
        !_disposed && epoch == _runtimeCacheEpoch && !cancellation.isCancelled;
    // Search suggestions must not wait for account restoration, the full voice
    // directory, or a scan/derivation of the user's local listening interests.
    try {
      final cached = await cancellation.waitFor(
        _preferencesStore.loadSearchSuggestions(),
      );
      if (!isCurrent()) return;
      if (cached != null) {
        _searchSuggestions = cached.suggestions;
        _searchSuggestionsUpdatedAt = cached.updatedAt;
        notifyListeners();
        final age = DateTime.now().difference(cached.updatedAt);
        if (!force && !age.isNegative && age < _searchSuggestionsFreshFor) {
          return;
        }
      }
    } catch (error, stack) {
      if (!isCurrent()) return;
      AppLogService.warning(
        'asmr_search_suggestions_cache_read_failed',
        error: error,
        stackTrace: stack,
      );
    }
    try {
      final suggestions = await cancellation
          .waitFor(
            _remoteCatalogService.loadSearchSuggestions(
              cancellationToken: cancellation,
            ),
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              cancellation.cancel();
              throw TimeoutException('Search suggestions request timed out.');
            },
          );
      if (!isCurrent()) return;
      final updatedAt = DateTime.now();
      _searchSuggestions = suggestions;
      _searchSuggestionsUpdatedAt = updatedAt;
      notifyListeners();
      // Publish first; disk writes must not delay already available suggestions.
      await _runStateMutation(() async {
        if (isCurrent()) {
          await _preferencesStore.saveSearchSuggestions(suggestions, updatedAt);
        }
      });
    } catch (error) {
      if (_disposed || epoch != _runtimeCacheEpoch) return;
      if (error is AsmrRequestCancelled) return;
      _searchSuggestionsError = error;
    }
  }

  void _invalidateSearchSuggestions() {
    _searchSuggestionsCancellation?.cancel();
    _searchSuggestionsCancellation = null;
    _searchSuggestionsTask = null;
    _searchSuggestionsUpdatedAt = null;
    _searchSuggestionsError = null;
    _searchSuggestions = initialAsmrSearchSuggestions;
  }

  Set<String> get excludedTagKeys => Set.unmodifiable(_tagPreferences.excluded);
  bool get tagCatalogComplete => _tagPreferences.catalogComplete;
  bool get isLoadingTagCatalog => _tagCatalogTask != null;
  Object? get tagCatalogError => _tagCatalogError;
  bool _isWorkAllowed(AsmrWork work) =>
      !_tagPreferences.excludes(names: work.tags, ids: work.tagIds) &&
      !_voiceActorPreferences.excludes(names: work.voiceActors) &&
      !_circlePreferences.excludes(names: [work.circleName]);

  Future<void> _mutateTagPreferences(
    void Function(AsmrTagPreferences)? mutate, {
    bool interruptRecommendations = false,
    List<AsmrTag>? catalog,
    int? expectedEpoch,
  }) => _runStateMutation(() async {
    bool isCurrent() =>
        !_disposed &&
        (expectedEpoch == null || expectedEpoch == _runtimeCacheEpoch);
    if (!isCurrent()) return;
    final next = catalog == null
        ? AsmrTagPreferences.fromJson(_tagPreferences.toJson())
        : await compute(_mergeTagCatalog, (
            state: _tagPreferences,
            entries: catalog,
          ));
    if (!isCurrent()) return;
    mutate?.call(next);
    await _preferencesStore.saveTagPreferences(next);
    if (!isCurrent()) return;
    _tagPreferences = next;
    _catalog.preferencesChanged(
      interruptRecommendations: interruptRecommendations,
    );
    _bumpGlobalRevision();
    notifyListeners();
  });

  Future<void> setTagInterested(String key, bool interested) =>
      applyTagSelections(excluded: false, changes: {key: interested});

  AsmrTagPreferences _creatorPreferences(_CreatorInterest kind) =>
      kind == _CreatorInterest.voiceActor
      ? _voiceActorPreferences
      : _circlePreferences;

  Future<void> _mutateCreatorPreferences(
    _CreatorInterest kind,
    void Function(AsmrTagPreferences)? mutate, {
    bool interruptRecommendations = false,
    int? expectedEpoch,
    List<AsmrTag>? catalog,
  }) async {
    await _runStateMutation(() async {
      if (_disposed ||
          (expectedEpoch != null && expectedEpoch != _runtimeCacheEpoch)) {
        return;
      }
      final next = catalog == null
          ? AsmrTagPreferences.fromJson(_creatorPreferences(kind).toJson())
          : await compute(_mergeTagCatalog, (
              state: _creatorPreferences(kind),
              entries: catalog,
            ));
      if (_disposed ||
          (expectedEpoch != null && expectedEpoch != _runtimeCacheEpoch)) {
        return;
      }
      mutate?.call(next);
      if (kind == _CreatorInterest.voiceActor) {
        await _preferencesStore.saveVoiceActorPreferences(next);
      } else {
        await _preferencesStore.saveCirclePreferences(next);
      }
      if (_disposed ||
          (expectedEpoch != null && expectedEpoch != _runtimeCacheEpoch)) {
        return;
      }
      if (kind == _CreatorInterest.voiceActor) {
        _voiceActorPreferences = next;
      } else {
        _circlePreferences = next;
      }
      _catalog.preferencesChanged(
        interruptRecommendations: interruptRecommendations,
      );
      _bumpGlobalRevision();
      notifyListeners();
    });
  }

  Future<void> applyVoiceActorSelections({
    bool excluded = false,
    required Map<String, bool> changes,
  }) => _applyCreatorSelections(_CreatorInterest.voiceActor, excluded, changes);

  Future<void> applyCircleSelections({
    bool excluded = false,
    required Map<String, bool> changes,
  }) => _applyCreatorSelections(_CreatorInterest.circle, excluded, changes);

  Future<void> _applyCreatorSelections(
    _CreatorInterest kind,
    bool excluded,
    Map<String, bool> changes,
  ) async {
    if (changes.isEmpty) return;
    final selections = Map<String, bool>.of(changes);
    await ensureTagInterests();
    await _mutateCreatorPreferences(
      kind,
      (state) => _applySelections(state, selections, excluded: excluded),
      interruptRecommendations: true,
    );
    await _refreshRecommendationsAfterPreferenceChange();
  }

  static void _applySelections(
    AsmrTagPreferences state,
    Map<String, bool> changes, {
    required bool excluded,
  }) {
    for (final entry in changes.entries) {
      if (!excluded) {
        state.setInterested(entry.key, entry.value);
      } else {
        if (!state.tags.containsKey(entry.key)) {
          throw ArgumentError.value(entry.key, 'key');
        }
        if (entry.value) {
          state.excluded.add(entry.key);
        } else {
          state.excluded.remove(entry.key);
        }
      }
    }
  }

  Future<void> recordVoiceActorListeningBatch({
    required String batchId,
    required List<({List<String> tags, Duration duration})> contributions,
  }) => _recordCreatorListeningBatch(
    _CreatorInterest.voiceActor,
    batchId,
    contributions,
  );

  Future<void> recordCircleListeningBatch({
    required String batchId,
    required List<({List<String> tags, Duration duration})> contributions,
  }) => _recordCreatorListeningBatch(
    _CreatorInterest.circle,
    batchId,
    contributions,
  );

  Future<void> _recordCreatorListeningBatch(
    _CreatorInterest kind,
    String batchId,
    List<({List<String> tags, Duration duration})> contributions,
  ) async {
    await ensureTagInterests();
    await _mutateCreatorPreferences(
      kind,
      (state) => state.recordListeningBatch(batchId, contributions),
    );
  }

  Future<void> ensureVoiceActorCatalog({bool force = false}) =>
      _ensureCreatorCatalog(_CreatorInterest.voiceActor, force: force);

  Future<void> ensureCircleCatalog({bool force = false}) =>
      _ensureCreatorCatalog(_CreatorInterest.circle, force: force);

  Future<void> _ensureCreatorCatalog(
    _CreatorInterest kind, {
    required bool force,
  }) {
    final pending = _creatorCatalogTasks[kind];
    if (pending != null) return pending;
    if (!force && _creatorPreferences(kind).catalogComplete) {
      return ensureTagInterests();
    }
    late final Future<void> task;
    task =
        (() async {
          final epoch = _runtimeCacheEpoch;
          _creatorCatalogErrors.remove(kind);
          try {
            await initializeForVisiblePage();
            await ensureTagInterests();
            final entries = await (kind == _CreatorInterest.voiceActor
                ? _remoteCatalogService.loadVoiceActorCatalog()
                : _remoteCatalogService.loadCircleCatalog());
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            await _mutateCreatorPreferences(
              kind,
              null,
              catalog: entries,
              expectedEpoch: epoch,
            );
          } catch (error) {
            if (!_disposed && epoch == _runtimeCacheEpoch) {
              _creatorCatalogErrors[kind] = error;
            }
          }
        })().whenComplete(() {
          if (identical(task, _creatorCatalogTasks[kind])) {
            _creatorCatalogTasks.remove(kind);
          }
          notifyListeners();
        });
    _creatorCatalogTasks[kind] = task;
    notifyListeners();
    return task;
  }

  /// Commits one editor's changes together so a failed save leaves no partial selection.
  Future<void> applyTagSelections({
    required bool excluded,
    required Map<String, bool> changes,
  }) async {
    if (changes.isEmpty) return;
    final selections = Map<String, bool>.of(changes);
    await ensureTagInterests();
    await _mutateTagPreferences(
      (state) => _applySelections(state, selections, excluded: excluded),
      interruptRecommendations: true,
    );
    await _refreshRecommendationsAfterPreferenceChange();
  }

  Future<void> _refreshRecommendationsAfterPreferenceChange() async {
    if (!_catalog.hasLoaded(AsmrCategoryType.recommendation)) return;
    await refreshCategory(
      AsmrCategoryType.recommendation,
      searchQuery: _catalog.activeQuery(AsmrCategoryType.recommendation),
    );
  }

  Future<void> setTagExcluded(String key, bool excluded) =>
      applyTagSelections(excluded: true, changes: {key: excluded});

  Future<void> recordTagListeningBatch({
    required String batchId,
    required List<({List<String> tags, Duration duration})> contributions,
  }) async {
    await ensureTagInterests();
    await _mutateTagPreferences(
      (state) => state.recordListeningBatch(batchId, contributions),
    );
  }

  Future<void> recordTagListening({
    required String batchId,
    required List<String> tags,
    required Duration duration,
  }) => recordTagListeningBatch(
    batchId: batchId,
    contributions: [(tags: tags, duration: duration)],
  );

  Future<void> ensureTagCatalog({bool force = false}) {
    final pending = _tagCatalogTask;
    if (pending != null) return pending;
    if (!force && tagCatalogComplete) return ensureTagInterests();
    late final Future<void> task;
    task = _loadTagCatalog().whenComplete(() {
      if (identical(task, _tagCatalogTask)) _tagCatalogTask = null;
      notifyListeners();
    });
    _tagCatalogTask = task;
    notifyListeners();
    return task;
  }

  Future<void> _loadTagCatalog() async {
    final epoch = _runtimeCacheEpoch;
    _tagCatalogError = null;
    try {
      await initializeForVisiblePage();
      await ensureTagInterests();
      final tags = await _remoteCatalogService.loadTagCatalog();
      if (_disposed || epoch != _runtimeCacheEpoch) return;
      await _mutateTagPreferences(null, catalog: tags, expectedEpoch: epoch);
    } catch (error) {
      if (!_disposed && epoch == _runtimeCacheEpoch) _tagCatalogError = error;
    }
  }

  Future<void> ensureTagInterests({List<MusicTrack>? localTracks}) async {
    await initializeForVisiblePage();
    if (_disposed || _tagInterestsReady) return;
    final pending = _tagInterestsTask;
    if (pending != null) return pending;
    final epoch = _runtimeCacheEpoch;
    late final Future<void> task;
    task =
        (() async {
          final tracks =
              localTracks ??
              await _remoteCatalogService.loadLocalTracksForInterests();
          await _runStateMutation(() async {
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            // Serialize against preference edits, but derive the full library's
            // tags away from the UI isolate and reuse recommendation inputs.
            final state = await compute(_deriveTagInterests, (
              state: _tagPreferences,
              voices: _voiceActorPreferences,
              circles: _circlePreferences,
              tracks: tracks,
              favorites: _favoriteWorks,
              history: _historyWorks,
            ));
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            await _preferencesStore.saveTagPreferences(state.$1);
            await _preferencesStore.saveVoiceActorPreferences(state.$2);
            await _preferencesStore.saveCirclePreferences(state.$3);
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            _tagPreferences = state.$1;
            _voiceActorPreferences = state.$2;
            _circlePreferences = state.$3;
            _tagInterestsReady = true;
            _bumpGlobalRevision();
            notifyListeners();
          });
        })().whenComplete(() {
          if (identical(_tagInterestsTask, task)) _tagInterestsTask = null;
        });
    _tagInterestsTask = task;
    return task;
  }

  List<AsmrCategoryType> _visibleCategories = kDefaultVisibleAsmrCategories;
  ContentLanguagePreference _contentLanguagePreference =
      ContentLanguagePreference.followPage;
  AppLanguage _pageLanguage = AppLanguage.zh;
  AsmrContentLanguage _contentLanguage = AsmrContentLanguage.zh;
  List<AsmrWork> _favoriteWorks = const <AsmrWork>[];
  Set<String> _favoriteIds = const <String>{};
  List<AsmrWork> _historyWorks = const <AsmrWork>[];
  List<AsmrSyncOperation> _syncOperations = const <AsmrSyncOperation>[];
  AsmrAuthSession? _authSession;
  AsmrSyncPhase _syncPhase = AsmrSyncPhase.idle;
  DateTime? _lastSyncAt;
  Object? _lastSyncError;
  Future<void>? _initializeTask;
  bool _skipRestoreForNextInitialize = false;
  Future<void>? _authRestoreTask;
  final Map<_AsmrSyncRequestKey, Future<void>> _syncTasks =
      <_AsmrSyncRequestKey, Future<void>>{};
  AsmrRequestCancellationToken? _activeSyncCancellationToken;
  Future<void> _stateMutationTail = Future<void>.value();
  bool _initialized = false;
  int _globalRevision = 0;
  int _authEpoch = 0;
  int _contentEpoch = 0;
  int _runtimeCacheEpoch = 0;
  bool _disposed = false;
  String get browseCacheScope =>
      '${_authSession?.userName.trim() ?? ''}:${_contentLanguage.name}';

  void beginSearchSession() => _catalog.clearSearchQueries();
  void endSearchSession() => _catalog.clearSearchQueries();
  void setSearchQuery(String query, AsmrCategoryType category) =>
      _catalog.setSearchQuery(query, category);

  void clearRuntimeCaches() {
    _invalidateSearchSuggestions();
    _creatorCatalogTasks.clear();
    _creatorCatalogErrors.clear();
    _runtimeCacheEpoch++;
    _contentEpoch++;
    _catalog.clearWorks();
    _workContent.clearCaches(clearErrors: true);
    _workContent.bumpAllTrackRevisions();
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  Future<T> _runStateMutation<T>(Future<T> Function() mutation) {
    final result = _stateMutationTail.then((_) => mutation());
    _stateMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  AsmrWorkRequestKey _workRequestKey(String workKey) => (
    workKey: workKey,
    contentEpoch: _contentEpoch,
    authEpoch: _authEpoch,
    runtimeCacheEpoch: _runtimeCacheEpoch,
  );

  bool _isWorkRequestCurrent(AsmrWorkRequestKey key) =>
      !_disposed &&
      key.contentEpoch == _contentEpoch &&
      key.authEpoch == _authEpoch &&
      key.runtimeCacheEpoch == _runtimeCacheEpoch;

  AsmrCategoryRequestContext get _categoryRequestContext => (
    authEpoch: _authEpoch,
    token: _authSession?.token,
    contentEpoch: _contentEpoch,
    language: _contentLanguage,
    scope: browseCacheScope,
  );

  void _refreshLoadedCategoriesForCurrentAuth() {
    final pending = _catalog.takePendingAuthRefreshes();
    unawaited(() async {
      for (final entry in pending.entries) {
        await ensureCategoryLoaded(entry.key, searchQuery: entry.value);
      }
    }());
  }

  void _invalidateRemoteWorkCaches() {
    _workContent.clearCaches(clearErrors: true);
  }

  void _applyAccountSnapshot(AsmrAccountSnapshot snapshot) {
    _authSession = snapshot.session;
    _favoriteWorks = snapshot.favoriteWorks;
    _favoriteIds = snapshot.favoriteIds;
    _historyWorks = snapshot.historyWorks;
    _syncOperations = snapshot.pendingOperations;
    _lastSyncAt = snapshot.lastSyncAt;
    _catalog.refreshLocalSearch();
  }

  void _cancelActiveSync() {
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = null;
  }

  bool get initialized => _initialized;
  List<AsmrCategoryType> get visibleCategories => _visibleCategories;
  ContentLanguagePreference get contentLanguagePreference =>
      _contentLanguagePreference;
  AppLanguage get pageLanguage => _pageLanguage;
  AsmrContentLanguage get contentLanguage => _contentLanguage;
  bool isFavorite(String workKey) => _favoriteIds.contains(workKey);
  bool get isAsmrAccountLoggedIn {
    final session = _authSession;
    return session != null &&
        session.isValid &&
        session.userName.trim().isNotEmpty;
  }

  String get asmrAccountName => _authSession?.userName.trim() ?? '';

  bool isLoadingCategory(AsmrCategoryType category) =>
      _catalog.isLoading(category);
  bool hasLoadedCategory(AsmrCategoryType category) =>
      AsmrCategoryCatalog.isRemote(category)
      ? _catalog.hasLoaded(category)
      : _initialized;
  bool isLoadingMoreCategory(AsmrCategoryType category) =>
      _catalog.isLoadingMore(category);
  bool hasMoreCategory(AsmrCategoryType category) => _catalog.hasMore(category);
  bool needsLoadMoreRetryCategory(AsmrCategoryType category) =>
      _catalog.needsLoadMoreRetry(category);
  int totalCountFor(AsmrCategoryType category) => _catalog.totalCount(category);
  String activeQueryFor(AsmrCategoryType category) =>
      _catalog.activeQuery(category);
  bool isTrackTreeLoading(String workKey) => _workContent.isLoading(workKey);
  List<AsmrTrackFile>? trackTreeFor(String workKey) =>
      _workContent.cachedTrackTree(workKey);

  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: _initialized,
    visibleCategories: _visibleCategories,
    contentLanguage: _contentLanguage,
    contentLanguagePreference: _contentLanguagePreference,
    revision: _globalRevision,
  );

  AsmrAuthViewState get authViewState => AsmrAuthViewState(
    isLoggedIn: isAsmrAccountLoggedIn,
    isRestoring: !_initialized || _authRestoreTask != null,
    userName: asmrAccountName,
    revision: _globalRevision,
  );

  AsmrSyncViewState get syncViewState => AsmrSyncViewState(
    phase: _syncPhase,
    lastSyncAt: _lastSyncAt,
    pendingCount: _syncOperations.length,
    lastError: _lastSyncError,
    revision: _globalRevision,
  );

  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => _catalog.viewState(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  );

  AsmrTrackTreeViewState trackTreeViewState(String workKey) =>
      _workContent.trackTreeViewState(workKey);

  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      _catalog.worksFor(category);

  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => _catalog.filteredWorksFor(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  );

  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) {
    final restoreAccountSession = !_skipRestoreForNextInitialize;
    _skipRestoreForNextInitialize = false;
    return _initialize(
      defaultLanguage: defaultLanguage,
      restoreAccountSession: restoreAccountSession,
    );
  }

  Future<void> initializeForVisiblePage({
    AsmrContentLanguage? defaultLanguage,
  }) {
    _skipRestoreForNextInitialize = true;
    final task = initialize(defaultLanguage: defaultLanguage);
    return task.whenComplete(() {
      _skipRestoreForNextInitialize = false;
    });
  }

  Future<void> _initialize({
    AsmrContentLanguage? defaultLanguage,
    required bool restoreAccountSession,
  }) {
    if (_disposed || _initialized) return Future<void>.value();
    final existing = _initializeTask;
    if (existing != null) {
      return existing;
    }
    late final Future<void> task;
    task =
        _initializeLocalState(
          defaultLanguage: defaultLanguage,
          restoreAccountSession: restoreAccountSession,
        ).whenComplete(() {
          if (identical(_initializeTask, task)) {
            _initializeTask = null;
          }
        });
    _initializeTask = task;
    return task;
  }

  Future<void> _initializeLocalState({
    AsmrContentLanguage? defaultLanguage,
    required bool restoreAccountSession,
  }) async {
    final visibleCategories = await _preferencesStore.loadVisibleCategories();
    if (_disposed) return;
    _visibleCategories = visibleCategories;
    if (defaultLanguage != null) {
      _pageLanguage = defaultLanguage.appLanguage;
    }
    final contentLanguagePreference = await _preferencesStore
        .loadContentLanguagePreference();
    if (_disposed) return;
    _contentLanguagePreference = contentLanguagePreference;
    _contentLanguage = _resolveContentLanguage();
    final accountSnapshot = await _accountSyncService.initialize();
    if (_disposed) return;
    _applyAccountSnapshot(accountSnapshot);
    final tagPreferences = await _preferencesStore.loadTagPreferences();
    if (_disposed) return;
    _tagPreferences = tagPreferences;
    _voiceActorPreferences = await _preferencesStore
        .loadVoiceActorPreferences();
    if (_disposed) return;
    _circlePreferences = await _preferencesStore.loadCirclePreferences();
    if (_disposed) return;
    _catalog.updateLocalCounts();
    _initialized = true;
    _bumpGlobalRevision();
    notifyListeners();
    if (restoreAccountSession) {
      unawaited(restoreAsmrAccountSession());
    }
  }

  Future<void> restoreAsmrAccountSession({bool force = false}) {
    if (!force && _authSession != null) {
      return Future<void>.value();
    }
    final existing = _authRestoreTask;
    if (!force && existing != null) {
      return existing;
    }
    late final Future<void> task;
    task = _restoreAsmrAccountSessionInternal().whenComplete(() {
      if (identical(_authRestoreTask, task)) {
        _authRestoreTask = null;
        _bumpGlobalRevision();
        notifyListeners();
      }
    });
    _authRestoreTask = task;
    _bumpGlobalRevision();
    notifyListeners();
    return task;
  }

  Future<void> _restoreAsmrAccountSessionInternal() async {
    final requestEpoch = _authEpoch;
    final previousSession = _authSession;
    try {
      final snapshot = await _accountSyncService.restoreSession();
      if (requestEpoch != _authEpoch) return;
      final restored = snapshot.session;
      if (previousSession?.token == restored?.token &&
          previousSession?.userName == restored?.userName) {
        return;
      }
      _authEpoch++;
      _cancelActiveSync();
      _catalog.invalidateForAuthChange();
      _invalidateRemoteWorkCaches();
      _applyAccountSnapshot(snapshot);
      _lastSyncError = null;
      _bumpGlobalRevision();
      notifyListeners();
      _refreshLoadedCategoriesForCurrentAuth();
    } catch (error) {
      if (requestEpoch != _authEpoch) return;
      _lastSyncError = error;
      _bumpGlobalRevision();
      notifyListeners();
    }
  }

  @override
  Future<void> reloadPersistedState() async {
    _invalidateSearchSuggestions();
    _creatorCatalogTasks.clear();
    _creatorCatalogErrors.clear();
    _initialized = false;
    _tagInterestsReady = false;
    _tagInterestsTask = null;
    _runtimeCacheEpoch++;
    _contentEpoch++;
    _catalog.clearWorks();
    _workContent.clearCaches(clearErrors: true);
    // Let an already-started preference write finish before reloading it.
    await _stateMutationTail;
    await initialize();
    await restoreAsmrAccountSession();
  }

  Future<void> loginAsmrAccount(String name, String password) async {
    var operationEpoch = ++_authEpoch;
    _cancelActiveSync();
    _catalog.invalidateForAuthChange();
    _invalidateRemoteWorkCaches();
    _authSession = null;
    _syncPhase = AsmrSyncPhase.syncing;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    try {
      final snapshot = await _accountSyncService.login(name, password);
      if (operationEpoch != _authEpoch) return;
      operationEpoch = ++_authEpoch;
      _catalog.invalidateForAuthChange();
      _invalidateRemoteWorkCaches();
      _applyAccountSnapshot(snapshot);
      await syncAsmrAccount(force: true);
      _refreshLoadedCategoriesForCurrentAuth();
    } catch (error) {
      if (operationEpoch != _authEpoch) return;
      _authSession = null;
      _syncPhase = AsmrSyncPhase.failed;
      _lastSyncError = error;
      _bumpGlobalRevision();
      notifyListeners();
      _refreshLoadedCategoriesForCurrentAuth();
      rethrow;
    }
  }

  Future<void> logoutAsmrAccount() async {
    final previousSession = _authSession;
    final logoutEpoch = ++_authEpoch;
    _authSession = null;
    _cancelActiveSync();
    _catalog.invalidateForAuthChange();
    _invalidateRemoteWorkCaches();
    final AsmrAccountSnapshot snapshot;
    try {
      snapshot = await _accountSyncService.logout();
    } catch (_) {
      if (logoutEpoch == _authEpoch) {
        _authSession = previousSession;
        _authEpoch++;
        _catalog.invalidateForAuthChange();
        _invalidateRemoteWorkCaches();
      }
      rethrow;
    }
    if (logoutEpoch != _authEpoch) return;
    _applyAccountSnapshot(snapshot);
    _syncPhase = AsmrSyncPhase.idle;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    _refreshLoadedCategoriesForCurrentAuth();
  }

  Future<void> syncAsmrAccount({bool force = false}) {
    final session = _authSession;
    if (session == null || !session.isValid) return Future<void>.value();
    final key = (authEpoch: _authEpoch, token: session.token);
    final existing = _syncTasks[key];
    if (existing != null) {
      return existing;
    }
    late final Future<void> task;
    task = _syncAsmrAccountInternal(key)
        .then<void>((completedKey) async {
          if (!identical(_syncTasks[key], task)) return;
          unawaited(_syncTasks.remove(key));
          // Mutations can arrive after the batch drained, during the last sync
          // timestamp write. Token recovery can also change the completed key.
          if (!_disposed &&
              completedKey != null &&
              completedKey.authEpoch == _authEpoch &&
              completedKey.token == _authSession?.token &&
              _accountSyncService.snapshot.pendingOperations.isNotEmpty) {
            await syncAsmrAccount();
          }
        })
        .whenComplete(() {
          if (identical(_syncTasks[key], task)) {
            unawaited(_syncTasks.remove(key));
          }
        });
    _syncTasks[key] = task;
    return task;
  }

  Future<_AsmrSyncRequestKey?> _syncAsmrAccountInternal(
    _AsmrSyncRequestKey key,
  ) async {
    if (key.authEpoch != _authEpoch || key.token != _authSession?.token) {
      return null;
    }
    final cancellationToken = AsmrRequestCancellationToken();
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = cancellationToken;
    _syncPhase = AsmrSyncPhase.syncing;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    var tokenChanged = false;
    try {
      final result = await _accountSyncService.synchronize(
        language: _contentLanguage,
        cancellationToken: cancellationToken,
      );
      if (cancellationToken.isCancelled || key.authEpoch != _authEpoch) {
        return null;
      }
      final previousToken = _authSession?.token;
      _applyAccountSnapshot(result.snapshot);
      tokenChanged = _authSession?.token != previousToken;
      if (tokenChanged) {
        _authEpoch++;
        _catalog.invalidateForAuthChange();
        _invalidateRemoteWorkCaches();
      }
      _syncPhase = result.succeeded
          ? AsmrSyncPhase.succeeded
          : AsmrSyncPhase.failed;
      _lastSyncError = result.failure;
      final session = _authSession;
      return result.succeeded && session != null
          ? (authEpoch: _authEpoch, token: session.token)
          : null;
    } on AsmrRequestCancelled {
      return null;
    } catch (error) {
      if (_disposed ||
          cancellationToken.isCancelled ||
          key.authEpoch != _authEpoch ||
          !identical(_activeSyncCancellationToken, cancellationToken)) {
        return null;
      }
      _syncPhase = AsmrSyncPhase.failed;
      _lastSyncError = error;
    } finally {
      if (identical(_activeSyncCancellationToken, cancellationToken)) {
        _activeSyncCancellationToken = null;
        _catalog.updateLocalCounts();
        _catalog.bumpRevision(AsmrCategoryType.favorites);
        _catalog.bumpRevision(AsmrCategoryType.history);
        _bumpGlobalRevision();
        notifyListeners();
        if (tokenChanged) {
          _refreshLoadedCategoriesForCurrentAuth();
        }
      }
    }
    return null;
  }

  Future<void> refreshCategoryWithSync(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    if (_catalog.errorFor(category) != null) {
      _catalog.setOperationError(category, null);
    }
    if (isAsmrAccountLoggedIn) {
      await syncAsmrAccount(force: true);
      if (_syncPhase == AsmrSyncPhase.failed) {
        _catalog.setOperationError(category, _lastSyncError);
        return;
      }
    }
    await refreshCategory(category, searchQuery: searchQuery);
  }

  Future<void> setVisibleCategories(List<AsmrCategoryType> categories) async {
    final next = _sanitizeVisibleCategories(categories);
    if (listEquals(next, _visibleCategories)) {
      return;
    }
    _visibleCategories = next;
    await _preferencesStore.saveVisibleCategories(next);
    _bumpGlobalRevision();
    notifyListeners();
  }

  bool setPageLanguage(AppLanguage language) {
    if (_pageLanguage == language) return false;
    _pageLanguage = language;
    if (!_initialized ||
        _contentLanguagePreference != ContentLanguagePreference.followPage) {
      return false;
    }
    final nextLanguage = _resolveContentLanguage();
    if (_contentLanguage == nextLanguage) return false;
    _applyContentLanguage(nextLanguage);
    return true;
  }

  Future<void> setContentLanguage(AsmrContentLanguage language) {
    return setContentLanguagePreference(
      ContentLanguagePreference.fromAppLanguage(language.appLanguage),
    );
  }

  Future<void> setContentLanguagePreference(
    ContentLanguagePreference preference,
  ) async {
    if (_contentLanguagePreference == preference) {
      return;
    }
    final refreshQueries = _catalog.loadedRemoteQueries;
    _contentLanguagePreference = preference;
    await _preferencesStore.saveContentLanguagePreference(preference);
    final nextLanguage = _resolveContentLanguage();
    if (_contentLanguage == nextLanguage) {
      _bumpGlobalRevision();
      notifyListeners();
      return;
    }
    _applyContentLanguage(nextLanguage);
    await Future.wait(
      refreshQueries.entries.map(
        (entry) => ensureCategoryLoaded(entry.key, searchQuery: entry.value),
      ),
    );
  }

  AsmrContentLanguage _resolveContentLanguage() {
    return AsmrContentLanguage.fromAppLanguage(
      _contentLanguagePreference.resolve(_pageLanguage),
    );
  }

  void _applyContentLanguage(AsmrContentLanguage language) {
    _contentLanguage = language;
    _contentEpoch++;
    _catalog.invalidateForContentChange();
    _workContent.clearCaches();
    _workContent.bumpAllTrackRevisions();
    _bumpGlobalRevision();
    notifyListeners();
  }

  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    if (searchSession) setSearchQuery(searchQuery, category);
    final searchEpoch = _catalog.searchEpoch;
    final authEpoch = _authEpoch;
    final contentEpoch = _contentEpoch;
    await initializeForVisiblePage();
    if (_disposed ||
        authEpoch != _authEpoch ||
        contentEpoch != _contentEpoch ||
        (searchSession &&
            (searchEpoch != _catalog.searchEpoch ||
                !_catalog.isSearchRequestCurrent(searchQuery, category)))) {
      return;
    }
    final pending = _catalog.pendingRefresh(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
    );
    if (pending != null) {
      await pending;
      return;
    }
    if (_catalog.hasAttemptedLoad(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
    )) {
      return;
    }
    await _catalog.refresh(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
      context: _categoryRequestContext,
    );
  }

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    if (searchSession) setSearchQuery(searchQuery, category);
    final searchEpoch = _catalog.searchEpoch;
    final authEpoch = _authEpoch;
    final contentEpoch = _contentEpoch;
    await initialize();
    if (_disposed ||
        authEpoch != _authEpoch ||
        contentEpoch != _contentEpoch ||
        (searchSession &&
            (searchEpoch != _catalog.searchEpoch ||
                !_catalog.isSearchRequestCurrent(searchQuery, category)))) {
      return;
    }
    await _catalog.refresh(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
      context: _categoryRequestContext,
    );
  }

  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    if (searchSession) setSearchQuery(searchQuery, category);
    final searchEpoch = _catalog.searchEpoch;
    final authEpoch = _authEpoch;
    final contentEpoch = _contentEpoch;
    await initialize();
    if (_disposed ||
        authEpoch != _authEpoch ||
        contentEpoch != _contentEpoch ||
        (searchSession &&
            (searchEpoch != _catalog.searchEpoch ||
                !_catalog.isSearchRequestCurrent(searchQuery, category)))) {
      return;
    }
    await _catalog.loadMore(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
      context: _categoryRequestContext,
    );
  }

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    await initializeForVisiblePage();
    final key = _workRequestKey(work.workKey);
    if (_disposed) throw StateError('asmr_content_invalidated');
    final tree = await ensureTrackTree(work);
    if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
      throw StateError('asmr_content_invalidated');
    }
    if (!_isWorkRequestCurrent(key) ||
        !identical(tree, _workContent.cachedTrackTree(work.workKey))) {
      return loadPlayableTracks(work);
    }
    final cached = _workContent.cachedPlayableTracks(work);
    if (cached != null) return cached;
    return _workContent.requestPlayableTracks(
      key,
      work,
      tree,
      () => _loadPlayableTracksOnce(work, tree, key),
    );
  }

  Future<List<MusicTrack>> _loadPlayableTracksOnce(
    AsmrWork work,
    List<AsmrTrackFile> tree,
    AsmrWorkRequestKey key,
  ) async {
    final tracks = await compute(_buildPlayableTracks, (
      work: work,
      tree: tree,
    ), debugLabel: 'asmr_playable_tracks');
    if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
      throw StateError('asmr_content_invalidated');
    }
    // Conversion can outlive an account/language change or a tree refresh.
    if (!_isWorkRequestCurrent(key) ||
        !identical(tree, _workContent.cachedTrackTree(work.workKey))) {
      return loadPlayableTracks(work);
    }
    return _workContent.storePlayableTracks(work, tracks);
  }

  Future<List<WorkTextFile>> findWorkTextFiles(
    AsmrWork work, {
    AsmrDownloadManager? downloadManager,
  }) async {
    final tree = await ensureTrackTree(work);
    return collectAsmrWorkTextFiles(
      tree,
      downloadManager: downloadManager,
      workKey: work.workKey,
    );
  }

  List<MusicTrack> buildPlayableTracksFromNode(
    AsmrWork work,
    AsmrTrackFile node,
  ) {
    if (node.isFolder) {
      return flattenAsmrPlayableTracks(work, <AsmrTrackFile>[node]);
    }
    return flattenAsmrPlayableTracks(
      work,
      _workContent.cachedTrackTree(work.workKey) ?? <AsmrTrackFile>[node],
      includeAudioNode: (candidate) => candidate.stableKey == node.stableKey,
    );
  }

  @override
  Future<List<MusicTrack>> loadPlayableTracksStartingAt(
    AsmrWork work,
    AsmrTrackFile target,
  ) async {
    final tracks = await loadPlayableTracks(work);
    final targetIndex = tracks.indexWhere(
      (track) =>
          track.remoteMetadata?['trackRelativePath'] == target.relativePath,
    );
    if (targetIndex < 0) {
      final targetTrackPath = target.toMusicTrack().path;
      final fallbackIndex = tracks.indexWhere(
        (track) => track.path == targetTrackPath,
      );
      if (fallbackIndex < 0) return const <MusicTrack>[];
      if (fallbackIndex == 0) return tracks;
      return <MusicTrack>[
        ...tracks.skip(fallbackIndex),
        ...tracks.take(fallbackIndex),
      ];
    }
    if (targetIndex == 0) return tracks;
    return <MusicTrack>[
      ...tracks.skip(targetIndex),
      ...tracks.take(targetIndex),
    ];
  }

  Future<List<AsmrTrackFile>> ensureTrackTree(
    AsmrWork work, {
    bool forceRefresh = false,
  }) {
    final cached = _workContent.cachedTrackTree(work.workKey);
    if (!forceRefresh && cached != null) {
      return SynchronousFuture<List<AsmrTrackFile>>(cached);
    }
    final key = _workRequestKey(work.workKey);
    return _workContent.requestTrackTree(
      key,
      (cancellationToken) => _loadTrackTreeOnce(work, key, cancellationToken),
    );
  }

  Future<List<AsmrTrackFile>> _loadTrackTreeOnce(
    AsmrWork work,
    AsmrWorkRequestKey key,
    AsmrRequestCancellationToken cancellationToken,
  ) async {
    try {
      final tree = await cancellationToken.waitFor(
        _remoteCatalogService.loadTrackTree(
          work,
          token: _authSession?.token,
          cancellationToken: cancellationToken,
        ),
      );
      if (_isWorkRequestCurrent(key)) {
        final sortedTree = await compute(sortAsmrTrackTreeNaturally, tree);
        // Account, language or cache invalidation can occur during sorting.
        if (_isWorkRequestCurrent(key)) {
          _workContent.clearTrackTreeError(work.workKey);
          final storedTree = _workContent.storeTrackTree(
            work.workKey,
            sortedTree,
          );
          _workContent.bumpTrackRevision(work.workKey);
          return storedTree;
        }
      }
      if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
        throw StateError('asmr_content_invalidated');
      }
      return ensureTrackTree(work);
    } on AsmrRequestCancelled {
      if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
        throw StateError('asmr_content_invalidated');
      }
      if (_isWorkRequestCurrent(key)) rethrow;
      return ensureTrackTree(work);
    } catch (error) {
      if (_isWorkRequestCurrent(key)) {
        _workContent.setTrackTreeError(work.workKey, error);
        _workContent.bumpTrackRevision(work.workKey);
      }
      rethrow;
    }
  }

  Future<void> toggleFavorite(AsmrWork work) {
    return _runStateMutation(() => _mutateFavoritesNow([work]));
  }

  Future<void> setFavorites(List<AsmrWork> works, {required bool favorite}) =>
      _runStateMutation(() => _mutateFavoritesNow(works, favorite: favorite));

  Future<void> _mutateFavoritesNow(
    List<AsmrWork> works, {
    bool? favorite,
  }) async {
    final mutationAuthEpoch = _authEpoch;
    final previous = _accountSyncService.snapshot;
    final snapshot = favorite == null
        ? await _accountSyncService.toggleFavorite(works.single)
        : await _accountSyncService.setFavorites(works, favorite: favorite);
    if (mutationAuthEpoch != _authEpoch) return;
    if (identical(previous, snapshot)) return;
    final previousIds = _favoriteIds;
    _applyAccountSnapshot(snapshot);
    final changedIds = {
      for (final work in works)
        if (previousIds.contains(work.workKey) !=
            _favoriteIds.contains(work.workKey))
          work.workKey: _favoriteIds.contains(work.workKey),
    };
    _catalog.updateFavorites(changedIds);
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _catalog.updateLocalCounts();
    _catalog.bumpRevision(AsmrCategoryType.favorites);
    _catalog.bumpRevision(AsmrCategoryType.history);
    notifyListeners();
  }

  @override
  Future<void> recordHistory(AsmrWork work) {
    return _runStateMutation(() => _recordHistoryNow(work));
  }

  Future<void> _recordHistoryNow(AsmrWork work) async {
    final mutationAuthEpoch = _authEpoch;
    final snapshot = await _accountSyncService.recordHistory(work);
    if (mutationAuthEpoch != _authEpoch) return;
    _applyAccountSnapshot(snapshot);
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _catalog.updateLocalCounts();
    _catalog.bumpRevision(AsmrCategoryType.history);
    notifyListeners();
  }

  void _bumpGlobalRevision() {
    _globalRevision++;
  }

  static List<AsmrCategoryType> _sanitizeVisibleCategories(
    List<AsmrCategoryType> categories,
  ) {
    final result = <AsmrCategoryType>[];
    for (final category in categories) {
      if (!kAsmrSelectableCategories.contains(category) ||
          result.contains(category)) {
        continue;
      }
      result.add(category);
      if (result.length == 5) {
        break;
      }
    }
    return result.isEmpty
        ? kDefaultVisibleAsmrCategories
        : result.toList(growable: false);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _searchSuggestionsCancellation?.cancel();
    _disposed = true;
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = null;
    _authEpoch++;
    _contentEpoch++;
    _catalog.cancelRequests();
    _workContent.cancelRequests();
    super.dispose();
  }
}
