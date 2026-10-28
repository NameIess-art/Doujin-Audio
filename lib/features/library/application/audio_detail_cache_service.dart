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

  bool affects(AudioDetailTarget target) =>
      targetKeys?.contains(AudioLibraryDetailKey.forTarget(target)) ?? true;
}

final class _AudioDetailReadRequest {
  _AudioDetailReadRequest({required this.target, required this.epoch});

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
    final request = _AudioDetailReadRequest(target: target, epoch: epoch)
      ..addRequester(isActive);
    final future = request.future = _runSerialized<AudioDetailLoadResult>(
      <AudioDetailTarget>[target],
      () async {
        if (epoch != _cacheEpoch || !request.isActive) {
          request.cancelled = true;
          throw const AudioDetailOperationCancelled();
        }
        final resolved = _takeResolved(key);
        if (resolved != null) return resolved;
        _pendingReads.add(request);
        _scheduleReads();
        final loaded = await request.result.future;
        if (epoch == _cacheEpoch) {
          final resultKey = AudioLibraryDetailKey.forTarget(
            loaded.detail.target,
          );
          _storeResolved(resultKey, loaded);
          if (resultKey != key) {
            _storeResolved(key, loaded);
          }
        }
        return loaded;
      },
    );
    request.tail = _operationTails[key]!;
    _loadFutures[key] = request;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_loadFutures[key], request)) {
            _loadFutures.remove(key);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_loadFutures[key], request)) {
            _loadFutures.remove(key);
          }
        },
      ),
    );
    return future;
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) => Future.wait(targets.map(load));

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
                  if (read.epoch != _cacheEpoch) {
                    read.result.completeError(
                      const AudioDetailOperationCancelled(),
                    );
                  } else {
                    read.result.complete(results[index]);
                  }
                }
              } catch (error, stackTrace) {
                for (final read in active) {
                  if (!read.result.isCompleted) {
                    read.result.completeError(error, stackTrace);
                  }
                }
              }
            }
            await Future<void>.delayed(Duration.zero);
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
