import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../domain/asmr_models.dart';
import 'asmr_api_service.dart';
import 'asmr_auth_service.dart';
import 'asmr_preferences.dart';

class AsmrAccountSnapshot {
  AsmrAccountSnapshot({
    this.session,
    List<AsmrWork> favoriteWorks = const <AsmrWork>[],
    List<AsmrWork> historyWorks = const <AsmrWork>[],
    List<AsmrSyncOperation> pendingOperations = const <AsmrSyncOperation>[],
    Map<int, String> remoteProgressByWorkId = const <int, String>{},
    this.lastSyncAt,
  }) : favoriteWorks = immutableList(favoriteWorks),
       historyWorks = immutableList(historyWorks),
       pendingOperations = immutableList(pendingOperations),
       remoteProgressByWorkId = immutableMap(remoteProgressByWorkId);

  final AsmrAuthSession? session;
  final List<AsmrWork> favoriteWorks;
  final List<AsmrWork> historyWorks;
  final List<AsmrSyncOperation> pendingOperations;
  final Map<int, String> remoteProgressByWorkId;
  final DateTime? lastSyncAt;

  static final Expando<Set<String>> _favoriteIdsCache = Expando<Set<String>>(
    'asmr_account_favorite_ids',
  );

  Set<String> get favoriteIds => _favoriteIdsCache[this] ??= immutableSet(
    favoriteWorks.map((work) => work.workKey),
  );

  AsmrAccountSnapshot copyWith({
    AsmrAuthSession? session,
    bool clearSession = false,
    List<AsmrWork>? favoriteWorks,
    List<AsmrWork>? historyWorks,
    List<AsmrSyncOperation>? pendingOperations,
    Map<int, String>? remoteProgressByWorkId,
    DateTime? lastSyncAt,
  }) {
    return AsmrAccountSnapshot(
      session: clearSession ? null : session ?? this.session,
      favoriteWorks: favoriteWorks ?? this.favoriteWorks,
      historyWorks: historyWorks ?? this.historyWorks,
      pendingOperations: pendingOperations ?? this.pendingOperations,
      remoteProgressByWorkId:
          remoteProgressByWorkId ?? this.remoteProgressByWorkId,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }
}

class AsmrAccountSyncResult {
  const AsmrAccountSyncResult({required this.snapshot, this.failure});

  final AsmrAccountSnapshot snapshot;
  final Object? failure;

