import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/audio_detail.dart';
import '../domain/asmr_models.dart';
import 'asmr_api_service.dart';
import 'asmr_auth_service.dart';
import 'asmr_preferences.dart';

class AsmrAccountSnapshot {
  AsmrAccountSnapshot({
    this.session,
    List<AsmrWork> favoriteWorks = const <AsmrWork>[],
    List<AsmrWork> reviewedWorks = const <AsmrWork>[],
    List<AsmrWork> historyWorks = const <AsmrWork>[],
    List<AsmrSyncOperation> pendingOperations = const <AsmrSyncOperation>[],
    Map<int, String> remoteProgressByWorkId = const <int, String>{},
    this.lastSyncAt,
  }) : favoriteWorks = immutableList(favoriteWorks),
       reviewedWorks = immutableList(reviewedWorks),
       historyWorks = immutableList(historyWorks),
       pendingOperations = immutableList(pendingOperations),
       remoteProgressByWorkId = immutableMap(remoteProgressByWorkId);

  final AsmrAuthSession? session;
  final List<AsmrWork> favoriteWorks;
  final List<AsmrWork> reviewedWorks;
  final List<AsmrWork> historyWorks;
  final List<AsmrSyncOperation> pendingOperations;
  final Map<int, String> remoteProgressByWorkId;
  final DateTime? lastSyncAt;

  static final Expando<Set<String>> _favoriteIdsCache = Expando<Set<String>>(
    'asmr_account_favorite_ids',
  );
  static final Expando<Map<String, AsmrWork>> _reviewedByWorkKeyCache =
      Expando<Map<String, AsmrWork>>('asmr_account_reviewed_by_work_key');
  static final Expando<Map<String, AsmrWork>> _reviewedByRjCodeCache =
      Expando<Map<String, AsmrWork>>('asmr_account_reviewed_by_rj_code');
  static final Expando<Set<int>> _protectedReviewIdsCache = Expando<Set<int>>(
    'asmr_account_protected_review_ids',
  );

  Set<String> get favoriteIds => _favoriteIdsCache[favoriteWorks] ??=
      immutableSet(favoriteWorks.map((work) => work.workKey));

  Map<String, AsmrWork> get reviewedByWorkKey =>
      _reviewedByWorkKeyCache[reviewedWorks] ??= immutableMap({
        for (final work in reviewedWorks) work.workKey: work,
      });

  Map<String, AsmrWork> get reviewedByRjCode =>
      _reviewedByRjCodeCache[reviewedWorks] ??= immutableMap({
        for (final work in reviewedWorks)
          if (work.rjCode.isNotEmpty) work.rjCode: work,
      });

  bool _hasProtectedReview(int workId) =>
      (_protectedReviewIdsCache[reviewedWorks] ??= <int>{
        for (final work in reviewedWorks)
          if (work.listenStatus?.isProtectedFromAutoListening ?? false)
            if (work.resourceFor(AsmrCatalogSource.asmrOne) case final one?)
              one.id,
      }).contains(workId);

