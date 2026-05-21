import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import 'audio_database_repository.dart';
import 'asmr_api_service.dart';
import 'asmr_preferences.dart';
import 'asmr_recommendation_engine.dart';
import 'search_query_utils.dart';

class AsmrLibraryController extends ChangeNotifier {
  AsmrLibraryController({
    AsmrApiService? apiService,
    AudioDatabaseRepository? audioDatabaseRepository,
    AsmrRecommendationEngine recommendationEngine =
        const AsmrRecommendationEngine(),
  }) : _apiService = apiService ?? AsmrApiService(),
       _audioDatabaseRepository =
           audioDatabaseRepository ?? AudioDatabaseRepository(),
       _recommendationEngine = recommendationEngine;

  static const int _historyLimit = 60;
  static const Map<AsmrCategoryType, int> _pageSizes = <AsmrCategoryType, int>{
    AsmrCategoryType.collected: 40,
    AsmrCategoryType.recommendation: 40,
    AsmrCategoryType.sales: 40,
    AsmrCategoryType.rating: 40,
    AsmrCategoryType.release: 40,
    AsmrCategoryType.favorites: 60,
    AsmrCategoryType.history: 60,
  };
  static const List<AsmrCategoryType> _recommendationCandidateCategories =
      <AsmrCategoryType>[
        AsmrCategoryType.collected,
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
      ];
  static const int _recommendationCandidatePageLimit = 2;

  final AsmrApiService _apiService;
  final AudioDatabaseRepository _audioDatabaseRepository;
  final AsmrRecommendationEngine _recommendationEngine;
  final Map<AsmrCategoryType, Future<void>> _refreshTasks =
      <AsmrCategoryType, Future<void>>{};
  final Map<AsmrCategoryType, String> _refreshTaskQueries =
      <AsmrCategoryType, String>{};
  final Map<AsmrCategoryType, int> _refreshRequestSerial =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, List<AsmrWork>> _worksByCategory =
      <AsmrCategoryType, List<AsmrWork>>{};
  final Map<AsmrCategoryType, bool> _loadingByCategory =
      <AsmrCategoryType, bool>{};
  final Map<AsmrCategoryType, bool> _loadingMoreByCategory =
      <AsmrCategoryType, bool>{};
  final Map<AsmrCategoryType, int> _currentPageByCategory =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, int> _totalCountByCategory =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, bool> _hasMoreByCategory =
      <AsmrCategoryType, bool>{};
  final Map<AsmrCategoryType, String> _queryByCategory =
      <AsmrCategoryType, String>{};
  final Map<int, AsmrWork> _workCache = <int, AsmrWork>{};
  final Map<int, AsmrWorkDetail> _detailCache = <int, AsmrWorkDetail>{};
  final Map<int, List<AsmrTrackFile>> _trackCache =
      <int, List<AsmrTrackFile>>{};
  final Set<int> _loadingTrackWorkIds = <int>{};

  AsmrAuthSession _authSession = const AsmrAuthSession();
  List<AsmrCategoryType> _visibleCategories = kDefaultVisibleAsmrCategories;
  AsmrContentLanguage _contentLanguage = AsmrContentLanguage.zh;
  List<AsmrWork> _favoriteWorks = const <AsmrWork>[];
  List<AsmrWork> _historyWorks = const <AsmrWork>[];
  bool _initialized = false;
  Object? _lastError;

  bool get initialized => _initialized;
  Object? get lastError => _lastError;
  AsmrAuthSession get authSession => _authSession;
  List<AsmrCategoryType> get visibleCategories => _visibleCategories;
  AsmrContentLanguage get contentLanguage => _contentLanguage;

  bool isLoadingCategory(AsmrCategoryType category) =>
      _loadingByCategory[category] ?? false;
  bool isLoadingMoreCategory(AsmrCategoryType category) =>
      _loadingMoreByCategory[category] ?? false;
  bool hasMoreCategory(AsmrCategoryType category) =>
      _hasMoreByCategory[category] ?? false;
  int totalCountFor(AsmrCategoryType category) =>
      _totalCountByCategory[category] ?? worksFor(category).length;
  String activeQueryFor(AsmrCategoryType category) =>
      _queryByCategory[category] ?? '';
  bool isTrackTreeLoading(int workId) => _loadingTrackWorkIds.contains(workId);
  List<AsmrTrackFile>? trackTreeFor(int workId) => _trackCache[workId];

