import 'dart:async';
import 'dart:collection';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
import 'audio_detail_repository.dart';

class AudioDetailCacheService {
  AudioDetailCacheService({
    required AudioDetailRepository repository,
    int maxResolvedEntries = 2000,
  }) : assert(maxResolvedEntries > 0),
       _repository = repository,
       _maxResolvedEntries = maxResolvedEntries;

  final AudioDetailRepository _repository;
  final int _maxResolvedEntries;
  final Map<String, Future<AudioDetailLoadResult>> _loadFutures =
      <String, Future<AudioDetailLoadResult>>{};
  final LinkedHashMap<String, AudioDetailLoadResult> _resolved =
      LinkedHashMap<String, AudioDetailLoadResult>();
  final Map<String, Future<void>> _operationTails = <String, Future<void>>{};
  int _revision = 0;
  int _cacheEpoch = 0;
  bool _suspended = false;

  int get revision => _revision;

  AudioDetail? resolvedDetail(AudioDetailTarget target) {
    return _resolved[AudioLibraryDetailKey.forTarget(target)]?.detail;
  }

  Future<AudioDetailLoadResult> load(AudioDetailTarget target) {
    final key = AudioLibraryDetailKey.forTarget(target);
    final cached = _takeResolved(key);
    if (cached != null) return Future<AudioDetailLoadResult>.value(cached);
    final existing = _loadFutures[key];
    if (existing != null) return existing;
    final epoch = _cacheEpoch;
    late final Future<AudioDetailLoadResult> future;
    future = _runSerialized<AudioDetailLoadResult>(
      <AudioDetailTarget>[target],
      () async {
        final resolved = _takeResolved(key);
        if (resolved != null) return resolved;
        final result = await _repository.load(target);
        if (epoch == _cacheEpoch) {
          final resultKey = AudioLibraryDetailKey.forTarget(
            result.detail.target,
          );
          _storeResolved(resultKey, result);
          if (resultKey != key) {
            _storeResolved(key, result);
          }
        }
        return result;
      },
    );
    _loadFutures[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_loadFutures[key], future)) {
            _loadFutures.remove(key);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_loadFutures[key], future)) {
            _loadFutures.remove(key);
          }
        },
      ),
    );
    return future;
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final epoch = _cacheEpoch;
    final orderedTargets = targets.toList(growable: false);
    if (orderedTargets.isEmpty) return const <AudioDetailLoadResult>[];

    final resolvedForRequest = <String, AudioDetailLoadResult>{};
    final pendingForRequest = <String, Future<AudioDetailLoadResult>>{};
    final batchTargetsByKey = <String, AudioDetailTarget>{};
    for (final target in orderedTargets) {
      final key = AudioLibraryDetailKey.forTarget(target);
      final cached = _takeResolved(key);
      if (cached != null) {
        resolvedForRequest[key] = cached;
        continue;
      }
      final pending = _loadFutures[key];
      if (pending != null) {
        pendingForRequest[key] = pending;
        continue;
      }
      batchTargetsByKey.putIfAbsent(key, () => target);
    }

    if (batchTargetsByKey.isNotEmpty) {
      final batchResults = await _runSerialized<List<AudioDetailLoadResult>>(
        batchTargetsByKey.values,
        () async {
          final results = <AudioDetailLoadResult>[];
          final missing = <AudioDetailTarget>[];
          // A preceding batch or write can resolve targets while this read waits.
          for (final entry in batchTargetsByKey.entries) {
            final resolved = _takeResolved(entry.key);
            if (resolved == null) {
              missing.add(entry.value);
            } else {
              results.add(resolved);
            }
          }
          if (missing.isNotEmpty) {
            results.addAll(await _repository.loadMany(missing));
          }
          if (epoch == _cacheEpoch) {
            for (final result in results) {
              _storeLoadResult(result);
            }
          }
          return results;
        },
      );
      for (final result in batchResults) {
        resolvedForRequest[AudioLibraryDetailKey.forTarget(
              result.detail.target,
            )] =
            result;
      }
    }

    return Future.wait(<Future<AudioDetailLoadResult>>[
      for (final target in orderedTargets)
        _resultForRequest(
          target,
          resolvedForRequest: resolvedForRequest,
          pendingForRequest: pendingForRequest,
        ),
    ]);
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
        _bumpRevision();
      }
      return result;
    });
  }

  Future<AudioDetailLoadResult> _resultForRequest(
    AudioDetailTarget target, {
    required Map<String, AudioDetailLoadResult> resolvedForRequest,
    required Map<String, Future<AudioDetailLoadResult>> pendingForRequest,
  }) {
    final key = AudioLibraryDetailKey.forTarget(target);
    final resolved = resolvedForRequest[key];
    if (resolved != null) return Future<AudioDetailLoadResult>.value(resolved);
    final pending = pendingForRequest[key];
    if (pending != null) return pending;
    return load(target);
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
        _bumpRevision();
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
        _bumpRevision();
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
      _bumpRevision();
      return result;
    });
  }

  Future<AudioDetailSaveResult> saveMissingDuration(
    AudioDetailTarget target,
    Duration duration,
  ) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailSaveResult>([target], () async {
      final previousDuration = resolvedDetail(target)?.duration;
      final result = await _repository.saveMissingDuration(target, duration);
      if (epoch != _cacheEpoch) {
        throw const AudioDetailOperationCancelled();
      }
      _store(result.detail);
      if (previousDuration != result.detail.duration) _bumpRevision();
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
        if (imported.changedDetails.isNotEmpty) _bumpRevision();
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
      _bumpRevision();
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
      _bumpRevision();
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
      _bumpRevision();
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
        _bumpRevision();
        return result;
      },
    );
  }

  void markChanged(AudioDetail detail) {
    _store(detail);
    _bumpRevision();
  }

  void clear() {
    _cacheEpoch++;
    _loadFutures.clear();
    _resolved.clear();
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

  void _store(AudioDetail detail) {
    _storeLoadResult(AudioDetailLoadResult(detail: detail));
    _loadFutures.remove(AudioLibraryDetailKey.forTarget(detail.target));
  }

  void _storeLoadResult(AudioDetailLoadResult loadResult) {
    final key = AudioLibraryDetailKey.forTarget(loadResult.detail.target);
    _storeResolved(key, loadResult);
    _loadFutures.remove(key);
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
  }

  void _bumpRevision() {
    _revision++;
  }
}

class AudioLibraryDetailKey {
  const AudioLibraryDetailKey._();

  static String forTarget(AudioDetailTarget target) {
    return '${target.targetType.dbValue}|${PathMatcher.equivalenceKey(target.targetPath)}';
  }
}
