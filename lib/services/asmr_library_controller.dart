import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import 'asmr_api_service.dart';
import 'asmr_preferences.dart';

class AsmrLibraryController extends ChangeNotifier {
  AsmrLibraryController({AsmrApiService? apiService})
    : _apiService = apiService ?? AsmrApiService();

  static const int _historyLimit = 60;
  static const Map<AsmrCategoryType, int> _pageSizes = <AsmrCategoryType, int>{
    AsmrCategoryType.sales: 40,
    AsmrCategoryType.rating: 40,
    AsmrCategoryType.release: 40,
    AsmrCategoryType.favorites: 60,
    AsmrCategoryType.history: 60,
  };

  final AsmrApiService _apiService;
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
  List<AsmrWork> _favoriteWorks = const <AsmrWork>[];
  List<AsmrWork> _historyWorks = const <AsmrWork>[];
  bool _initialized = false;
  Object? _lastError;

  bool get initialized => _initialized;
  Object? get lastError => _lastError;
  AsmrAuthSession get authSession => _authSession;

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
    final normalizedQuery = searchQuery.trim();
    if (normalizedQuery.isEmpty) {
      return works;
    }
    if (category != AsmrCategoryType.favorites &&
        category != AsmrCategoryType.history) {
      return works;
    }
    return works
        .where((work) => _matchesQuery(work, normalizedQuery))
        .toList(growable: false);
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _authSession = await AsmrPreferences.loadAuthSession();
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

  Future<void> updateAuthToken(String? token) async {
    final trimmed = token?.trim();
    _authSession = AsmrAuthSession(
      token: trimmed?.isEmpty == true ? null : trimmed,
    );
    await AsmrPreferences.saveAuthSession(_authSession);
    notifyListeners();
    if (_authSession.isLoggedIn) {
      await syncAuthSession();
    }
  }

  Future<void> login({
    required String userName,
    required String password,
  }) async {
    final session = await _apiService.login(
      userName: userName,
      password: password,
    );
    _authSession = session;
    await AsmrPreferences.saveAuthSession(_authSession);
    notifyListeners();
    await syncAuthSession();
  }

  Future<void> clearAuthSession() async {
    _authSession = const AsmrAuthSession();
    await AsmrPreferences.saveAuthSession(_authSession);
    notifyListeners();
  }

  Future<void> syncAuthSession() async {
    final token = _authSession.token;
    if (token == null || token.isEmpty) return;
    try {
      final synced = await _apiService.fetchAuthSession(token);
      final favoritePlaylistId = await _apiService.fetchFavoritePlaylistId(
        token,
      );
      _authSession = synced.copyWith(favoritePlaylistId: favoritePlaylistId);
      await AsmrPreferences.saveAuthSession(_authSession);
      if (favoritePlaylistId != null) {
        await _syncFavoriteWorksFromRemote(
          token: token,
          playlistId: favoritePlaylistId,
        );
      }
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
    }
  }

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final existing = _refreshTasks[category];
    final normalizedQuery = searchQuery.trim();
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
    final normalizedQuery = searchQuery.trim();
    if (category == AsmrCategoryType.favorites ||
        category == AsmrCategoryType.history) {
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
    final normalizedQuery = searchQuery.trim();
    _loadingByCategory[category] = true;
    _lastError = null;
    notifyListeners();
    try {
      switch (category) {
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
      );
    }
    return _apiService.fetchWorks(
      order: spec.order,
      sort: spec.sort,
      page: page,
      pageSize: pageSize,
      token: _authSession.token,
    );
  }

  ({String order, String sort}) _sortSpecFor(AsmrCategoryType category) {
    switch (category) {
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
    Iterable<AsmrTrackFile> roots,
  ) {
    final result = <MusicTrack>[];
    void visit(Iterable<AsmrTrackFile> nodes) {
      for (final node in nodes) {
        if (node.isAudio) {
          final track = node.toMusicTrack(groupTitleOverride: work.title);
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
    final targetTrack = target.toMusicTrack(groupTitleOverride: work.title);
    final targetIndex = tracks.indexWhere(
      (track) => track.path == targetTrack.path,
    );
    final queue = targetIndex <= 0
        ? tracks
        : <MusicTrack>[
            ...tracks.skip(targetIndex),
            ...tracks.take(targetIndex),
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
    final lowerQuery = query.trim().toLowerCase();
    if (lowerQuery.isEmpty) {
      return true;
    }
    final haystacks = <String>[
      work.title,
      work.circleName,
      work.rjCode,
      ...work.tags,
      ...work.voiceActors,
    ];
    return haystacks.any(
      (value) => value.trim().toLowerCase().contains(lowerQuery),
    );
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
}
