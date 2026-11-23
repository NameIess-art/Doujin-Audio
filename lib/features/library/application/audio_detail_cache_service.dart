import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/json_document_store.dart';
import 'audio_detail_repository.dart';

class AudioDetailCacheChange {
  const AudioDetailCacheChange({required this.revision, this.targetKeys});

  final int revision;
  // A null set invalidates every target after reset or replacement.
  final Set<String>? targetKeys;

  bool affectsKey(String targetKey) => targetKeys?.contains(targetKey) ?? true;

  bool affects(AudioDetailTarget target) {
    final keys = targetKeys;
    if (keys == null) return true;
    if (keys.isEmpty) return false;
    return keys.contains(AudioLibraryDetailKey.forTarget(target));
  }
}

final class _AudioDetailReadRequest {
  _AudioDetailReadRequest({
    required this.key,
    required this.target,
    required this.epoch,
  });

  final String key;
  final AudioDetailTarget target;
  final int epoch;
  final result = Completer<AudioDetailLoadResult>();
  late final Future<AudioDetailLoadResult> future;
  late final Future<void> tail;
  final _requesters = <bool Function()>[];
  bool _hasUnscopedRequester = false;
  bool cancelled = false;

  bool get isActive =>
      _hasUnscopedRequester || _requesters.any((isActive) => isActive());

  void addRequester(bool Function()? isActive) {
    if (isActive == null) {
      _hasUnscopedRequester = true;
    } else {
      _requesters.add(isActive);
    }
  }
}

class AudioDetailCacheService {
  AudioDetailCacheService({
    required AudioDetailRepository repository,
    int maxResolvedEntries = 2000,
  }) : assert(maxResolvedEntries > 0),
       _repository = repository,
       _maxResolvedEntries = maxResolvedEntries;

  final AudioDetailRepository _repository;
  final int _maxResolvedEntries;
  final Map<String, _AudioDetailReadRequest> _loadFutures = {};
  final _pendingReads = Queue<_AudioDetailReadRequest>();
  bool _reading = false;
  final _changes = StreamController<AudioDetailCacheChange>.broadcast();
  final LinkedHashMap<String, AudioDetailLoadResult> _resolved =
      LinkedHashMap<String, AudioDetailLoadResult>();
  final Map<String, Future<void>> _operationTails = <String, Future<void>>{};
  int _revision = 0;
  int _workTitleRevision = 0;
  int _voiceActorRevision = 0;
  int _releaseDateRevision = 0;
  int _cacheEpoch = 0;
  bool _suspended = false;

  int get revision => _revision;
  int get workTitleRevision => _workTitleRevision;
  int get voiceActorRevision => _voiceActorRevision;
  int get releaseDateRevision => _releaseDateRevision;
  Stream<AudioDetailCacheChange> get changes => _changes.stream;

  AudioDetail? resolvedDetail(AudioDetailTarget target) {
    return _resolved[AudioLibraryDetailKey.forTarget(target)]?.detail;
  }

