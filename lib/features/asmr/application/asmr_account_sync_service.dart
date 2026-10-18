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

  Set<int> get favoriteIds =>
      immutableSet(favoriteWorks.map((work) => work.id));

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
  }) : _authService = authService,
       _apiService = apiService,
       _preferencesStore = preferencesStore;

  static const int _historyLimit = 60;

  final AsmrAuthService _authService;
  final AsmrApiService _apiService;
  final AsmrPreferencesStore _preferencesStore;
  AsmrAccountSnapshot _snapshot = AsmrAccountSnapshot();
  Future<void> _mutationTail = Future<void>.value();

  AsmrAccountSnapshot get snapshot => _snapshot;

  Future<AsmrAccountSnapshot> initialize() async {
    final normalized = await compute(_normalizeAccountWorks, (
      favoriteWorks: await _preferencesStore.loadFavoriteWorks(),
      historyWorks: await _preferencesStore.loadHistoryWorks(),
    ));
    _snapshot = AsmrAccountSnapshot(
      favoriteWorks: normalized.favoriteWorks,
      historyWorks: normalized.historyWorks,
      pendingOperations: await _preferencesStore.loadSyncOperations(),
      lastSyncAt: await _preferencesStore.loadLastSyncAt(),
    );
    await _seedOutboxIfNeeded();
    return _snapshot;
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
      final session = await _authService.login(name.trim(), password);
      _snapshot = _snapshot.copyWith(session: session);
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> logout() {
    return _serialize(() async {
      await _authService.logout();
      _snapshot = _snapshot.copyWith(
        clearSession: true,
        remoteProgressByWorkId: const <int, String>{},
      );
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> toggleFavorite(AsmrWork work) {
    return _serialize(
      () => _setFavoritesNow([work], !_snapshot.favoriteIds.contains(work.id)),
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
    final changed = <int, AsmrWork>{};
    for (final work in works) {
      if (favoriteIds.contains(work.id) == favorite) continue;
      changed.putIfAbsent(work.id, () => work.copyWith(isFavorite: favorite));
    }
    if (changed.isEmpty) return current;
    final changedWorks = changed.values.toList(growable: false);
    final newOperations = [
      for (final work in changedWorks)
        AsmrSyncOperation(
          type: favorite
              ? AsmrSyncOperationType.favoriteAdd
              : AsmrSyncOperationType.favoriteRemove,
          workId: work.id,
          sourceId: work.sourceId,
          createdAt: DateTime.now(),
        ),
    ];
    final operations = [
      ...current.pendingOperations.where(
        (operation) =>
            !changed.containsKey(operation.workId) ||
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
    _snapshot = current.copyWith(
      favoriteWorks: [
        if (favorite) ...changedWorks.reversed,
        ...current.favoriteWorks.where((work) => !changed.containsKey(work.id)),
      ],
      historyWorks:
          current.historyWorks.any((work) => changed.containsKey(work.id))
          ? current.historyWorks
                .map((work) {
                  if (!changed.containsKey(work.id)) return work;
                  // Favorites own shared metadata; removal retains that saved history row.
                  return favorite
                      ? changed[work.id]!
                      : work.copyWith(isFavorite: false);
                })
                .toList(growable: false)
          : current.historyWorks,
      pendingOperations: operations,
    );
    return _snapshot;
  }

  Future<AsmrAccountSnapshot> recordHistory(AsmrWork work) {
    return _serialize(() async {
      final current = _snapshot;
      final favorite = current.favoriteWorks
          .where((item) => item.id == work.id)
          .firstOrNull;
      final historyWork =
          favorite ??
          (work.isFavorite ? work.copyWith(isFavorite: false) : work);
      final history = <AsmrWork>[
        historyWork,
        ...current.historyWorks.where((item) => item.id != work.id),
      ].take(_historyLimit).toList(growable: false);
      final operation = AsmrSyncOperation(
        type: AsmrSyncOperationType.historyListening,
        workId: work.id,
        sourceId: work.sourceId,
        createdAt: DateTime.now(),
      );
      final operations = _operationsAfterEnqueue(
        current.pendingOperations,
        operation,
      );
      await _preferencesStore.saveHistoryState(
        work: historyWork,
        historyWorkIds: history.map((item) => item.id).toList(growable: false),
        operation: operation,
      );
      _snapshot = current.copyWith(
        historyWorks: history,
        pendingOperations: operations,
      );
      return _snapshot;
    });
  }

  Future<AsmrAccountSyncResult> synchronize({
    required AsmrContentLanguage language,
    required AsmrRequestCancellationToken cancellationToken,
  }) async {
    var session = _snapshot.session;
    if (session == null || !session.isValid) {
      return AsmrAccountSyncResult(snapshot: _snapshot);
    }
    try {
      await _runSync(session, language, cancellationToken);
    } catch (error) {
      cancellationToken.throwIfCancelled();
      if (!AsmrApiException.isAuthenticationError(error)) {
        return AsmrAccountSyncResult(snapshot: _snapshot, failure: error);
      }
      final recovered = await _authService.restoreSession();
      cancellationToken.throwIfCancelled();
      if (recovered == null || !recovered.isValid) {
        await _authService.logout();
        _snapshot = _snapshot.copyWith(clearSession: true);
        return AsmrAccountSyncResult(snapshot: _snapshot, failure: error);
      }
      session = recovered;
      _snapshot = _snapshot.copyWith(session: recovered);
      try {
        await _runSync(recovered, language, cancellationToken);
      } catch (retryError) {
        cancellationToken.throwIfCancelled();
        if (AsmrApiException.isAuthenticationError(retryError)) {
          await _authService.logout();
          _snapshot = _snapshot.copyWith(clearSession: true);
        }
        return AsmrAccountSyncResult(snapshot: _snapshot, failure: retryError);
      }
    }
    cancellationToken.throwIfCancelled();
    final syncedAt = DateTime.now();
    await _preferencesStore.saveLastSyncAt(syncedAt);
    cancellationToken.throwIfCancelled();
    _snapshot = _snapshot.copyWith(lastSyncAt: syncedAt, session: session);
    return AsmrAccountSyncResult(snapshot: _snapshot);
  }

  Future<void> _runSync(
    AsmrAuthSession session,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) async {
    do {
      token.throwIfCancelled();
      final batch = await token.waitFor(
        compute(_orderedOperations, _snapshot.pendingOperations),
      );
      token.throwIfCancelled();
      if (batch.any(
        (operation) =>
            operation.type == AsmrSyncOperationType.historyListening ||
            operation.type == AsmrSyncOperationType.favoriteRemove,
      )) {
        await _preflightProtectedProgress(session.token, language, token);
      }
      final uploaded = await _flushOperations(session.token, batch, token);
      final recordPages = await _fetchRemoteState(
        session.token,
        language,
        token,
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
            uploaded: uploaded,
          )),
        );
        token.throwIfCancelled();
        await _preferencesStore.saveAccountSyncState(
          favoriteWorks: merged.favoriteWorks,
          historyWorks: merged.historyWorks,
          operations: merged.pendingOperations,
        );
        _snapshot = merged;
        return _snapshot;
      });
    } while (_snapshot.pendingOperations.isNotEmpty);
  }

  Future<List<AsmrSyncOperation>> _flushOperations(
    String tokenValue,
    List<AsmrSyncOperation> batch,
    AsmrRequestCancellationToken token,
  ) async {
    final uploaded = <AsmrSyncOperation>[];
    final failed = <AsmrSyncOperation>[];
    for (final operation in batch) {
      token.throwIfCancelled();
      try {
        switch (operation.type) {
          case AsmrSyncOperationType.favoriteAdd:
            await _putProgress(operation.workId, 'marked', tokenValue);
          case AsmrSyncOperationType.favoriteRemove:
            if (_snapshot.remoteProgressByWorkId[operation.workId] ==
                'marked') {
              await _apiService.deleteReview(
                workId: operation.workId,
                token: tokenValue,
              );
            }
            if (_snapshot.historyWorks.any(
              (work) => work.id == operation.workId,
            )) {
              await _putProgress(operation.workId, 'listening', tokenValue);
            }
          case AsmrSyncOperationType.historyListening:
            if (_snapshot.favoriteIds.contains(operation.workId)) {
              await _putProgress(operation.workId, 'marked', tokenValue);
            } else if (!_isProtected(operation.workId)) {
              await _putProgress(operation.workId, 'listening', tokenValue);
            }
        }
        token.throwIfCancelled();
        uploaded.add(operation);
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
    return uploaded;
  }

  Future<void> _putProgress(int workId, String progress, String token) async {
    await _apiService.putReviewProgress(
      workId: workId,
      progress: progress,
      token: token,
    );
    _snapshot = _snapshot.copyWith(
      remoteProgressByWorkId: <int, String>{
        ..._snapshot.remoteProgressByWorkId,
        workId: progress,
      },
    );
  }

  Future<void> _preflightProtectedProgress(
    String tokenValue,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) async {
    const filters = <String>['marked', 'listened', 'replay', 'postponed'];
    final pages = await Future.wait(
      filters.map(
        (filter) => _fetchReviews(tokenValue, filter, language, token),
      ),
    );
    token.throwIfCancelled();
    final progress = await token.waitFor(compute(_progressByWorkId, pages));
    token.throwIfCancelled();
    _snapshot = _snapshot.copyWith(remoteProgressByWorkId: progress);
  }

  Future<List<List<AsmrReviewRecord>>> _fetchRemoteState(
    String tokenValue,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) {
    const filters = <String>[
      'marked',
      'listening',
      'listened',
      'replay',
      'postponed',
    ];
    return Future.wait(
      filters.map(
        (filter) => _fetchReviews(tokenValue, filter, language, token),
      ),
    );
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
    final favoriteById = <int, AsmrWork>{};
    for (final work in current.favoriteWorks) {
      if (!pendingRemoves.contains(work.id)) {
        favoriteById[work.id] = work.copyWith(isFavorite: true);
      }
    }
    final remoteFavorites =
        records
            .where((record) => record.progress == 'marked')
            .toList(growable: false)
          ..sort(_newestFirst);
    for (final record in remoteFavorites) {
      if (!pendingRemoves.contains(record.work.id)) {
        favoriteById[record.work.id] = record.work.copyWith(isFavorite: true);
      }
    }
    final history = <AsmrWork>[];
    final seen = <int>{};
    for (final work in current.historyWorks) {
      if (seen.add(work.id)) history.add(work);
    }
    final remoteHistory =
        records
            .where((record) => record.progress != 'marked')
            .toList(growable: false)
          ..sort(_newestFirst);
    for (final record in remoteHistory) {
      if (seen.add(record.work.id)) history.add(record.work);
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
    final favoriteById = <int, AsmrWork>{};
    for (final work in works.favoriteWorks) {
      favoriteById.putIfAbsent(work.id, () => work.copyWith(isFavorite: true));
    }
    final normalizedHistory = <AsmrWork>[];
    final seenHistoryIds = <int>{};
    for (final work in works.historyWorks) {
      if (!seenHistoryIds.add(work.id)) continue;
      normalizedHistory.add(
        favoriteById[work.id] ?? work.copyWith(isFavorite: false),
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
      final key = '${AsmrSyncOperationType.historyListening.name}:${work.id}';
      if (keys.add(key)) {
        operations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.historyListening,
            workId: work.id,
            sourceId: work.sourceId,
            createdAt: createdAt,
          ),
        );
        createdAt = createdAt.add(const Duration(milliseconds: 1));
      }
    }
    for (final work in _snapshot.favoriteWorks.reversed) {
      final key = '${AsmrSyncOperationType.favoriteAdd.name}:${work.id}';
      if (keys.add(key)) {
        operations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.favoriteAdd,
            workId: work.id,
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
    final result = _mutationTail.then((_) => mutation());
    _mutationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}