  bool get succeeded => failure == null;
}

class AsmrAccountSyncService {
  AsmrAccountSyncService({
    required AsmrAuthService authService,
    required AsmrApiService apiService,
    required AsmrPreferencesStore preferencesStore,
    Duration fullPullCooldown = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _authService = authService,
       _apiService = apiService,
       _preferencesStore = preferencesStore,
       _fullPullCooldown = fullPullCooldown,
       _now = now ?? DateTime.now;

  static const int _historyLimit = 60;
  static const List<String> _protectedFilters = <String>[
    'marked',
    'listened',
    'replay',
    'postponed',
  ];
  static const List<String> _allReviewFilters = <String>[
    'marked',
    'listening',
    'listened',
    'replay',
    'postponed',
  ];
  static final Expando<Set<int>> _asmrOneIdsCache = Expando<Set<int>>(
    'asmr_account_one_ids',
  );

  static Set<int> _asmrOneIdsFor(List<AsmrWork> works) {
    if (works.isEmpty) return const <int>{};
    return _asmrOneIdsCache[works] ??= <int>{
      for (final work in works)
        if (work.resourceFor(AsmrCatalogSource.asmrOne) case final one?) one.id,
    };
  }

  final AsmrAuthService _authService;
  final AsmrApiService _apiService;
  final AsmrPreferencesStore _preferencesStore;
  final Duration _fullPullCooldown;
  final DateTime Function() _now;
  AsmrAccountSnapshot _snapshot = AsmrAccountSnapshot();
  DateTime? _lastFullPullAt;
  Future<void>? _mutationTail;

  AsmrAccountSnapshot get snapshot => _snapshot;

  Future<AsmrAccountSnapshot> initialize() {
    return _serialize(() async {
      final normalized = await compute(_normalizeAccountWorks, (
        favoriteWorks: await _preferencesStore.loadFavoriteWorks(),
        historyWorks: await _preferencesStore.loadHistoryWorks(),
      ));
      _lastFullPullAt = null;
      _snapshot = AsmrAccountSnapshot(
        favoriteWorks: normalized.favoriteWorks,
        historyWorks: normalized.historyWorks,
        pendingOperations: await _preferencesStore.loadSyncOperations(),
        lastSyncAt: await _preferencesStore.loadLastSyncAt(),
      );
      await _seedOutboxIfNeeded();
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> restoreSession() {
    return _serialize(() async {
      final session = await _authService.restoreSession();
      _snapshot = _snapshot.copyWith(
        session: session,
        clearSession: session == null,
      );
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> login(String name, String password) {
    return _serialize(() async {
      final session = await _authService.login(name, password);
      _lastFullPullAt = null;
      _snapshot = _snapshot.copyWith(
        session: session,
        remoteProgressByWorkId: const <int, String>{},
      );
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> logout() {
    return _serialize(() async {
      await _authService.logout();
      _lastFullPullAt = null;
      _snapshot = _snapshot.copyWith(
        clearSession: true,
        remoteProgressByWorkId: const <int, String>{},
      );
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> toggleFavorite(AsmrWork work) {
    return _serialize(
      () => _setFavoritesNow([
        work,
      ], !_snapshot.favoriteIds.contains(work.workKey)),
    );
  }

  Future<AsmrAccountSnapshot> setFavorites(
    List<AsmrWork> works, {
    required bool favorite,
  }) => _serialize(() => _setFavoritesNow(works, favorite));

  Future<AsmrAccountSnapshot> _setFavoritesNow(
    List<AsmrWork> works,
    bool favorite,
  ) async {
    final current = _snapshot;
    final favoriteIds = current.favoriteIds;
    final changed = <String, AsmrWork>{};
    for (final work in works) {
      if (favoriteIds.contains(work.workKey) == favorite) continue;
      changed.putIfAbsent(
        work.workKey,
        () => work.copyWith(isFavorite: favorite),
      );
    }
    if (changed.isEmpty) return current;
    final changedWorks = changed.values.toList(growable: false);
    final changedOneIds = <int>{};
    final newOperations = <AsmrSyncOperation>[];
    final now = DateTime.now();
    for (final work in changedWorks) {
      final one = work.resourceFor(AsmrCatalogSource.asmrOne);
      if (one == null) continue;
      changedOneIds.add(one.id);
      newOperations.add(
        AsmrSyncOperation(
          type: favorite
              ? AsmrSyncOperationType.favoriteAdd
              : AsmrSyncOperationType.favoriteRemove,
          workId: one.id,
          sourceId: work.sourceId,
          createdAt: now,
        ),
      );
    }
    final operations = [
      ...current.pendingOperations.where(
        (operation) =>
            !changedOneIds.contains(operation.workId) ||
            (operation.type != AsmrSyncOperationType.favoriteAdd &&
                operation.type != AsmrSyncOperationType.favoriteRemove),
      ),
      ...newOperations,
    ];
    await _preferencesStore.saveFavoriteState(
      works: changedWorks,
      favorite: favorite,
      operations: newOperations,
    );
    final latest = _snapshot;
    _snapshot = latest.copyWith(
      favoriteWorks: [
        if (favorite) ...changedWorks.reversed,
        ...latest.favoriteWorks.where(
          (work) => !changed.containsKey(work.workKey),
        ),
      ],
      historyWorks:
          latest.historyWorks.any((work) => changed.containsKey(work.workKey))
          ? latest.historyWorks
                .map((work) {
                  if (!changed.containsKey(work.workKey)) return work;
                  // Favorites own shared metadata; removal retains that saved history row.
                  return favorite
                      ? changed[work.workKey]!
                      : work.copyWith(isFavorite: false);
                })
                .toList(growable: false)
          : latest.historyWorks,
      pendingOperations: operations,
    );
    return _snapshot;
  }

  Future<AsmrAccountSnapshot> recordHistory(AsmrWork work) {
    return _serialize(() async {
      final current = _snapshot;
      final favorite = current.favoriteIds.contains(work.workKey)
          ? current.favoriteWorks
                .where((item) => item.workKey == work.workKey)
                .firstOrNull
          : null;
      final historyWork =
          favorite?.mergedWith(work) ??
          (work.isFavorite ? work.copyWith(isFavorite: false) : work);
      final history = <AsmrWork>[
        historyWork,
        ...current.historyWorks.where((item) => item.workKey != work.workKey),
      ].take(_historyLimit).toList(growable: false);
      final one = work.resourceFor(AsmrCatalogSource.asmrOne);
      final operation = one == null
          ? null
          : AsmrSyncOperation(
              type: AsmrSyncOperationType.historyListening,
              workId: one.id,
              sourceId: work.sourceId,
              createdAt: DateTime.now(),
            );
      final operations = operation == null
          ? current.pendingOperations
          : _operationsAfterEnqueue(current.pendingOperations, operation);
      await _preferencesStore.saveHistoryState(
        work: historyWork,
        historyWorkKeys: history
            .map((item) => item.workKey)
            .toList(growable: false),
        operation: operation,
      );
      final latest = _snapshot;
      _snapshot = latest.copyWith(
        historyWorks: history,
        pendingOperations: operations,
      );
      return _snapshot;
    });
  }

  static bool _isSameSession(
    AsmrAuthSession? current,
    AsmrAuthSession expected,
  ) =>
      current != null &&
      current.token == expected.token &&
      current.userName == expected.userName;

  Future<void> _clearExpiredSession(AsmrAuthSession failedSession) {
    return _serialize(() async {
      if (!_isSameSession(_snapshot.session, failedSession)) return;
      await _authService.logout();
      _lastFullPullAt = null;
      _snapshot = _snapshot.copyWith(
        clearSession: true,
        remoteProgressByWorkId: const <int, String>{},
      );
    });
  }

  Future<AsmrAccountSyncResult> synchronize({
    required AsmrContentLanguage language,
    required AsmrRequestCancellationToken cancellationToken,
    bool fullPull = true,
  }) async {
    var session = _snapshot.session;
    if (session == null || !session.isValid) {
      return AsmrAccountSyncResult(snapshot: _snapshot);
    }
    try {
      await _runSync(session, language, cancellationToken, fullPull: fullPull);
    } catch (error) {
      cancellationToken.throwIfCancelled();
      if (!AsmrApiException.isAuthenticationError(error)) {
        return AsmrAccountSyncResult(snapshot: _snapshot, failure: error);
      }
      final AsmrAuthSession? recovered;
      try {
        recovered = await _authService.refreshSession();
      } catch (recoveryError) {
        cancellationToken.throwIfCancelled();
        if (AsmrApiException.isAuthenticationError(recoveryError)) {
          await _clearExpiredSession(session);
        }
        return AsmrAccountSyncResult(
          snapshot: _snapshot,
          failure: recoveryError,
        );
      }
      cancellationToken.throwIfCancelled();
      if (recovered == null || !recovered.isValid) {
        await _clearExpiredSession(session);
        return AsmrAccountSyncResult(snapshot: _snapshot, failure: error);
      }
      final previousSession = session;
      final applied = await _serialize(() async {
        cancellationToken.throwIfCancelled();
        if (!_isSameSession(_snapshot.session, previousSession)) return false;
        _snapshot = _snapshot.copyWith(session: recovered);
        return true;
      });
      if (!applied) {
        return AsmrAccountSyncResult(snapshot: _snapshot);
      }
      session = recovered;
      try {
        await _runSync(
          recovered,
          language,
          cancellationToken,
          fullPull: fullPull,
        );
      } catch (retryError) {
        cancellationToken.throwIfCancelled();
        if (AsmrApiException.isAuthenticationError(retryError)) {
          await _clearExpiredSession(session);
        }
        return AsmrAccountSyncResult(snapshot: _snapshot, failure: retryError);
      }
    }
    cancellationToken.throwIfCancelled();
    final syncedAt = _now();
    await _preferencesStore.saveLastSyncAt(syncedAt);
    cancellationToken.throwIfCancelled();
    final completedSession = session;
    await _serialize(() async {
      cancellationToken.throwIfCancelled();
      if (!_isSameSession(_snapshot.session, completedSession)) return;
      _snapshot = _snapshot.copyWith(
        lastSyncAt: syncedAt,
        session: completedSession,
      );
    });
    return AsmrAccountSyncResult(snapshot: _snapshot);
  }

  Future<void> _runSync(
    AsmrAuthSession session,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token, {
    required bool fullPull,
  }) async {
    var shouldFullPull =
        fullPull ||
        _lastFullPullAt == null ||
        _now().difference(_lastFullPullAt!) >= _fullPullCooldown;
    do {
      token.throwIfCancelled();
      final pending = _snapshot.pendingOperations;
      final batch = pending.length <= 64
          ? _orderedOperations(pending)
          : await token.waitFor(compute(_orderedOperations, pending));
      token.throwIfCancelled();
      if (!shouldFullPull) {
        if (batch.isEmpty) break;
        final flushResult = await _flushOperations(session.token, batch, token);
        token.throwIfCancelled();
        await _serialize(() async {
          token.throwIfCancelled();
          final uploadedKeys = flushResult.uploaded.map(_operationKey).toSet();
          final operations = _snapshot.pendingOperations
              .where((item) => !uploadedKeys.contains(_operationKey(item)))
              .toList(growable: false);
          await _preferencesStore.saveSyncOperations(operations);
          token.throwIfCancelled();
          _snapshot = _snapshot.copyWith(pendingOperations: operations);
          return _snapshot;
        });
        continue;
      }
      Map<String, List<AsmrReviewRecord>>? preflightPages;
      if (batch.any(
        (operation) =>
            operation.type == AsmrSyncOperationType.historyListening ||
            operation.type == AsmrSyncOperationType.favoriteRemove,
      )) {
        preflightPages = await _preflightProtectedProgress(
          session.token,
          language,
          token,
        );
      }
      final flushResult = await _flushOperations(session.token, batch, token);
      final recordPages = await _fetchRemoteState(
        session.token,
        language,
        token,
        preflightPages: preflightPages,
        mutatedFilters: flushResult.mutatedFilters,
      );
      token.throwIfCancelled();
      await _serialize(() async {
        token.throwIfCancelled();
        // Stay inside the mutation queue while preparing the snapshot so an
        // intervening favorite/history action cannot be overwritten on return.
        final merged = await token.waitFor(
          compute(_prepareSyncedSnapshot, (
            current: _snapshot,
            recordPages: recordPages,
            uploaded: flushResult.uploaded,
          )),
        );
        token.throwIfCancelled();
        await _preferencesStore.saveAccountSyncState(
          favoriteWorks: merged.favoriteWorks,
          historyWorks: merged.historyWorks,
          operations: merged.pendingOperations,
        );
        token.throwIfCancelled();
        _snapshot = merged;
        _lastFullPullAt = _now();
        return _snapshot;
      });
      shouldFullPull = false;
    } while (_snapshot.pendingOperations.isNotEmpty);
  }

  Future<({List<AsmrSyncOperation> uploaded, Set<String> mutatedFilters})>
  _flushOperations(
    String tokenValue,
    List<AsmrSyncOperation> batch,
    AsmrRequestCancellationToken token,
  ) async {
    final uploaded = <AsmrSyncOperation>[];
    final failed = <AsmrSyncOperation>[];
    final mutatedFilters = <String>{};
    Future<void> putAndTrack(int workId, String progress) async {
      final previous = _snapshot.remoteProgressByWorkId[workId];
      await _putProgress(workId, progress, tokenValue, token);
      mutatedFilters.add(progress);
      if (previous != null) mutatedFilters.add(previous);
    }

    for (final operation in batch) {
      token.throwIfCancelled();
      try {
        switch (operation.type) {
          case AsmrSyncOperationType.favoriteAdd:
            await putAndTrack(operation.workId, 'marked');
          case AsmrSyncOperationType.favoriteRemove:
            final progress = _snapshot.remoteProgressByWorkId[operation.workId];
            if (progress == 'marked') {
              await _apiService.deleteReview(
                workId: operation.workId,
                token: tokenValue,
              );
              await _serialize(() async {
                token.throwIfCancelled();
                if (_snapshot.session?.token != tokenValue) return;
                final updatedProgress = Map<int, String>.of(
                  _snapshot.remoteProgressByWorkId,
                )..remove(operation.workId);
                _snapshot = _snapshot.copyWith(
                  remoteProgressByWorkId: updatedProgress,
                );
              });
              mutatedFilters.add('marked');
            }
            if ((progress == 'marked' || !_isProtected(operation.workId)) &&
                _asmrOneIdsFor(
                  _snapshot.historyWorks,
                ).contains(operation.workId)) {
              await putAndTrack(operation.workId, 'listening');
            }
          case AsmrSyncOperationType.historyListening:
            if (_asmrOneIdsFor(
              _snapshot.favoriteWorks,
            ).contains(operation.workId)) {
              await putAndTrack(operation.workId, 'marked');
            } else if (!_isProtected(operation.workId)) {
              await putAndTrack(operation.workId, 'listening');
            }
        }
        token.throwIfCancelled();
        uploaded.add(operation);
      } on AsmrRequestCancelled {
        rethrow;
      } catch (error) {
        if (AsmrApiException.isAuthenticationError(error)) rethrow;
        failed.add(operation);
      }
    }
    if (failed.isNotEmpty) {
      await _serialize(() async {
        token.throwIfCancelled();
        final uploadedKeys = uploaded.map(_operationKey).toSet();
        final failedKeys = failed.map(_operationKey).toSet();
        final operations = _snapshot.pendingOperations
            .where((item) => !uploadedKeys.contains(_operationKey(item)))
            .map(
              (item) => failedKeys.contains(_operationKey(item))
                  ? item.copyWith(retryCount: item.retryCount + 1)
                  : item,
            )
            .toList(growable: false);
        await _preferencesStore.saveSyncOperations(operations);
        token.throwIfCancelled();
        _snapshot = _snapshot.copyWith(pendingOperations: operations);
        return _snapshot;
      });
      throw const HttpException('ASMR sync operations failed.');
    }
    return (uploaded: uploaded, mutatedFilters: mutatedFilters);
  }

  Future<void> _putProgress(
    int workId,
    String progress,
    String token,
    AsmrRequestCancellationToken cancellationToken,
  ) async {
    await _apiService.putReviewProgress(
      workId: workId,
      progress: progress,
      token: token,
    );
    await _serialize(() async {
      cancellationToken.throwIfCancelled();
      if (_snapshot.session?.token != token) return;
      _snapshot = _snapshot.copyWith(
        remoteProgressByWorkId: <int, String>{
          ..._snapshot.remoteProgressByWorkId,
          workId: progress,
        },
      );
    });
  }

  Future<Map<String, List<AsmrReviewRecord>>> _preflightProtectedProgress(
    String tokenValue,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) async {
    final pages = await Future.wait(
      _protectedFilters.map(
        (filter) => _fetchReviews(tokenValue, filter, language, token),
      ),
    );
    token.throwIfCancelled();
    final progress = await token.waitFor(compute(_progressByWorkId, pages));
    token.throwIfCancelled();
    await _serialize(() async {
      token.throwIfCancelled();
      if (_snapshot.session?.token != tokenValue) return;
      _snapshot = _snapshot.copyWith(remoteProgressByWorkId: progress);
    });
    return <String, List<AsmrReviewRecord>>{
      for (var index = 0; index < _protectedFilters.length; index++)
        _protectedFilters[index]: pages[index],
    };
  }

  Future<List<List<AsmrReviewRecord>>> _fetchRemoteState(
    String tokenValue,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token, {
    Map<String, List<AsmrReviewRecord>>? preflightPages,
    Set<String> mutatedFilters = const <String>{},
  }) async {
    final filtersToFetch = <String>[
      for (final filter in _allReviewFilters)
        if (preflightPages?[filter] == null || mutatedFilters.contains(filter))
          filter,
    ];
    final fetched = await Future.wait(
      filtersToFetch.map(
        (filter) => _fetchReviews(tokenValue, filter, language, token),
      ),
    );
    final fetchedByFilter = <String, List<AsmrReviewRecord>>{
      for (var index = 0; index < filtersToFetch.length; index++)
        filtersToFetch[index]: fetched[index],
    };
    return <List<AsmrReviewRecord>>[
      for (final filter in _allReviewFilters)
        fetchedByFilter[filter] ?? preflightPages![filter]!,
    ];
  }

  Future<List<AsmrReviewRecord>> _fetchReviews(
    String tokenValue,
    String filter,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) async {
    final records = <AsmrReviewRecord>[];
    for (var page = 1; ; page++) {
      token.throwIfCancelled();
      final values = await _apiService.fetchReviews(
        token: tokenValue,
        filter: filter,
        page: page,
        language: language,
        cancellationToken: token,
      );
      token.throwIfCancelled();
      if (values.isEmpty) break;
      records.addAll(values);
    }
    return records;
  }

  static List<AsmrSyncOperation> _orderedOperations(
    List<AsmrSyncOperation> operations,
  ) =>
      operations.toList(growable: false)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  static Map<int, String> _progressByWorkId(
    List<List<AsmrReviewRecord>> pages,
  ) => immutableMap({
    for (final records in pages)
      for (final record in records) record.work.id: record.progress,
  });

  static AsmrAccountSnapshot _prepareSyncedSnapshot(
    ({
      AsmrAccountSnapshot current,
      List<List<AsmrReviewRecord>> recordPages,
      List<AsmrSyncOperation> uploaded,
    })
    request,
  ) {
    final uploadedKeys = request.uploaded.map(_operationKey).toSet();
    final operations = request.current.pendingOperations
        .where((item) => !uploadedKeys.contains(_operationKey(item)))
        .toList(growable: false);
    return _mergeRemoteState(
      request.current,
      request.recordPages.expand((records) => records).toList(growable: false),
    ).copyWith(pendingOperations: operations);
  }

  static AsmrAccountSnapshot _mergeRemoteState(
    AsmrAccountSnapshot current,
    List<AsmrReviewRecord> records,
  ) {
    final pendingRemoves = current.pendingOperations
        .where((item) => item.type == AsmrSyncOperationType.favoriteRemove)
        .map((item) => item.workId)
        .toSet();
    final favoriteById = <String, AsmrWork>{};
    for (final work in current.favoriteWorks) {
      if (!pendingRemoves.contains(
        work.resourceFor(AsmrCatalogSource.asmrOne)?.id,
      )) {
        favoriteById[work.workKey] = work.copyWith(isFavorite: true);
      }
    }
    final remoteFavorites =
        records
            .where((record) => record.progress == 'marked')
            .toList(growable: false)
          ..sort(_newestFirst);
    for (final record in remoteFavorites) {
      if (!pendingRemoves.contains(record.work.id)) {
        favoriteById.update(
          record.work.workKey,
          (local) => local.mergedWith(record.work).copyWith(isFavorite: true),
          ifAbsent: () => record.work.copyWith(isFavorite: true),
        );
      }
    }
    final history = <AsmrWork>[];
    final historyIndexByKey = <String, int>{};
    for (final work in current.historyWorks) {
      historyIndexByKey.putIfAbsent(work.workKey, () {
        history.add(work);
        return history.length - 1;
      });
    }
    final remoteHistory =
        records
            .where((record) => record.progress != 'marked')
            .toList(growable: false)
          ..sort(_newestFirst);
    for (final record in remoteHistory) {
      final existingIndex = historyIndexByKey[record.work.workKey];
      if (existingIndex == null) {
        historyIndexByKey[record.work.workKey] = history.length;
        history.add(record.work);
      } else {
        history[existingIndex] = history[existingIndex].mergedWith(record.work);
      }
    }
    final normalized = _normalizeAccountWorks((
      favoriteWorks: favoriteById.values.toList(growable: false),
      historyWorks: history.take(_historyLimit).toList(growable: false),
    ));
    return current.copyWith(
      favoriteWorks: normalized.favoriteWorks,
      historyWorks: normalized.historyWorks,
      remoteProgressByWorkId: <int, String>{
        for (final record in records) record.work.id: record.progress,
      },
    );
  }

  static ({List<AsmrWork> favoriteWorks, List<AsmrWork> historyWorks})
  _normalizeAccountWorks(
    ({List<AsmrWork> favoriteWorks, List<AsmrWork> historyWorks}) works,
  ) {
    final favoriteById = <String, AsmrWork>{};
    for (final work in works.favoriteWorks) {
      favoriteById.update(
        work.workKey,
        (existing) => existing.mergedWith(work).copyWith(isFavorite: true),
        ifAbsent: () => work.copyWith(isFavorite: true),
      );
    }
    final normalizedHistory = <AsmrWork>[];
    final seenHistoryIds = <String>{};
    for (final work in works.historyWorks) {
      if (!seenHistoryIds.add(work.workKey)) continue;
      normalizedHistory.add(
        favoriteById[work.workKey]
                ?.mergedWith(work)
                .copyWith(isFavorite: true) ??
            work.copyWith(isFavorite: false),
      );
    }
    return (
      favoriteWorks: favoriteById.values.toList(growable: false),
      historyWorks: normalizedHistory,
    );
  }

  Future<void> _seedOutboxIfNeeded() async {
    if (await _preferencesStore.isSyncOutboxSeeded()) return;
    final operations = _snapshot.pendingOperations.toList(growable: true);
    final keys = operations
        .map((item) => '${item.type.name}:${item.workId}')
        .toSet();
    var createdAt = DateTime.now().subtract(
      Duration(
        milliseconds:
            _snapshot.favoriteWorks.length + _snapshot.historyWorks.length,
      ),
    );
    for (final work in _snapshot.historyWorks.reversed) {
      if (work.resourceFor(AsmrCatalogSource.asmrOne) == null) continue;
      final key = '${AsmrSyncOperationType.historyListening.name}:${work.id}';
      if (keys.add(key)) {
        operations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.historyListening,
            workId: work.resourceFor(AsmrCatalogSource.asmrOne)!.id,
            sourceId: work.sourceId,
            createdAt: createdAt,
          ),
        );
        createdAt = createdAt.add(const Duration(milliseconds: 1));
      }
    }
    for (final work in _snapshot.favoriteWorks.reversed) {
      if (work.resourceFor(AsmrCatalogSource.asmrOne) == null) continue;
      final key = '${AsmrSyncOperationType.favoriteAdd.name}:${work.id}';
      if (keys.add(key)) {
        operations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.favoriteAdd,
            workId: work.resourceFor(AsmrCatalogSource.asmrOne)!.id,
            sourceId: work.sourceId,
            createdAt: createdAt,
          ),
        );
        createdAt = createdAt.add(const Duration(milliseconds: 1));
      }
    }
    if (operations.length != _snapshot.pendingOperations.length) {
      await _preferencesStore.saveSyncOperations(operations);
      _snapshot = _snapshot.copyWith(pendingOperations: operations);
    }
    await _preferencesStore.markSyncOutboxSeeded();
  }

  List<AsmrSyncOperation> _operationsAfterEnqueue(
    List<AsmrSyncOperation> current,
    AsmrSyncOperation operation,
  ) {
    return <AsmrSyncOperation>[
      ...current.where((existing) {
        if (existing.workId != operation.workId) return true;
        if (operation.type == AsmrSyncOperationType.favoriteAdd ||
            operation.type == AsmrSyncOperationType.favoriteRemove) {
          return existing.type != AsmrSyncOperationType.favoriteAdd &&
              existing.type != AsmrSyncOperationType.favoriteRemove;
        }
        return existing.type != operation.type;
      }),
      operation,
    ];
  }

  bool _isProtected(int workId) {
    final progress = _snapshot.remoteProgressByWorkId[workId];
    return progress == 'marked' ||
        progress == 'listened' ||
        progress == 'replay' ||
        progress == 'postponed';
  }

  static ({AsmrSyncOperationType type, int workId, DateTime createdAt})
  _operationKey(AsmrSyncOperation operation) => (
    type: operation.type,
    workId: operation.workId,
    createdAt: operation.createdAt,
  );

  static int _newestFirst(AsmrReviewRecord a, AsmrReviewRecord b) {
    final left = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final right = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byTime = right.compareTo(left);
    return byTime != 0 ? byTime : b.work.id.compareTo(a.work.id);
  }

  Future<T> _serialize<T>(Future<T> Function() mutation) {
    final previous = _mutationTail;
    final result = previous == null
        ? Future<T>.sync(mutation)
        : previous.then((_) => mutation());
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_, _) {}).whenComplete(() {
      if (identical(_mutationTail, tail)) {
        _mutationTail = null;
      }
    });
    _mutationTail = tail;
    return result;
  }
}