  Future<AudioDetailLoadResult> load(
    AudioDetailTarget target, {
    bool Function()? isActive,
  }) {
    if (_suspended) {
      return Future<AudioDetailLoadResult>.error(
        const AudioDetailOperationCancelled(),
      );
    }
    final key = AudioLibraryDetailKey.forTarget(target);
    final predecessor = _operationTails[key];
    final cached = predecessor == null ? _takeResolved(key) : null;
    if (cached != null) return Future<AudioDetailLoadResult>.value(cached);
    final existing = _loadFutures[key];
    if (existing != null &&
        !existing.cancelled &&
        identical(existing.tail, predecessor)) {
      existing.addRequester(isActive);
      return existing.future;
    }
    final epoch = _cacheEpoch;
    final request = _AudioDetailReadRequest(
      key: key,
      target: target,
      epoch: epoch,
    )..addRequester(isActive);
    final future = request.future = _runSerialized<AudioDetailLoadResult>(
      <AudioDetailTarget>[target],
      () async {
        if (epoch != _cacheEpoch || !request.isActive) {
          request.cancelled = true;
          _releaseLoadFuture(request);
          throw const AudioDetailOperationCancelled();
        }
        final resolved = _takeResolved(key);
        if (resolved != null) {
          _releaseLoadFuture(request);
          return resolved;
        }
        _pendingReads.add(request);
        _scheduleReads();
        return request.result.future;
      },
    );
    request.tail = _operationTails[key]!;
    _loadFutures[key] = request;
    unawaited(
      future.then<void>(
        (_) => _releaseLoadFuture(request),
        onError: (Object error, StackTrace stackTrace) =>
            _releaseLoadFuture(request),
      ),
    );
    return future;
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets, {
    bool Function()? isActive,
  }) {
    if (_suspended) {
      return Future<List<AudioDetailLoadResult>>.error(
        const AudioDetailOperationCancelled(),
      );
    }
    final values = targets.toList(growable: false);
    if (values.isEmpty) {
      return Future<List<AudioDetailLoadResult>>.value(
        const <AudioDetailLoadResult>[],
      );
    }
    if (values.length == 1) {
      return load(
        values.first,
        isActive: isActive,
      ).then((result) => <AudioDetailLoadResult>[result]);
    }
    final requestKeys = <String>[];
    final resolvedByKey = <String, AudioDetailLoadResult>{};
    final futuresByKey = <String, Future<AudioDetailLoadResult>>{};
    final toLoad = <_AudioDetailReadRequest>[];
    final epoch = _cacheEpoch;

    for (final target in values) {
      final key = AudioLibraryDetailKey.forTarget(target);
      requestKeys.add(key);
      if (resolvedByKey.containsKey(key) || futuresByKey.containsKey(key)) {
        continue;
      }
      final predecessor = _operationTails[key];
      final cached = predecessor == null ? _takeResolved(key) : null;
      if (cached != null) {
        resolvedByKey[key] = cached;
        continue;
      }
      final existing = _loadFutures[key];
      if (existing != null &&
          !existing.cancelled &&
          identical(existing.tail, predecessor)) {
        existing.addRequester(isActive);
        futuresByKey[key] = existing.future;
        continue;
      }
      final request = _AudioDetailReadRequest(
        key: key,
        target: target,
        epoch: epoch,
      )..addRequester(isActive);
      request.future = request.result.future;
      futuresByKey[key] = request.future;
      toLoad.add(request);
    }

    if (toLoad.isNotEmpty) {
      final batchTargets = [for (final request in toLoad) request.target];
      final batchExecution = _runSerialized<void>(batchTargets, () async {
        final queued = <_AudioDetailReadRequest>[];
        for (final request in toLoad) {
          if (epoch != _cacheEpoch || !request.isActive) {
            request.cancelled = true;
            _releaseLoadFuture(request);
            if (!request.result.isCompleted) {
              request.result.completeError(
                const AudioDetailOperationCancelled(),
              );
            }
            continue;
          }
          final resolved = _takeResolved(request.key);
          if (resolved != null) {
            _releaseLoadFuture(request);
            if (!request.result.isCompleted) {
              request.result.complete(resolved);
            }
            continue;
          }
          queued.add(request);
          _pendingReads.add(request);
        }
        if (queued.isEmpty) return;
        _scheduleReads();
        await Future.wait<void>(
          queued.map(
            (request) =>
                request.result.future.then<void>((_) {}, onError: (_, _) {}),
          ),
        );
      });
      final batchTail = _operationTails[toLoad.first.key]!;
      for (final request in toLoad) {
        request.tail = batchTail;
        _loadFutures[request.key] = request;
      }
      unawaited(
        batchExecution.then<void>(
          (_) {
            for (final request in toLoad) {
              _releaseLoadFuture(request);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            for (final request in toLoad) {
              _releaseLoadFuture(request);
              if (!request.result.isCompleted) {
                request.cancelled = true;
                request.result.completeError(error, stackTrace);
              }
            }
          },
        ),
      );
    }

    if (futuresByKey.isEmpty) {
      return Future<List<AudioDetailLoadResult>>.value([
        for (final key in requestKeys) resolvedByKey[key]!,
      ]);
    }
    final pendingKeys = futuresByKey.keys.toList(growable: false);
    return Future.wait(pendingKeys.map((key) => futuresByKey[key]!)).then((
      loaded,
    ) {
      for (var index = 0; index < pendingKeys.length; index++) {
        resolvedByKey[pendingKeys[index]] = loaded[index];
      }
      return [for (final key in requestKeys) resolvedByKey[key]!];
    });
  }

  Future<Map<String, Duration?>?> loadDurationsIfSupported(
    Iterable<AudioDetailTarget> targets,
  ) async {
    if (_suspended) {
      throw const AudioDetailOperationCancelled();
    }
    if (!_repository.supportsFastQueries) return null;
    final values = targets.toList(growable: false);
    if (values.isEmpty) return const <String, Duration?>{};
    final result = <String, Duration?>{};
    final inFlightTargets = <AudioDetailTarget>[];
    final toQuery = <AudioDetailTarget>[];
    final seen = <String>{};
    for (final target in values) {
      final key = AudioLibraryDetailKey.forTarget(target);
      if (!seen.add(key)) continue;
      if (_operationTails[key] != null) {
        inFlightTargets.add(target);
        continue;
      }
      final cached = _resolved[key];
      if (cached != null) {
        if (!cached.detail.isEmpty || cached.detail.duration != null) {
          result[key] = cached.detail.duration;
        }
        continue;
      }
      toQuery.add(target);
    }
    if (inFlightTargets.isNotEmpty) {
      final loaded = await loadMany(inFlightTargets);
      for (var index = 0; index < inFlightTargets.length; index++) {
        final detail = loaded[index].detail;
        if (!detail.isEmpty || detail.duration != null) {
          result[AudioLibraryDetailKey.forTarget(inFlightTargets[index])] =
              detail.duration;
        }
      }
    }
    if (toQuery.isNotEmpty) {
      final queried = await _repository.loadDurationsIfSupported(toQuery);
      if (queried != null) {
        result.addAll(queried);
      }
    }
    return result;
  }

  /// Loads search-relevant detail projections. Uses the lightweight SQLite
  /// projection query when supported without evicting `_resolved` LRU entries,
  /// and falls back to `loadMany` otherwise.
  Future<List<AudioDetail>> loadSearchDetails(
    Iterable<AudioDetailTarget> targets, {
    bool Function()? isActive,
  }) async {
    if (_suspended) {
      throw const AudioDetailOperationCancelled();
    }
    if (!_repository.supportsFastQueries) {
      final loaded = await loadMany(targets, isActive: isActive);
      return <AudioDetail>[for (final entry in loaded) entry.detail];
    }
    final values = targets.toList(growable: false);
    if (values.isEmpty) return const <AudioDetail>[];
    if (isActive?.call() == false) {
      throw const AudioDetailOperationCancelled();
    }
    final requestKeys = <String>[];
    final byKey = <String, AudioDetail>{};
    final inFlightTargets = <AudioDetailTarget>[];
    final uncachedTargets = <AudioDetailTarget>[];
    final seen = <String>{};
    for (final target in values) {
      final key = AudioLibraryDetailKey.forTarget(target);
      requestKeys.add(key);
      if (!seen.add(key)) continue;
      if (_operationTails[key] != null) {
        inFlightTargets.add(target);
        continue;
      }
      final cached = _resolved[key];
      if (cached != null) {
        byKey[key] = cached.detail;
        continue;
      }
      uncachedTargets.add(target);
    }
    if (inFlightTargets.isNotEmpty) {
      final loaded = await loadMany(inFlightTargets, isActive: isActive);
      for (var i = 0; i < inFlightTargets.length; i++) {
        byKey[AudioLibraryDetailKey.forTarget(inFlightTargets[i])] =
            loaded[i].detail;
      }
    }
    if (uncachedTargets.isNotEmpty) {
      if (isActive?.call() == false) {
        throw const AudioDetailOperationCancelled();
      }
      final queried = await _repository.loadSearchDetails(uncachedTargets);
      for (var i = 0; i < uncachedTargets.length; i++) {
        byKey[AudioLibraryDetailKey.forTarget(uncachedTargets[i])] = queried[i];
      }
    }
    return <AudioDetail>[
      for (var i = 0; i < requestKeys.length; i++)
        byKey[requestKeys[i]] ?? AudioDetail.empty(values[i]),
    ];
  }

  void _releaseLoadFuture(_AudioDetailReadRequest request) {
    if (identical(_loadFutures[request.key], request)) {
      _loadFutures.remove(request.key);
    }
  }

  void _scheduleReads() {
    if (_reading) return;
    _reading = true;
    // Collect the visible rows together, yielding to input before each batch.
    unawaited(
      Future<void>(() async {
        try {
          while (_pendingReads.isNotEmpty) {
            final count = _pendingReads.length.clamp(0, 64);
            final batch = List.generate(
              count,
              (_) => _pendingReads.removeFirst(),
              growable: false,
            );
            final active = <_AudioDetailReadRequest>[];
            for (final read in batch) {
              // A fling can recycle rows while the preceding DB batch is busy.
              // Keep shared or unscoped callers, but skip abandoned card reads.
              if (read.epoch != _cacheEpoch || !read.isActive) {
                read.cancelled = true;
                _releaseLoadFuture(read);
                read.result.completeError(
                  const AudioDetailOperationCancelled(),
                );
              } else {
                active.add(read);
              }
            }
            if (active.isNotEmpty) {
              try {
                final results = await _repository.loadMany(
                  active.map((read) => read.target),
                );
                for (var index = 0; index < active.length; index++) {
                  final read = active[index];
                  _releaseLoadFuture(read);
                  if (read.epoch != _cacheEpoch) {
                    read.result.completeError(
                      const AudioDetailOperationCancelled(),
                    );
                  } else {
                    final loaded = results[index];
                    final resultKey = AudioLibraryDetailKey.forTarget(
                      loaded.detail.target,
                    );
                    _storeResolved(resultKey, loaded);
                    if (resultKey != read.key) {
                      _storeResolved(read.key, loaded);
                    }
                    read.result.complete(loaded);
                  }
                }
              } catch (error, stackTrace) {
                for (final read in active) {
                  _releaseLoadFuture(read);
                  if (!read.result.isCompleted) {
                    read.result.completeError(error, stackTrace);
                  }
                }
              }
            }
            if (_pendingReads.isNotEmpty) {
              await Future<void>.delayed(Duration.zero);
            }
          }
        } finally {
          _reading = false;
          if (_pendingReads.isNotEmpty) _scheduleReads();
        }
      }),
    );
  }

  Future<AudioDetailBackupImportResult> importBackupsMany(
    Iterable<AudioDetailTarget> targets,
  ) {
    final values = targets.toList(growable: false);
    if (values.isEmpty) {
      return Future<AudioDetailBackupImportResult>.value(
        const AudioDetailBackupImportResult(),
      );
    }
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailBackupImportResult>(values, () async {
      final result = await _repository.importBackupsMany(values);
      if (epoch != _cacheEpoch) {
        throw const AudioDetailOperationCancelled();
      }
      if (result.changedDetails.isNotEmpty) {
        for (final detail in result.changedDetails) {
          _store(detail);
        }
        _bumpRevision(result.changedDetails.map((detail) => detail.target));
      }
      return result;
    });
  }

  Future<AudioDetailSaveResult> save(
    AudioDetail detail, {
    bool preserveExistingDuration = false,
  }) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailSaveResult>(
      <AudioDetailTarget>[detail.target],
      () async {
        var next = detail;
        if (preserveExistingDuration && next.duration == null) {
          // Read inside the queue so a preceding probe can finish committing.
          final latest = (await _repository.load(next.target)).detail;
          next = next.copyWith(duration: latest.duration);
        }
        final result = await _repository.save(next);
        if (epoch != _cacheEpoch) {
          throw const AudioDetailOperationCancelled();
        }
        _store(result.detail);
        _bumpRevision([result.detail.target]);
        return result;
      },
    );
  }