  List<AsmrWork> worksFor(AsmrCategoryType category) {
    switch (category) {
      case AsmrCategoryType.favorites:
        return _favoriteWorks;
      case AsmrCategoryType.history:
        return _historyWorks;
      default:
        return _worksByCategory[category] ?? const <AsmrWork>[];
    }
  }

  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final works = worksFor(category);
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (normalizedQuery.isEmpty) {
      return works;
    }
    if (category != AsmrCategoryType.favorites &&
        category != AsmrCategoryType.history) {
      return works;
    }
    return works
        .where((work) => _matchesQuery(work, searchQuery))
        .toList(growable: false);
  }

  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {
    if (_initialized) return;
    _authSession = await AsmrPreferences.loadAuthSession();
    _visibleCategories = await AsmrPreferences.loadVisibleCategories();
    _contentLanguage = await AsmrPreferences.loadContentLanguage(
      defaultLanguage ?? AsmrContentLanguage.zh,
    );
    _favoriteWorks = await AsmrPreferences.loadFavoriteWorks();
    _historyWorks = await AsmrPreferences.loadHistoryWorks();
    for (final work in _favoriteWorks.followedBy(_historyWorks)) {
      _workCache[work.id] = work;
    }
    _updateLocalCategoryCounts();
    _initialized = true;
    notifyListeners();
    if (_authSession.isLoggedIn) {
      await syncAuthSession();
    }
  }

  Future<void> syncAuthSession() async {
    final token = _authSession.token;
    if (token == null || token.isEmpty) return;
    try {
      final synced = await _apiService.fetchAuthSession(token);
      final favoritePlaylistId = await _fetchFavoritePlaylistId(token);
      _authSession = synced.copyWith(favoritePlaylistId: favoritePlaylistId);
      await AsmrPreferences.saveAuthSession(_authSession);
      if (favoritePlaylistId != null) {
        await _syncFavoriteWorksFromRemoteIfAvailable(
          token: token,
          playlistId: favoritePlaylistId,
        );
      }
      notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
    }
  }

  Future<void> login({required String name, required String password}) async {
    final loggedIn = await _apiService.login(name: name, password: password);
    final favoritePlaylistId = loggedIn.token?.isNotEmpty == true
        ? await _fetchFavoritePlaylistId(loggedIn.token!)
        : null;
    _authSession = loggedIn.copyWith(favoritePlaylistId: favoritePlaylistId);
    await AsmrPreferences.saveAuthSession(_authSession);
    if (_authSession.token != null && favoritePlaylistId != null) {
      await _syncFavoriteWorksFromRemoteIfAvailable(
        token: _authSession.token!,
        playlistId: favoritePlaylistId,
      );
    }
    _worksByCategory.remove(AsmrCategoryType.recommendation);
    _lastError = null;
    notifyListeners();
  }

  Future<void> logout() async {
    _authSession = const AsmrAuthSession();
    await AsmrPreferences.saveAuthSession(_authSession);
    _worksByCategory.remove(AsmrCategoryType.recommendation);
    _applyFavoriteFlags();
    notifyListeners();
  }

  Future<void> setVisibleCategories(List<AsmrCategoryType> categories) async {
    final next = _sanitizeVisibleCategories(categories);
    if (listEquals(next, _visibleCategories)) {
      return;
    }
    _visibleCategories = next;
    await AsmrPreferences.saveVisibleCategories(next);
    notifyListeners();
  }

  Future<void> setContentLanguage(AsmrContentLanguage language) async {
    if (_contentLanguage == language) {
      return;
    }
    _contentLanguage = language;
    await AsmrPreferences.saveContentLanguage(language);
    _worksByCategory.clear();
    _detailCache.clear();
    _trackCache.clear();
    _queryByCategory.removeWhere(
      (category, _) =>
          category != AsmrCategoryType.favorites &&
          category != AsmrCategoryType.history,
    );
    if (_authSession.isLoggedIn &&
        _authSession.token != null &&
        _authSession.favoritePlaylistId != null) {
      await _syncFavoriteWorksFromRemote(
        token: _authSession.token!,
        playlistId: _authSession.favoritePlaylistId!,
      );
    }
    notifyListeners();
  }

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final existing = _refreshTasks[category];
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (existing != null && _refreshTaskQueries[category] == normalizedQuery) {
      return existing;
    }
    final requestId = (_refreshRequestSerial[category] ?? 0) + 1;
    _refreshRequestSerial[category] = requestId;
    late final Future<void> task;
    task =
        _refreshCategoryInternal(
          category,
          searchQuery: normalizedQuery,
          requestId: requestId,
        ).whenComplete(() {
          if (identical(_refreshTasks[category], task)) {
            _refreshTasks.remove(category);
            _refreshTaskQueries.remove(category);
          }
        });
    _refreshTasks[category] = task;
    _refreshTaskQueries[category] = normalizedQuery;
    return task;
  }

  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (category == AsmrCategoryType.favorites ||
        category == AsmrCategoryType.history ||
        category == AsmrCategoryType.recommendation) {
      return;
    }
    if (isLoadingCategory(category) || isLoadingMoreCategory(category)) {
      return;
    }
    final existingQuery = _queryByCategory[category] ?? '';
    if (existingQuery != normalizedQuery) {
      await refreshCategory(category, searchQuery: normalizedQuery);
      return;
    }
    if (!hasMoreCategory(category)) {
      return;
    }

    _loadingMoreByCategory[category] = true;
    notifyListeners();
    try {
      final requestId = _refreshRequestSerial[category] ?? 0;
      final page = (_currentPageByCategory[category] ?? 1) + 1;
      final pageResult = await _loadRemotePage(
        category,
        searchQuery: normalizedQuery,
        page: page,
      );
      if (_refreshRequestSerial[category] != requestId) {
        return;
      }
      final existingIds = (_worksByCategory[category] ?? const <AsmrWork>[])
          .map((work) => work.id)
          .toSet();
      final merged = <AsmrWork>[
        ...?_worksByCategory[category],
        ...pageResult.works.where((work) => existingIds.add(work.id)),
      ];
      _worksByCategory[category] = merged
          .map(_decorateWork)
          .toList(growable: false);
      _applyPageResult(
        category,
        query: normalizedQuery,
        pageResult: pageResult,
      );
      for (final work in _worksByCategory[category]!) {
        _workCache[work.id] = work;
      }
    } catch (error) {
      _lastError = error;
    } finally {
      _loadingMoreByCategory[category] = false;
      notifyListeners();
    }
  }

  Future<void> _refreshCategoryInternal(
    AsmrCategoryType category, {
    required String searchQuery,
    required int requestId,
  }) async {
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    _loadingByCategory[category] = true;
    _lastError = null;
    notifyListeners();
    try {
      switch (category) {
        case AsmrCategoryType.collected:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.recommendation:
          await _loadRecommendedWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.sales:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.rating:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.release:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.favorites:
          final token = _authSession.token;
          final playlistId = _authSession.favoritePlaylistId;
          if (token != null && token.isNotEmpty && playlistId != null) {
            await _syncFavoriteWorksFromRemote(
              token: token,
              playlistId: playlistId,
            );
          }
          _queryByCategory[category] = normalizedQuery;
          _totalCountByCategory[category] = filteredWorksFor(
            category,
            searchQuery: normalizedQuery,
          ).length;
          _hasMoreByCategory[category] = false;
          break;
        case AsmrCategoryType.history:
          _queryByCategory[category] = normalizedQuery;
          _totalCountByCategory[category] = filteredWorksFor(
            category,
            searchQuery: normalizedQuery,
          ).length;
          _hasMoreByCategory[category] = false;
          break;
      }
    } catch (error) {
      _lastError = error;
    } finally {
      if (_refreshRequestSerial[category] == requestId) {
        _loadingByCategory[category] = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadWorks(
    AsmrCategoryType category, {
    required String searchQuery,
    required int requestId,
  }) async {
    final pageResult = await _loadRemotePage(
      category,
      searchQuery: searchQuery,
      page: 1,
    );
    if (_refreshRequestSerial[category] != requestId) {
      return;
    }
    _worksByCategory[category] = pageResult.works
        .map(_decorateWork)
        .toList(growable: false);
    _applyPageResult(category, query: searchQuery, pageResult: pageResult);
    for (final work in _worksByCategory[category]!) {
      _workCache[work.id] = work;
    }
  }

  Future<void> _loadRecommendedWorks(
    AsmrCategoryType category, {
    required String searchQuery,
    required int requestId,
  }) async {
    final pageSize = _pageSizes[category] ?? 40;
    final pageGroups = await Future.wait(<Future<List<AsmrWorkPage>>>[
      for (final sourceCategory in _recommendationCandidateCategories)
        _loadRecommendationCandidatePages(
          sourceCategory,
          searchQuery: searchQuery,
        ),
    ]);
    if (_refreshRequestSerial[category] != requestId) {
      return;
    }
    final candidatesById = <int, AsmrWork>{};
    for (final page in pageGroups.expand((group) => group)) {
      for (final work in page.works) {
        candidatesById.putIfAbsent(work.id, () => work);
      }
    }
    final localTracks = await _loadLocalTracksForRecommendation();
    if (_refreshRequestSerial[category] != requestId) {
      return;
    }
    final ranked = _recommendationEngine.rank(
      candidates: candidatesById.values.map(_decorateWork).toList(),
      localTracks: localTracks,
      favoriteWorks: _favoriteWorks,
      historyWorks: _historyWorks,
      refreshSeed: requestId,
      limit: pageSize,
    );
    _worksByCategory[category] = ranked;
    _applyPageResult(
      category,
      query: searchQuery,
      pageResult: AsmrWorkPage(
        works: ranked,
        currentPage: 1,
        pageSize: ranked.length,
        totalCount: ranked.length,
      ),
    );
    _hasMoreByCategory[category] = false;
    for (final work in ranked) {
      _workCache[work.id] = work;
    }
  }

  Future<List<AsmrWorkPage>> _loadRecommendationCandidatePages(
    AsmrCategoryType category, {
    required String searchQuery,
  }) async {
    final pages = <AsmrWorkPage>[];
    var page = await _loadRemotePage(
      category,
      searchQuery: searchQuery,
      page: 1,
    );
    pages.add(page);
    while (page.hasMore && pages.length < _recommendationCandidatePageLimit) {
      page = await _loadRemotePage(
        category,
        searchQuery: searchQuery,
        page: pages.length + 1,
      );
      pages.add(page);
    }
    return pages;
  }

  Future<List<MusicTrack>> _loadLocalTracksForRecommendation() async {
    try {
      return await _audioDatabaseRepository.loadAllTracks();
    } catch (error) {
      debugPrint(
        'AsmrLibraryController recommendation local load error: $error',
      );
      return const <MusicTrack>[];
    }
  }

  Future<AsmrWorkPage> _loadRemotePage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
  }) {
    final spec = _sortSpecFor(category);
    final pageSize = _pageSizes[category] ?? 40;
    if (searchQuery.isNotEmpty) {
      return _apiService.searchWorks(
        keyword: searchQuery,
        order: spec.order,
        sort: spec.sort,
        page: page,
        pageSize: pageSize,
        token: _authSession.token,
        language: _contentLanguage,
      );
    }
    return _apiService.fetchWorks(
      order: spec.order,
      sort: spec.sort,
      page: page,
      pageSize: pageSize,
      token: _authSession.token,
      language: _contentLanguage,
    );
  }

  ({String order, String sort}) _sortSpecFor(AsmrCategoryType category) {
    switch (category) {
      case AsmrCategoryType.collected:
        return (order: 'create_date', sort: 'desc');
      case AsmrCategoryType.recommendation:
        return (order: 'create_date', sort: 'desc');
      case AsmrCategoryType.sales:
        return (order: 'dl_count', sort: 'desc');
      case AsmrCategoryType.rating:
        return (order: 'rate_average_2dp', sort: 'desc');
      case AsmrCategoryType.release:
        return (order: 'release', sort: 'desc');
      case AsmrCategoryType.favorites:
      case AsmrCategoryType.history:
        return (order: 'release', sort: 'desc');
    }
  }

  void _applyPageResult(
    AsmrCategoryType category, {
    required String query,
    required AsmrWorkPage pageResult,
  }) {
    _queryByCategory[category] = query;
    _currentPageByCategory[category] = pageResult.currentPage;
    _totalCountByCategory[category] = pageResult.totalCount;
    _hasMoreByCategory[category] = pageResult.hasMore;
  }

  AsmrWork _decorateWork(AsmrWork work) {
    final favoriteIds = _favoriteWorks.map((item) => item.id).toSet();
    return work.copyWith(isFavorite: favoriteIds.contains(work.id));
  }

  Future<void> _syncFavoriteWorksFromRemote({
    required String token,
    required int playlistId,
  }) async {
    final remoteWorks = await _apiService.fetchFavoriteWorks(
      token: token,
      playlistId: playlistId,
      language: _contentLanguage,
    );
    final decorated = remoteWorks
        .map((work) => work.copyWith(isFavorite: true))
        .toList(growable: false);
    _favoriteWorks = decorated;
    for (final work in decorated.followedBy(_historyWorks)) {
      _workCache[work.id] = work;
    }
    _applyFavoriteFlags();
    _updateLocalCategoryCounts();
    await AsmrPreferences.saveFavoriteWorks(_favoriteWorks);
  }

  Future<int?> _fetchFavoritePlaylistId(String token) async {
    try {
      final playlistId = await _apiService.fetchFavoritePlaylistId(token);
      _lastError = null;
      return playlistId;
    } catch (error) {
      _lastError = error;
      return null;
    }
  }

  Future<void> _syncFavoriteWorksFromRemoteIfAvailable({
    required String token,
    required int playlistId,
  }) async {
    try {
      await _syncFavoriteWorksFromRemote(token: token, playlistId: playlistId);
      _lastError = null;
    } catch (error) {
      _lastError = error;
    }
  }

  void _applyFavoriteFlags() {
    final favoriteIds = _favoriteWorks.map((work) => work.id).toSet();
    for (final entry in _worksByCategory.entries) {
      _worksByCategory[entry.key] = entry.value
          .map(
            (work) => work.copyWith(isFavorite: favoriteIds.contains(work.id)),
          )
          .toList(growable: false);
    }
    _historyWorks = _historyWorks
        .map((work) => work.copyWith(isFavorite: favoriteIds.contains(work.id)))
        .toList(growable: false);
    _detailCache.updateAll(
      (_, detail) => AsmrWorkDetail(
        work: detail.work.copyWith(
          isFavorite: favoriteIds.contains(detail.work.id),
        ),
        description: detail.description,
        ageCategory: detail.ageCategory,
        languageEditionLabels: detail.languageEditionLabels,
        userRating: detail.userRating,
      ),
    );
  }

  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) async {
    final cached = _detailCache[work.id];
    if (cached != null) {
      return cached;
    }
    final detail = await _apiService.fetchWorkDetail(
      work.id,
      token: _authSession.token,
      language: _contentLanguage,
    );
    final merged = AsmrWorkDetail(
      work: _decorateWork(detail.work),
      description: detail.description,
      ageCategory: detail.ageCategory,
      languageEditionLabels: detail.languageEditionLabels,
      userRating: detail.userRating,
    );
    _detailCache[work.id] = merged;
    _workCache[work.id] = merged.work;
    return merged;
  }

  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    final tree =
        _trackCache[work.id] ??
        await _apiService.fetchTrackTree(work.id, token: _authSession.token);
    _trackCache[work.id] = tree;
    return _flattenTracks(work, tree);
  }

  List<MusicTrack> buildPlayableTracksFromNode(
    AsmrWork work,
    AsmrTrackFile node,
  ) {
    return _flattenTracks(work, <AsmrTrackFile>[node]);
  }

  List<MusicTrack> _flattenTracks(
    AsmrWork work,
    Iterable<AsmrTrackFile> roots, {
    bool Function(AsmrTrackFile node)? includeAudioNode,
  }) {
    final result = <MusicTrack>[];
    final subtitleByStem = <String, AsmrTrackFile>{};
    final subtitlesByBaseName = <String, List<AsmrTrackFile>>{};

    void indexSubtitles(Iterable<AsmrTrackFile> nodes) {
      for (final node in nodes) {
        if (node.isSubtitle) {
          subtitleByStem.putIfAbsent(node.stemKey, () => node);
          subtitlesByBaseName
              .putIfAbsent(node.baseNameStem, () => <AsmrTrackFile>[])
              .add(node);
        }
        if (node.children.isNotEmpty) {
          indexSubtitles(node.children);
        }
      }
    }

    Map<String, Object?> remoteMetadataForTrack(AsmrTrackFile node) {
      final metadata = Map<String, Object?>.from(work.toJson());
      metadata['trackRelativePath'] = node.relativePath;
      metadata['trackDirectoryPath'] = path.dirname(node.relativePath);
      final subtitle =
          subtitleByStem[node.stemKey] ??
          switch (subtitlesByBaseName[node.baseNameStem]) {
            final List<AsmrTrackFile> matches when matches.length == 1 =>
              matches.first,
            _ => null,
          };
      final subtitleUrl = (subtitle?.streamUrl ?? subtitle?.downloadUrl ?? '')
          .trim();
      if (subtitleUrl.isEmpty) {
        return metadata;
      }
      metadata['subtitleUrl'] = subtitleUrl;
      metadata['subtitleExtension'] = subtitle!.resolvedExtension;
      metadata['subtitleSourcePath'] = subtitle.relativePath;
      metadata['subtitleTitle'] = subtitle.title;
      return metadata;
    }

    indexSubtitles(roots);

    void visit(Iterable<AsmrTrackFile> nodes) {
      for (final node in nodes) {
        if (node.isAudio) {
          if (includeAudioNode != null && !includeAudioNode(node)) {
            continue;
          }
          final track = node.toMusicTrack(
            groupTitleOverride: work.title,
            remoteCoverUrl: work.mainCoverUrl.isNotEmpty
                ? work.mainCoverUrl
                : work.coverUrl,
            remoteMetadataKind: 'asmr.one',
            remoteMetadata: remoteMetadataForTrack(node),
          );
          if (track.path.isNotEmpty) {
            result.add(track);
          }
          continue;
        }
        if (node.children.isNotEmpty) {
          visit(node.children);
        }
      }
    }

    visit(roots);
    return result;
  }

  Future<List<AsmrTrackFile>> ensureTrackTree(AsmrWork work) async {
    final cached = _trackCache[work.id];
    if (cached != null) {
      return cached;
    }
    if (_loadingTrackWorkIds.add(work.id)) {
      notifyListeners();
    }
    try {
      final tree = await _apiService.fetchTrackTree(
        work.id,
        token: _authSession.token,
      );
      _trackCache[work.id] = tree;
      return tree;
    } finally {
      _loadingTrackWorkIds.remove(work.id);
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(AsmrWork work) async {
    final existingIndex = _favoriteWorks.indexWhere(
      (item) => item.id == work.id,
    );
    final shouldFavorite = existingIndex < 0;
    final updatedWork = work.copyWith(isFavorite: shouldFavorite);
    if (shouldFavorite) {
      _favoriteWorks = <AsmrWork>[updatedWork, ..._favoriteWorks]
          .fold<List<AsmrWork>>(<AsmrWork>[], (result, item) {
            if (result.any((existing) => existing.id == item.id)) {
              return result;
            }
            return <AsmrWork>[...result, item];
          });
    } else {
      _favoriteWorks = _favoriteWorks
          .where((item) => item.id != work.id)
          .toList(growable: false);
    }
    _workCache[work.id] = updatedWork;
    _detailCache.update(
      work.id,
      (detail) => AsmrWorkDetail(
        work: updatedWork,
        description: detail.description,
        ageCategory: detail.ageCategory,
        languageEditionLabels: detail.languageEditionLabels,
        userRating: detail.userRating,
      ),
      ifAbsent: () => AsmrWorkDetail(
        work: updatedWork,
        description: '',
        ageCategory: '',
        languageEditionLabels: const <String>[],
        userRating: null,
      ),
    );
    for (final entry in _worksByCategory.entries) {
      entry.value.replaceRange(
        0,
        entry.value.length,
        entry.value
            .map(
              (item) => item.id == work.id
                  ? item.copyWith(isFavorite: shouldFavorite)
                  : item,
            )
            .toList(growable: false),
      );
    }
    await AsmrPreferences.saveFavoriteWorks(_favoriteWorks);
    _updateLocalCategoryCounts();
    notifyListeners();

    final token = _authSession.token;
    final playlistId = _authSession.favoritePlaylistId;
    if (token == null || token.isEmpty || playlistId == null) {
      return;
    }
    try {
      if (shouldFavorite) {
        await _apiService.addWorkToFavoritePlaylist(
          token: token,
          playlistId: playlistId,
          workId: work.id,
        );
        return;
      }
      await _apiService.removeWorkFromFavoritePlaylist(
        token: token,
        playlistId: playlistId,
        workId: work.id,
      );
    } catch (error) {
      _lastError = error;
      notifyListeners();
    }
  }

  Future<void> recordHistory(AsmrWork work) async {
    _historyWorks = <AsmrWork>[
      work,
      ..._historyWorks.where((item) => item.id != work.id),
    ].take(_historyLimit).toList(growable: false);
    _workCache[work.id] = work;
    await AsmrPreferences.saveHistoryWorks(_historyWorks);
    _updateLocalCategoryCounts();
    notifyListeners();
  }

  Future<void> playWork(
    AudioProvider provider,
    AsmrWork work, {
    bool autoPlay = true,
  }) async {
    final tracks = await loadPlayableTracks(work);
    if (tracks.isEmpty) {
      return;
    }
    await recordHistory(work);
    await provider.spawnSessionWithQueue(
      tracks,
      autoPlay: autoPlay,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
  }

  Future<void> playTrack(
    AudioProvider provider,
    AsmrWork work,
    AsmrTrackFile target,
  ) async {
    final tracks = await loadPlayableTracks(work);
    if (tracks.isEmpty) {
      return;
    }
    final targetTrack = target.toMusicTrack(
      groupTitleOverride: work.title,
      remoteCoverUrl: work.mainCoverUrl.isNotEmpty
          ? work.mainCoverUrl
          : work.coverUrl,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: work.toJson(),
    );
    final siblingDirectoryPath = path.dirname(target.relativePath);
    final siblingTracks = _flattenTracks(
      work,
      _trackCache[work.id] ?? const <AsmrTrackFile>[],
      includeAudioNode: (node) =>
          path.dirname(node.relativePath) == siblingDirectoryPath,
    );
    final effectiveTracks = siblingTracks.isNotEmpty ? siblingTracks : tracks;
    final effectiveTargetIndex = effectiveTracks.indexWhere(
      (track) => track.path == targetTrack.path,
    );
    final queue = effectiveTargetIndex <= 0
        ? effectiveTracks
        : <MusicTrack>[
            ...effectiveTracks.skip(effectiveTargetIndex),
            ...effectiveTracks.take(effectiveTargetIndex),
          ];
    await recordHistory(work);
    await provider.spawnSessionWithQueue(
      queue,
      autoPlay: true,
      loopMode: queue.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
  }

  bool _matchesQuery(AsmrWork work, String query) {
    final haystacks = <String>[
      work.title,
      work.circleName,
      work.rjCode,
      ...work.tags,
      ...work.voiceActors,
    ];
    return matchesSearchTerms(haystacks, query);
  }

  void _updateLocalCategoryCounts() {
    for (final category in <AsmrCategoryType>[
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]) {
      final query = _queryByCategory[category] ?? '';
      _totalCountByCategory[category] = filteredWorksFor(
        category,
        searchQuery: query,
      ).length;
    }
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
}
