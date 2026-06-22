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
    final loadResult = AudioDetailLoadResult(detail: detail);
    _resolved[AudioLibraryDetailKey.forTarget(detail.target)] = loadResult;
    _loadFutures.remove(AudioLibraryDetailKey.forTarget(detail.target));
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