  Future<bool> exportTimeSegments(AudioDetailTarget target) =>
      _runSerialized<bool>(<AudioDetailTarget>[
        target,
      ], () => _repository.exportTimeSegments(target));

  Future<AudioDetailSaveResult> retarget(
    AudioDetailTarget previousTarget,
    AudioDetail detail,
  ) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailSaveResult>(
      <AudioDetailTarget>[previousTarget, detail.target],
      () async {
        final result = await _repository.retarget(previousTarget, detail);
        if (epoch != _cacheEpoch) {
          throw const AudioDetailOperationCancelled();
        }
        _remove(previousTarget);
        _store(result.detail);
        _bumpRevision([previousTarget, result.detail.target]);
        return result;
      },
    );
  }

  Future<AudioDetail> updateDerivedFields(
    AudioDetailTarget target, {
    String? rjCode,
    Duration? duration,
    String? cardCoverPath,
    bool? cardCoverSelected,
  }) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetail>(<AudioDetailTarget>[target], () async {
      final result = await _repository.updateDerivedFields(
        target,
        rjCode: rjCode,
        duration: duration,
        cardCoverPath: cardCoverPath,
        cardCoverSelected: cardCoverSelected,
      );
      if (epoch != _cacheEpoch) {
        throw const AudioDetailOperationCancelled();
      }
      _store(result);
      _bumpRevision([result.target]);
      return result;
    });
  }

  Future<AudioDetailSaveResult> saveMissingDuration(
    AudioDetailTarget target,
    Duration duration, {
    bool skipSynchronizedDocument = false,
  }) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailSaveResult>([target], () async {
      final cached = _takeResolved(AudioLibraryDetailKey.forTarget(target));
      if (skipSynchronizedDocument &&
          cached?.durationDocumentSynchronized == true) {
        return AudioDetailSaveResult(
          detail: cached!.detail,
          documentStatus: JsonDocumentWriteStatus.preserved,
        );
      }
      final previousDuration = cached?.detail.duration;
      final result = await _repository.saveMissingDuration(
        target,
        duration,
        cachedDetail: cached?.detail,
      );
      if (epoch != _cacheEpoch) {
        throw const AudioDetailOperationCancelled();
      }
      _store(
        result.detail,
        durationDocumentSynchronized: !result.documentFailed,
      );
      if (previousDuration != result.detail.duration) {
        _bumpRevision([result.detail.target]);
      }
      return result;
    });
  }

  Future<String?> loadCardCoverPath(AudioDetailTarget target) async {
    return (await loadCardCoverSelection(target)).path;
  }

  Future<({String? path, bool selected})> loadCardCoverSelection(
    AudioDetailTarget target,
  ) async {
    final detail = (await load(target)).detail;
    return (path: detail.cardCoverPath, selected: detail.cardCoverSelected);
  }

  Future<String?> saveCardCoverPath(
    AudioDetailTarget target,
    String? coverPath, {
    bool? selected,
    bool writeDocument = false,
  }) {
    final epoch = _cacheEpoch;
    return _runSerialized<String?>(<AudioDetailTarget>[target], () async {
      // A cover-only edit must retain authored fields even before startup import.
      var current = (await _repository.load(target)).detail;
      var imported = const AudioDetailBackupImportResult();
      if (writeDocument &&
          current.updatedAt == null &&
          current.workTitle.isEmpty &&
          current.circleName.isEmpty &&
          current.voiceActors.isEmpty &&
          current.tags.isEmpty) {
        imported = await _repository.importBackupsMany([target]);
        current = (await _repository.load(target)).detail;
      }
      if (epoch != _cacheEpoch) throw const AudioDetailOperationCancelled();
      final normalizedPath = coverPath?.trim();
      final nextPath = normalizedPath == null || normalizedPath.isEmpty
          ? null
          : normalizedPath;
      final nextSelected = nextPath == null
          ? false
          : selected ??
                (current.cardCoverPath == nextPath &&
                    current.cardCoverSelected);
      if (current.cardCoverPath == nextPath &&
          current.cardCoverSelected == nextSelected) {
        _store(current);
        if (imported.changedDetails.isNotEmpty) _bumpRevision([current.target]);
        return current.cardCoverPath;
      }
      final AudioDetail updated;
      if (writeDocument) {
        updated = (await _repository.save(
          current.copyWith(
            cardCoverPath: nextPath,
            cardCoverSelected: nextSelected,
          ),
        )).detail;
      } else {
        updated = await _repository.updateDerivedFields(
          target,
          cardCoverPath: nextPath,
          cardCoverSelected: nextSelected,
        );
      }
      if (epoch != _cacheEpoch) throw const AudioDetailOperationCancelled();
      _store(updated);
      _bumpRevision([updated.target]);
      return updated.cardCoverPath;
    });
  }

  Future<void> delete(AudioDetailTarget target) async {
    final epoch = _cacheEpoch;
    await _runSerialized<void>(<AudioDetailTarget>[target], () async {
      await _repository.delete(target);
      if (epoch != _cacheEpoch) {
        throw const AudioDetailOperationCancelled();
      }
      _remove(target);
      _bumpRevision([target]);
    });
  }

  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) async {
    final values = targets.toList(growable: false);
    if (values.isEmpty) return;
    final epoch = _cacheEpoch;
    await _runSerialized<void>(values, () async {
      await _repository.deleteMany(values);
      if (epoch != _cacheEpoch) {
        throw const AudioDetailOperationCancelled();
      }
      for (final target in values) {
        _remove(target);
      }
      _bumpRevision(values);
    });
  }

  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailSaveResult?>(
      <AudioDetailTarget>[target],
      () async {
        final result = await _repository.prefillRjCodeFromText(target, text);
        if (epoch != _cacheEpoch) {
          throw const AudioDetailOperationCancelled();
        }
        if (result == null) return null;
        _store(result.detail);
        _bumpRevision([result.detail.target]);
        return result;
      },
    );
  }

  void markChanged(AudioDetail detail) {
    _store(detail);
    _bumpRevision([detail.target]);
  }

  void clear() {
    _cacheEpoch++;
    _loadFutures.clear();
    _resolved.clear();
    _workTitleRevision++;
    _voiceActorRevision++;
    _releaseDateRevision++;
    _bumpRevision();
  }

  void trimMemory() {
    final targetSize = (_maxResolvedEntries ~/ 10).clamp(
      0,
      _maxResolvedEntries,
    );
    while (_resolved.length > targetSize) {
      _resolved.remove(_resolved.keys.first);
    }
  }

  Future<void> suspendAndWait() async {
    _suspended = true;
    clear();
    final pending = _operationTails.values.toSet().toList(growable: false);
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  Future<void> waitForPendingOperations() async {
    final pending = _operationTails.values.toSet().toList(growable: false);
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  void resume() {
    _suspended = false;
  }

  Future<T> _runSerialized<T>(
    Iterable<AudioDetailTarget> targets,
    Future<T> Function() operation,
  ) {
    if (_suspended) {
      return Future<T>.error(const AudioDetailOperationCancelled());
    }
    final keys =
        targets
            .map(AudioLibraryDetailKey.forTarget)
            .toSet()
            .toList(growable: false)
          ..sort();
    final epoch = _cacheEpoch;
    final predecessors = <Future<void>>[
      for (final key in keys) ?_operationTails[key],
    ];
    final future = Future.wait(predecessors).then(
      (_) => AudioDetailRepository.runWithCommitGuard<T>(
        () => epoch == _cacheEpoch,
        operation,
      ),
    );
    final tail = future.then<void>((_) {}, onError: (_, _) {});
    for (final key in keys) {
      _operationTails[key] = tail;
    }
    unawaited(
      tail.then((_) {
        for (final key in keys) {
          if (identical(_operationTails[key], tail)) {
            _operationTails.remove(key);
          }
        }
      }),
    );
    return future;
  }

  void _store(AudioDetail detail, {bool durationDocumentSynchronized = false}) {
    final previous = resolvedDetail(detail.target);
    if (previous?.workTitle != detail.workTitle) _workTitleRevision++;
    if (!listEquals(previous?.voiceActors, detail.voiceActors)) {
      _voiceActorRevision++;
    }
    if (previous?.releaseDate != detail.releaseDate) _releaseDateRevision++;
    _storeLoadResult(
      AudioDetailLoadResult(
        detail: detail,
        durationDocumentSynchronized: durationDocumentSynchronized,
      ),
    );
  }

  void _storeLoadResult(AudioDetailLoadResult loadResult) {
    final key = AudioLibraryDetailKey.forTarget(loadResult.detail.target);
    _storeResolved(key, loadResult);
  }

  void _storeResolved(String key, AudioDetailLoadResult loadResult) {
    _resolved.remove(key);
    _resolved[key] = loadResult;
    while (_resolved.length > _maxResolvedEntries) {
      _resolved.remove(_resolved.keys.first);
    }
  }

  AudioDetailLoadResult? _takeResolved(String key) {
    final value = _resolved.remove(key);
    if (value != null) _resolved[key] = value;
    return value;
  }

  void _remove(AudioDetailTarget target) {
    final key = AudioLibraryDetailKey.forTarget(target);
    _resolved.remove(key);
    _loadFutures.remove(key);
    _workTitleRevision++;
    _voiceActorRevision++;
    _releaseDateRevision++;
  }

  void _bumpRevision([Iterable<AudioDetailTarget>? targets]) {
    _revision++;
    _changes.add(
      AudioDetailCacheChange(
        revision: _revision,
        targetKeys: targets == null
            ? null
            : Set<String>.unmodifiable(
                targets.map(AudioLibraryDetailKey.forTarget),
              ),
      ),
    );
  }

  Future<void> dispose() async {
    await suspendAndWait();
    await _changes.close();
  }
}

class AudioLibraryDetailKey {
  const AudioLibraryDetailKey._();

  static String forTarget(AudioDetailTarget target) {
    return '${target.targetType.dbValue}|${PathMatcher.equivalenceKey(target.targetPath)}';
  }
}