  AsmrAccountSnapshot copyWith({
    AsmrAuthSession? session,
    bool clearSession = false,
    List<AsmrWork>? favoriteWorks,
    List<AsmrWork>? reviewedWorks,
    List<AsmrWork>? historyWorks,
    List<AsmrSyncOperation>? pendingOperations,
    Map<int, String>? remoteProgressByWorkId,
    DateTime? lastSyncAt,
  }) {
    return AsmrAccountSnapshot(
      session: clearSession ? null : session ?? this.session,
      favoriteWorks: favoriteWorks ?? this.favoriteWorks,
      reviewedWorks: reviewedWorks ?? this.reviewedWorks,
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
        reviewedWorks: await _preferencesStore.loadReviewedWorks(),
        historyWorks: await _preferencesStore.loadHistoryWorks(),
      ));
      _lastFullPullAt = null;
      _snapshot = AsmrAccountSnapshot(
        favoriteWorks: normalized.favoriteWorks,
        reviewedWorks: normalized.reviewedWorks,
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
    final reviewedByKey = current.reviewedByWorkKey;
    final pendingReviews = <int, AsmrSyncOperation>{
      for (final operation in current.pendingOperations)
        if (operation.type == AsmrSyncOperationType.reviewUpsert ||
            operation.type == AsmrSyncOperationType.reviewDelete)
          operation.workId: operation,
    };
    final now = _now();
    final changed = <String, AsmrWork>{};
    for (final work in works) {
      if (favoriteIds.contains(work.workKey) == favorite) continue;
      changed.putIfAbsent(work.workKey, () {
        final base = reviewedByKey[work.workKey]?.mergedWith(work) ?? work;
        final one = base.resourceFor(AsmrCatalogSource.asmrOne);
        final pending = pendingReviews[one?.id];
        return base.copyWith(
          isFavorite: favorite,
          listenStatus: favorite ? WorkListenStatus.marked : null,
          clearListenStatus:
              !favorite && base.listenStatus == WorkListenStatus.marked,
          userRating: pending?.userRating,
          clearUserRating: pending != null && pending.userRating == null,
          reviewText: pending == null ? null : pending.reviewText ?? '',
          reviewUpdatedAt: now,
        );
      });
    }
    if (changed.isEmpty) return current;
    final changedWorks = changed.values.toList(growable: false);
    final changedOneIds = <int>{};
    final newOperations = <AsmrSyncOperation>[];
    for (final work in changedWorks) {
      final one = work.resourceFor(AsmrCatalogSource.asmrOne);
      if (one == null || one.id <= 0) continue;
      changedOneIds.add(one.id);
      if ((!favorite && work.hasUserReview) ||
          (favorite && pendingReviews.containsKey(one.id))) {
        newOperations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.reviewUpsert,
            workId: one.id,
            sourceId: work.sourceId,
            createdAt: now,
            progress: work.listenStatus?.wireValue,
            userRating: work.userRating,
            reviewText: work.reviewText,
            hasReviewPayload: true,
          ),
        );
      } else {
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
    }
    final operations = [
      ...current.pendingOperations.where(
        (operation) =>
            !changedOneIds.contains(operation.workId) ||
            (operation.type != AsmrSyncOperationType.favoriteAdd &&
                operation.type != AsmrSyncOperationType.favoriteRemove &&
                operation.type != AsmrSyncOperationType.reviewUpsert &&
                operation.type != AsmrSyncOperationType.reviewDelete),
      ),
      ...newOperations,
    ];
    await _preferencesStore.saveFavoriteState(
      works: changedWorks,
      favorite: favorite,
      operations: newOperations,
    );
    final latest = _snapshot;
    final retainedReviewedChanged = [
      for (final work in changedWorks.reversed)
        if (work.hasUserReview) work,
    ];
    _snapshot = latest.copyWith(
      favoriteWorks: [
        if (favorite) ...changedWorks.reversed,
        ...latest.favoriteWorks.where(
          (work) => !changed.containsKey(work.workKey),
        ),
      ],
      reviewedWorks: [
        ...retainedReviewedChanged,
        ...latest.reviewedWorks.where(
          (work) => !changed.containsKey(work.workKey),
        ),
      ],
      historyWorks:
          latest.historyWorks.any((work) => changed.containsKey(work.workKey))
          ? latest.historyWorks
                .map((work) => changed[work.workKey] ?? work)
                .toList(growable: false)
          : latest.historyWorks,
      pendingOperations: operations,
    );
    return _snapshot;
  }

  Future<AsmrAccountSnapshot> saveWorkReview(
    AsmrWork work, {
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
    DateTime? updatedAt,
    bool enqueueSync = true,
  }) {
    return _serialize(() async {
      final current = _snapshot;
      final normalizedRating =
          userRating != null && userRating >= 1 && userRating <= 5
          ? userRating
          : null;
      final normalizedText = AudioDetail.normalizeReviewText(reviewText);
      final hasReview =
          listenStatus != null ||
          normalizedRating != null ||
          normalizedText.isNotEmpty;
      final existing = current.reviewedByWorkKey[work.workKey];
      if (!hasReview &&
          existing == null &&
          !current.favoriteIds.contains(work.workKey)) {
        return current;
      }
      if (existing != null &&
          existing.listenStatus == listenStatus &&
          existing.userRating == normalizedRating &&
          existing.reviewText == normalizedText) {
        return current;
      }
      final effectiveUpdatedAt = updatedAt ?? _now();
      final base = existing?.mergedWith(work) ?? work;
      final updated = base.copyWith(
        listenStatus: listenStatus,
        clearListenStatus: listenStatus == null,
        isFavorite: listenStatus == WorkListenStatus.marked,
        userRating: normalizedRating,
        clearUserRating: normalizedRating == null,
        reviewText: normalizedText,
        reviewUpdatedAt: effectiveUpdatedAt,
      );
      final one = updated.resourceFor(AsmrCatalogSource.asmrOne);
      final operation = !enqueueSync || one == null || one.id <= 0
          ? null
          : AsmrSyncOperation(
              type: hasReview
                  ? AsmrSyncOperationType.reviewUpsert
                  : AsmrSyncOperationType.reviewDelete,
              workId: one.id,
              sourceId: updated.sourceId,
              createdAt: effectiveUpdatedAt,
              progress: listenStatus?.wireValue,
              userRating: normalizedRating,
              reviewText: normalizedText,
              hasReviewPayload: hasReview,
            );
      final operations = operation == null
          ? current.pendingOperations
          : _operationsAfterEnqueue(current.pendingOperations, operation);
      await _preferencesStore.saveReviewState(
        work: updated,
        favorite: updated.isFavorite,
        reviewed: hasReview,
        operation: operation,
      );
      final latest = _snapshot;
      _snapshot = latest.copyWith(
        favoriteWorks: [
          if (updated.isFavorite) updated,
          ...latest.favoriteWorks.where(
            (item) => item.workKey != updated.workKey,
          ),
        ],
        reviewedWorks: [
          if (hasReview) updated,
          ...latest.reviewedWorks.where(
            (item) => item.workKey != updated.workKey,
          ),
        ],
        historyWorks:
            latest.historyWorks.any((item) => item.workKey == updated.workKey)
            ? latest.historyWorks
                  .map(
                    (item) => item.workKey == updated.workKey ? updated : item,
                  )
                  .toList(growable: false)
            : latest.historyWorks,
        pendingOperations: operations,
      );
      return _snapshot;
    });
  }

  Future<AsmrAccountSnapshot> recordHistory(AsmrWork work) {
    return _serialize(() async {
      final current = _snapshot;
      final existingReview =
          current.reviewedByWorkKey[work.workKey] ??
          (current.favoriteIds.contains(work.workKey)
              ? current.favoriteWorks
                    .where((item) => item.workKey == work.workKey)
                    .firstOrNull
              : null);
      final historyWork =
          existingReview?.mergedWith(work) ??
          (work.isFavorite ? work.copyWith(isFavorite: false) : work);
      final history = <AsmrWork>[
        historyWork,
        ...current.historyWorks.where((item) => item.workKey != work.workKey),
      ].take(_historyLimit).toList(growable: false);
      final one = work.resourceFor(AsmrCatalogSource.asmrOne);
      final operation = one == null || one.id <= 0
          ? null
          : AsmrSyncOperation(
              type: AsmrSyncOperationType.historyListening,
              workId: one.id,
              sourceId: work.sourceId,
              createdAt: _now(),
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
      List<AsmrReviewRecord>? preflightReviews;
      if (batch.any(
        (operation) =>
            operation.type == AsmrSyncOperationType.historyListening ||
            operation.type == AsmrSyncOperationType.favoriteRemove,
      )) {
        preflightReviews = await _preflightProtectedProgress(
          session.token,
          language,
          token,
        );
      }
      final flushResult = await _flushOperations(session.token, batch, token);
      final remoteReviews =
          preflightReviews != null && !flushResult.mutatedRemoteReviews
          ? preflightReviews
          : await _fetchReviews(session.token, language, token);
      token.throwIfCancelled();
      await _serialize(() async {
        token.throwIfCancelled();
        // Stay inside the mutation queue while preparing the snapshot so an
        // intervening favorite/history action cannot be overwritten on return.
        final merged = await token.waitFor(
          compute(_prepareSyncedSnapshot, (
            current: _snapshot,
            remoteReviews: remoteReviews,
            uploaded: flushResult.uploaded,
          )),
        );
        token.throwIfCancelled();
        await _preferencesStore.saveAccountSyncState(
          favoriteWorks: merged.favoriteWorks,
          historyWorks: merged.historyWorks,
          operations: merged.pendingOperations,
          reviewedWorks: merged.reviewedWorks,
        );
        token.throwIfCancelled();
        _snapshot = merged;
        _lastFullPullAt = _now();
        return _snapshot;
      });
      shouldFullPull = false;
    } while (_snapshot.pendingOperations.isNotEmpty);
  }

  static bool _isUncollectedWorkError(Object error) {
    if (error is! AsmrApiException) return false;
    return error.statusCode == HttpStatus.notFound ||
        error.statusCode == HttpStatus.badRequest ||
        error.statusCode == HttpStatus.unprocessableEntity;
  }

  /// ASMR.ONE's /api/review route returns HTTP 500 when `work_id` violates the
  /// foreign-key constraint on `t_work` (for example, local DLsite or removed
  /// works). Confirm via `/api/workInfo/<id>` before treating 5xx as a failure.
  Future<bool> _isRejectedUncollectedWork(
    int workId,
    Object error,
    AsmrRequestCancellationToken token,
    Map<int, bool> collectedByWorkId,
  ) async {
    if (_isUncollectedWorkError(error)) return true;
    if (error is! AsmrApiException || error.statusCode < 500) return false;
    final cached = collectedByWorkId[workId];
    if (cached != null) return !cached;
    try {
      final collected = await _apiService.isWorkCollected(
        workId,
        cancellationToken: token,
      );
      collectedByWorkId[workId] = collected;
      return !collected;
    } on AsmrRequestCancelled {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  Future<({List<AsmrSyncOperation> uploaded, bool mutatedRemoteReviews})>
  _flushOperations(
    String tokenValue,
    List<AsmrSyncOperation> batch,
    AsmrRequestCancellationToken token,
  ) async {
    final uploaded = <AsmrSyncOperation>[];
    final failed = <AsmrSyncOperation>[];
    var mutatedRemoteReviews = false;
    final collectedByWorkId = <int, bool>{};
    Object? firstFailure;
    StackTrace? firstFailureStackTrace;
    Future<void> putAndTrack(int workId, String progress) async {
      await _putProgress(workId, progress, tokenValue, token);
      mutatedRemoteReviews = true;
    }

    for (final operation in batch) {
      token.throwIfCancelled();
      if (operation.workId <= 0) {
        uploaded.add(operation);
        continue;
      }
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
              mutatedRemoteReviews = true;
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
          case AsmrSyncOperationType.reviewUpsert:
            final nextStatus = WorkListenStatus.tryFromWireValue(
              operation.progress,
            );
            await _apiService.putReview(
              workId: operation.workId,
              token: tokenValue,
              progress: nextStatus,
              userRating: operation.userRating,
              reviewText: operation.reviewText ?? '',
            );
            mutatedRemoteReviews = true;
            await _serialize(() async {
              token.throwIfCancelled();
              if (_snapshot.session?.token != tokenValue) return;
              final updatedProgress = Map<int, String>.of(
                _snapshot.remoteProgressByWorkId,
              );
              if (nextStatus != null) {
                updatedProgress[operation.workId] = nextStatus.wireValue;
              } else {
                updatedProgress.remove(operation.workId);
              }
              _snapshot = _snapshot.copyWith(
                remoteProgressByWorkId: updatedProgress,
              );
            });
          case AsmrSyncOperationType.reviewDelete:
            await _apiService.deleteReview(
              workId: operation.workId,
              token: tokenValue,
            );
            mutatedRemoteReviews = true;
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
        }
        token.throwIfCancelled();
        uploaded.add(operation);
      } on AsmrRequestCancelled {
        rethrow;
      } catch (error, stackTrace) {
        token.throwIfCancelled();
        if (AsmrApiException.isAuthenticationError(error)) rethrow;
        if (await _isRejectedUncollectedWork(
          operation.workId,
          error,
          token,
          collectedByWorkId,
        )) {
          uploaded.add(operation);
          continue;
        }
        firstFailure ??= error;
        firstFailureStackTrace ??= stackTrace;
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
      Error.throwWithStackTrace(
        firstFailure ?? const HttpException('ASMR sync operations failed.'),
        firstFailureStackTrace ?? StackTrace.current,
      );
    }
    return (uploaded: uploaded, mutatedRemoteReviews: mutatedRemoteReviews);
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

  Future<List<AsmrReviewRecord>> _preflightProtectedProgress(
    String tokenValue,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) async {
    final reviews = await _fetchReviews(tokenValue, language, token);
    token.throwIfCancelled();
    final progress = await token.waitFor(compute(_progressByWorkId, reviews));
    token.throwIfCancelled();
    await _serialize(() async {
      token.throwIfCancelled();
      if (_snapshot.session?.token != tokenValue) return;
      _snapshot = _snapshot.copyWith(remoteProgressByWorkId: progress);
    });
    return reviews;
  }

  Future<List<AsmrReviewRecord>> _fetchReviews(
    String tokenValue,
    AsmrContentLanguage language,
    AsmrRequestCancellationToken token,
  ) async {
    final records = <AsmrReviewRecord>[];
    for (var page = 1; ; page++) {
      token.throwIfCancelled();
      final values = await _apiService.fetchReviews(
        token: tokenValue,
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

  static Map<int, String> _progressByWorkId(List<AsmrReviewRecord> reviews) =>
      immutableMap({
        for (final record in reviews)
          if (record.progress.isNotEmpty) record.work.id: record.progress,
      });

  static AsmrAccountSnapshot _prepareSyncedSnapshot(
    ({
      AsmrAccountSnapshot current,
      List<AsmrReviewRecord> remoteReviews,
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
      request.remoteReviews,
    ).copyWith(pendingOperations: operations);
  }

  static AsmrWork _workFromReviewRecord(AsmrReviewRecord record) {
    final listenStatus = record.listenStatus;
    final userRating = record.userRating ?? record.work.userRating;
    final reviewText = record.reviewText.isNotEmpty
        ? record.reviewText
        : record.work.reviewText;
    final updatedAt = record.updatedAt ?? record.work.reviewUpdatedAt;
    return record.work.copyWith(
      listenStatus: listenStatus,
      clearListenStatus: listenStatus == null,
      isFavorite: listenStatus == WorkListenStatus.marked,
      userRating: userRating,
      clearUserRating: userRating == null,
      reviewText: reviewText,
      reviewUpdatedAt: updatedAt,
      clearReviewUpdatedAt: updatedAt == null,
    );
  }

  static AsmrWork _withPendingReview(AsmrWork remote, AsmrWork local) =>
      remote.mergeResources(local.resources).copyWith(
        listenStatus: local.listenStatus,
        clearListenStatus: local.listenStatus == null,
        isFavorite: local.isFavorite,
        userRating: local.userRating,
        clearUserRating: local.userRating == null,
        reviewText: local.reviewText,
        reviewUpdatedAt: local.reviewUpdatedAt,
      );

  static AsmrAccountSnapshot _mergeRemoteState(
    AsmrAccountSnapshot current,
    List<AsmrReviewRecord> records,
  ) {
    final pendingRemoves = current.pendingOperations
        .where((item) => item.type == AsmrSyncOperationType.favoriteRemove)
        .map((item) => item.workId)
        .toSet();
    final pendingDeletes = current.pendingOperations
        .where((item) => item.type == AsmrSyncOperationType.reviewDelete)
        .map((item) => item.workId)
        .toSet();
    final pendingFavoriteAdds = current.pendingOperations
        .where((item) => item.type == AsmrSyncOperationType.favoriteAdd)
        .map((item) => item.workId)
        .toSet();
    final pendingReviewUpserts = <int, AsmrSyncOperation>{
      for (final item in current.pendingOperations)
        if (item.type == AsmrSyncOperationType.reviewUpsert) item.workId: item,
    };

    final sortedRecords = records.toList(growable: false)..sort(_newestFirst);
    final remoteWorkByOneId = <int, AsmrWork>{};
    for (final record in sortedRecords) {
      if (pendingDeletes.contains(record.work.id)) continue;
      if (pendingRemoves.contains(record.work.id) &&
          record.progress == 'marked') {
        continue;
      }
      remoteWorkByOneId.putIfAbsent(
        record.work.id,
        () => _workFromReviewRecord(record),
      );
    }

    final favoriteById = <String, AsmrWork>{};
    for (final work in current.favoriteWorks) {
      final oneId = work.resourceFor(AsmrCatalogSource.asmrOne)?.id;
      if (oneId != null &&
          (pendingRemoves.contains(oneId) || pendingDeletes.contains(oneId))) {
        continue;
      }
      if (oneId != null &&
          !pendingFavoriteAdds.contains(oneId) &&
          !pendingReviewUpserts.containsKey(oneId)) {
        final remote = remoteWorkByOneId[oneId];
        if (remote != null && remote.listenStatus != WorkListenStatus.marked) {
          // Remote moved this work from 'marked' to another status.
          continue;
        }
      }
      favoriteById[work.workKey] = work.copyWith(isFavorite: true);
    }
    final remoteFavorites = sortedRecords.where(
      (record) => record.progress == 'marked',
    );
    for (final record in remoteFavorites) {
      if (pendingRemoves.contains(record.work.id) ||
          pendingDeletes.contains(record.work.id)) {
        continue;
      }
      final pendingUpsert = pendingReviewUpserts[record.work.id];
      if (pendingUpsert != null && pendingUpsert.progress != 'marked') {
        continue;
      }
      final pulled = _workFromReviewRecord(record);
      final pendingReview = pendingUpsert == null
          ? null
          : current.reviewedByWorkKey[pulled.workKey];
      final remoteWork = pendingReview == null
          ? pulled
          : _withPendingReview(pulled, pendingReview);
      favoriteById.update(
        remoteWork.workKey,
        (local) => local.mergedWith(remoteWork).copyWith(isFavorite: true),
        ifAbsent: () => remoteWork.copyWith(isFavorite: true),
      );
    }

    final reviewedById = <String, AsmrWork>{};
    // Insert remote reviews newest-first first, then retain local-only reviews.
    for (final record in sortedRecords) {
      if (pendingDeletes.contains(record.work.id)) continue;
      if (pendingRemoves.contains(record.work.id) &&
          record.progress == 'marked') {
        continue;
      }
      final remoteWork = _workFromReviewRecord(record);
      if (!remoteWork.hasUserReview) continue;
      final local = current.reviewedByWorkKey[remoteWork.workKey];
      if (pendingReviewUpserts.containsKey(record.work.id) && local != null) {
        reviewedById[remoteWork.workKey] = _withPendingReview(remoteWork, local);
      } else {
        reviewedById[remoteWork.workKey] = local == null
            ? remoteWork
            : local.mergedWith(remoteWork);
      }
    }
    for (final work in current.reviewedWorks) {
      final oneId = work.resourceFor(AsmrCatalogSource.asmrOne)?.id;
      if (oneId != null && pendingDeletes.contains(oneId)) continue;
      if (oneId != null &&
          pendingRemoves.contains(oneId) &&
          work.listenStatus == WorkListenStatus.marked &&
          work.userRating == null &&
          work.reviewText.isEmpty) {
        continue;
      }
      if (!work.hasUserReview) continue;
      reviewedById.putIfAbsent(work.workKey, () => work);
    }

    final history = <AsmrWork>[];
    final historyIndexByKey = <String, int>{};
    for (final work in current.historyWorks) {
      historyIndexByKey.putIfAbsent(work.workKey, () {
        history.add(work);
        return history.length - 1;
      });
    }
    final remoteHistory = sortedRecords.where(
      (record) => record.progress != 'marked' && record.progress.isNotEmpty,
    );
    for (final record in remoteHistory) {
      if (pendingDeletes.contains(record.work.id)) continue;
      final remoteWork = _workFromReviewRecord(record);
      final existingIndex = historyIndexByKey[remoteWork.workKey];
      if (existingIndex == null) {
        historyIndexByKey[remoteWork.workKey] = history.length;
        history.add(remoteWork);
      } else {
        history[existingIndex] = history[existingIndex].mergedWith(remoteWork);
      }
    }
    final normalized = _normalizeAccountWorks((
      favoriteWorks: favoriteById.values.toList(growable: false),
      reviewedWorks: reviewedById.values.toList(growable: false),
      historyWorks: history.take(_historyLimit).toList(growable: false),
    ));
    return current.copyWith(
      favoriteWorks: normalized.favoriteWorks,
      reviewedWorks: normalized.reviewedWorks,
      historyWorks: normalized.historyWorks,
      remoteProgressByWorkId: <int, String>{
        for (final record in records)
          if (record.progress.isNotEmpty &&
              !pendingDeletes.contains(record.work.id) &&
              !(pendingRemoves.contains(record.work.id) &&
                  record.progress == 'marked'))
            record.work.id: record.progress,
      },
    );
  }

  static ({
    List<AsmrWork> favoriteWorks,
    List<AsmrWork> reviewedWorks,
    List<AsmrWork> historyWorks,
  })
  _normalizeAccountWorks(
    ({
      List<AsmrWork> favoriteWorks,
      List<AsmrWork> reviewedWorks,
      List<AsmrWork> historyWorks,
    })
    works,
  ) {
    final favoriteById = <String, AsmrWork>{};
    for (final work in works.favoriteWorks) {
      favoriteById.update(
        work.workKey,
        (existing) => existing
            .mergedWith(work)
            .copyWith(isFavorite: true, listenStatus: WorkListenStatus.marked),
        ifAbsent: () => work.copyWith(
          isFavorite: true,
          listenStatus: WorkListenStatus.marked,
        ),
      );
    }

    final reviewedById = <String, AsmrWork>{};
    for (final work in works.reviewedWorks) {
      if (!work.hasUserReview) continue;
      final fav = favoriteById[work.workKey];
      final resolved = fav != null
          ? fav
                .mergedWith(work)
                .copyWith(
                  isFavorite: true,
                  listenStatus: WorkListenStatus.marked,
                )
          : (work.listenStatus == WorkListenStatus.marked
                ? work.copyWith(isFavorite: false, clearListenStatus: true)
                : work.copyWith(isFavorite: false));
      if (!resolved.hasUserReview) continue;
      reviewedById.update(
        resolved.workKey,
        (existing) => existing.mergedWith(resolved),
        ifAbsent: () => resolved,
      );
      if (fav != null) {
        favoriteById[resolved.workKey] = resolved;
      }
    }
    for (final fav in favoriteById.values) {
      reviewedById.putIfAbsent(fav.workKey, () => fav);
    }

    final normalizedHistory = <AsmrWork>[];
    final seenHistoryIds = <String>{};
    for (final work in works.historyWorks) {
      if (!seenHistoryIds.add(work.workKey)) continue;
      final reviewed = reviewedById[work.workKey];
      if (reviewed != null) {
        normalizedHistory.add(
          work
              .mergedWith(reviewed)
              .copyWith(
                listenStatus: reviewed.listenStatus,
                clearListenStatus: reviewed.listenStatus == null,
                isFavorite: reviewed.isFavorite,
                userRating: reviewed.userRating,
                clearUserRating: reviewed.userRating == null,
                reviewText: reviewed.reviewText,
                reviewUpdatedAt: reviewed.reviewUpdatedAt,
              ),
        );
      } else {
        normalizedHistory.add(work.copyWith(isFavorite: false));
      }
    }
    return (
      favoriteWorks: favoriteById.values.toList(growable: false),
      reviewedWorks: reviewedById.values.toList(growable: false),
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
      final one = work.resourceFor(AsmrCatalogSource.asmrOne);
      if (one == null || one.id <= 0) continue;
      final key = '${AsmrSyncOperationType.historyListening.name}:${one.id}';
      if (keys.add(key)) {
        operations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.historyListening,
            workId: one.id,
            sourceId: work.sourceId,
            createdAt: createdAt,
          ),
        );
        createdAt = createdAt.add(const Duration(milliseconds: 1));
      }
    }
    for (final work in _snapshot.favoriteWorks.reversed) {
      final one = work.resourceFor(AsmrCatalogSource.asmrOne);
      if (one == null || one.id <= 0) continue;
      final key = '${AsmrSyncOperationType.favoriteAdd.name}:${one.id}';
      if (keys.add(key)) {
        operations.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.favoriteAdd,
            workId: one.id,
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
        if (operation.type == AsmrSyncOperationType.reviewUpsert ||
            operation.type == AsmrSyncOperationType.reviewDelete) {
          return false;
        }
        if (operation.type == AsmrSyncOperationType.favoriteAdd ||
            operation.type == AsmrSyncOperationType.favoriteRemove) {
          return existing.type != AsmrSyncOperationType.favoriteAdd &&
              existing.type != AsmrSyncOperationType.favoriteRemove &&
              existing.type != AsmrSyncOperationType.reviewUpsert &&
              existing.type != AsmrSyncOperationType.reviewDelete;
        }
        if (operation.type == AsmrSyncOperationType.historyListening &&
            (existing.type == AsmrSyncOperationType.reviewUpsert ||
                existing.type == AsmrSyncOperationType.reviewDelete)) {
          return true;
        }
        return existing.type != operation.type;
      }),
      if (operation.type != AsmrSyncOperationType.historyListening ||
          !current.any(
            (existing) =>
                existing.workId == operation.workId &&
                existing.type == AsmrSyncOperationType.reviewUpsert &&
                (WorkListenStatus.tryFromWireValue(
                      existing.progress,
                    )?.isProtectedFromAutoListening ??
                    false),
          ))
        operation,
    ];
  }

  bool _isProtected(int workId) {
    final progress = _snapshot.remoteProgressByWorkId[workId];
    if (progress == 'marked' ||
        progress == 'listened' ||
        progress == 'replay' ||
        progress == 'postponed') {
      return true;
    }
    return _snapshot._hasProtectedReview(workId);
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
