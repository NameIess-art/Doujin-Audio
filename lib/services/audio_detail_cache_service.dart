import 'dart:async';

import '../models/audio_detail.dart';
import 'audio_detail_repository.dart';

class AudioDetailCacheService {
  AudioDetailCacheService({required AudioDetailRepository repository})
    : _repository = repository;

  final AudioDetailRepository _repository;
  final Map<String, Future<AudioDetailLoadResult>> _loadFutures =
      <String, Future<AudioDetailLoadResult>>{};
  final Map<String, AudioDetailLoadResult> _resolved =
      <String, AudioDetailLoadResult>{};
  int _revision = 0;

  int get revision => _revision;

  Future<AudioDetailLoadResult> load(AudioDetailTarget target) {
    final key = AudioLibraryDetailKey.forTarget(target);
    final cached = _resolved[key];
    if (cached != null) return Future<AudioDetailLoadResult>.value(cached);
    return _loadFutures.putIfAbsent(key, () {
      final future = () async {
        final result = await _repository.load(target);
        final resultKey = AudioLibraryDetailKey.forTarget(result.detail.target);
        _resolved[resultKey] = result;
        if (resultKey != key) {
          _resolved[key] = result;
        }
        return result;
      }();
      unawaited(future.whenComplete(() => _loadFutures.remove(key)));
      return future;
    });
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final orderedTargets = targets.toList(growable: false);
    if (orderedTargets.isEmpty) return const <AudioDetailLoadResult>[];

    final batchTargets = <AudioDetailTarget>[];
    for (final target in orderedTargets) {
      final key = AudioLibraryDetailKey.forTarget(target);
      if (_resolved.containsKey(key) || _loadFutures.containsKey(key)) {
        continue;
      }
      batchTargets.add(target);
    }

    if (batchTargets.isNotEmpty) {
      final batchResults = await _repository.loadMany(batchTargets);
      for (final result in batchResults) {
        _storeLoadResult(result);
      }
    }

    return Future.wait(orderedTargets.map(load));
  }

  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    final result = await _repository.save(detail);
    _store(result.detail);
    _bumpRevision();
    return result;
  }

  Future<void> delete(AudioDetailTarget target) async {
    await _repository.delete(target);
    _remove(target);
    _bumpRevision();
  }

  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final result = await _repository.prefillRjCodeFromText(target, text);
    if (result == null) return null;
    _store(result.detail);
    _bumpRevision();
    return result;
  }

  void markChanged(AudioDetail detail) {
    _store(detail);
    _bumpRevision();
  }

  void clear() {
    _loadFutures.clear();
    _resolved.clear();
    _bumpRevision();
  }

  void _store(AudioDetail detail) {
    _storeLoadResult(AudioDetailLoadResult(detail: detail));
    _loadFutures.remove(AudioLibraryDetailKey.forTarget(detail.target));
  }

  void _storeLoadResult(AudioDetailLoadResult loadResult) {
    final key = AudioLibraryDetailKey.forTarget(loadResult.detail.target);
    _resolved[key] = loadResult;
    _loadFutures.remove(key);
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
