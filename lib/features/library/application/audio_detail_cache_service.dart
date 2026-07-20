import 'dart:async';
import 'dart:collection';

import '../../../core/media/audio_detail.dart';
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
          final results = await _repository.loadMany(batchTargetsByKey.values);
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
    AudioDetailSaveOrigin origin = AudioDetailSaveOrigin.user,
  }) {
    final epoch = _cacheEpoch;
    return _runSerialized<AudioDetailSaveResult>(
      <AudioDetailTarget>[detail.target],
      () async {
        final result = await _repository.save(detail, origin: origin);
        if (epoch != _cacheEpoch) {
          throw const AudioDetailOperationCancelled();
        }
        _store(result.detail);
        _bumpRevision();
        return result;
      },
    );
  }

  Future<String?> loadCardCoverPath(AudioDetailTarget target) async {
    return (await load(target)).detail.cardCoverPath;
  }

  Future<String?> saveCardCoverPath(
    AudioDetailTarget target,
    String? coverPath,
  ) async {
    final current = (await load(target)).detail;
    final normalizedPath = coverPath?.trim();
    final nextPath = normalizedPath == null || normalizedPath.isEmpty
        ? null
        : normalizedPath;
    if (current.cardCoverPath == nextPath) return current.cardCoverPath;
    final result = await save(current.copyWith(cardCoverPath: nextPath));
    return result.detail.cardCoverPath;
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

  Future<void> suspendAndWait() async {
    _suspended = true;
    clear();
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
    return '${target.targetType.dbValue}|${target.targetPath}';
  }
}
