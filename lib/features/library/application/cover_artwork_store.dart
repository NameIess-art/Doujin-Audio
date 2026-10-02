import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/cover_image_format.dart';
import '../../../core/media/path_matcher.dart';
export '../../../core/media/cover_image_format.dart'
    show coverArtworkStoreDirectoryName;

const String coverArtworkStoreIndexFileName = 'index.json';

enum CoverArtworkNamespace { remote, embedded, generated, legacy }

typedef RemoteCoverValidation = ({
  DateTime checkedAt,
  String? etag,
  String? lastModified,
});

String _canonicalLogicalKey(String value) {
  for (final prefix in const [
    'folder:',
    'track:',
    'native:',
    'embedded:',
    'video:',
  ]) {
    if (!value.startsWith(prefix)) continue;
    final source = value.substring(prefix.length);
    if (source.startsWith('remote-cover:')) return value;
    final fingerprintAt = source.indexOf('|');
    final videoAt = prefix == 'video:'
        ? source.lastIndexOf(':', source.lastIndexOf(':') - 1)
        : -1;
    final suffixAt = fingerprintAt >= 0 ? fingerprintAt : videoAt;
    final sourcePath = suffixAt < 0 ? source : source.substring(0, suffixAt);
    if (sourcePath.startsWith('windows:') ||
        sourcePath.startsWith('file:') ||
        (sourcePath.startsWith('content:') &&
            !sourcePath.startsWith('content://'))) {
      return value;
    }
    return '$prefix${PathMatcher.equivalenceKey(sourcePath)}${suffixAt < 0 ? '' : source.substring(suffixAt)}';
  }
  return value;
}

/// Owns durable cover files and the small synchronous lookup index used by UI.
final class CoverArtworkStore {
  CoverArtworkStore({
    Future<Directory> Function()? persistentDirectory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _persistentDirectory =
           persistentDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final Future<Directory> Function() _persistentDirectory;
  final Future<Directory> Function() _temporaryDirectory;
  final Map<String, String> _bindings = <String, String>{};
  final Map<String, String> _legacyAliases = <String, String>{};
  final Map<String, RemoteCoverValidation> _remoteValidation = {};
  Future<void>? _initializeFuture;
  Future<void> _operations = Future<void>.value();
  late Directory _root;
  late File _index;
  bool _initialized = false;
  int _clearEpoch = 0;

  bool get isInitialized => _initialized;

  String? get rootPath => _initialized ? _root.path : null;

  Future<void> initialize() {
    final inFlight = _initializeFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> load;
    load = _load().onError((error, stackTrace) {
      if (identical(_initializeFuture, load)) _initializeFuture = null;
      Error.throwWithStackTrace(
        error ?? StateError('Cover artwork store initialization failed.'),
        stackTrace,
      );
    });
    _initializeFuture = load;
    return load;
  }

  Future<void> _load() async {
    final support = await _persistentDirectory();
    _root = Directory(path.join(support.path, coverArtworkStoreDirectoryName));
    _index = File(path.join(_root.path, coverArtworkStoreIndexFileName));
    await _root.create(recursive: true);
    try {
      if (await _index.exists()) {
        final decoded = json.decode(await _index.readAsString());
        if (decoded is Map &&
            (decoded['version'] == 1 || decoded['version'] == 2)) {
          _decodeMap(decoded['bindings'], _bindings);
          _decodeMap(decoded['legacyAliases'], _legacyAliases);
          final validation = decoded['remoteValidation'];
          if (validation is Map) {
            for (final entry in validation.entries) {
              final data = entry.value;
              if (data is! Map) continue;
              final checkedAt = DateTime.tryParse(
                data['checkedAt']?.toString() ?? '',
              );
              if (checkedAt == null) continue;
              _remoteValidation[entry.key.toString()] = (
                checkedAt: checkedAt,
                etag: data['etag'] as String?,
                lastModified: data['lastModified'] as String?,
              );
            }
          }
        }
      }
    } catch (_) {
      _bindings.clear();
      _legacyAliases.clear();
    }
    _initialized = true;
    final migrated = <String, String>{
      for (final entry in _bindings.entries)
        _canonicalLogicalKey(entry.key): entry.value,
    };
    if (migrated.keys.any((key) => !_bindings.containsKey(key)) ||
        migrated.length != _bindings.length) {
      _bindings
        ..clear()
        ..addAll(migrated);
      await _persistIndex();
    }
  }

  void _decodeMap(Object? value, Map<String, String> target) {
    if (value is! Map) return;
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final stored = entry.value?.toString() ?? '';
      if (key.isNotEmpty && stored.isNotEmpty) target[key] = stored;
    }
  }

  String? resolvedPath(String logicalKey) {
    if (!_initialized || logicalKey.isEmpty) return null;
    final stored = _bindings[_canonicalLogicalKey(logicalKey)];
    return stored == null ? null : _absoluteValue(stored);
  }

  Iterable<String> logicalKeysForPath(String resolvedPath) => _bindings.entries
      .where(
        (entry) => PathMatcher.equalsNormalized(
          _absoluteValue(entry.value),
          resolvedPath,
        ),
      )
      .map((entry) => entry.key);

  Future<void> discardUnreadableArtifact(
    String value, {
    Iterable<String> keys = const [],
  }) {
    final epoch = _clearEpoch;
    return _enqueue<void>(() async {
      if (epoch != _clearEpoch || !_initialized) return;
      if (path.isWithin(_root.path, value)) {
        final file = File(value);
        if (await file.exists()) await file.delete();
      }
      var changed = false;
      for (final key in keys) {
        changed =
            _bindings.remove(_canonicalLogicalKey(key)) != null || changed;
      }
      if (changed) await _persistIndex();
    });
  }

  Future<bool> isRebuildablePath(String value) async {
    await initialize();
    if (_isUri(value)) return false;
    if (path.isWithin(_root.path, value)) return true;
    if (path.isWithin(
      path.join(_root.parent.path, 'portable_card_covers'),
      value,
    )) {
      return false;
    }
    final temporary = await _temporaryDirectory();
    return path.isWithin(temporary.path, value) ||
        path.isWithin(path.join(_root.parent.path, 'remote_covers'), value);
  }

  Future<String?> validatedPath(String logicalKey) async {
    logicalKey = _canonicalLogicalKey(logicalKey);
    final stored = _bindings[logicalKey];
    final epoch = _clearEpoch;
    final resolved = await _validResolvedValue(stored);
    if (epoch != _clearEpoch || _bindings[logicalKey] != stored) return null;
    if (stored != null && resolved == null) {
      _bindings.remove(logicalKey);
      await _enqueue<void>(_persistIndex);
    }
    return resolved;
  }

  Future<String?> validatedArtifact(
    CoverArtworkNamespace namespace,
    String fileName,
  ) async {
    if (!_initialized || fileName.isEmpty) return null;
    final epoch = _clearEpoch;
    final candidate = _artifactFile(namespace, fileName);
    final usable = await _isUsableFile(candidate.path);
    return epoch == _clearEpoch && usable ? candidate.path : null;
  }

  String? resolveStoredPath(String? storedPath) {
    if (!_initialized) return null;
    final value = storedPath?.trim();
    if (value == null || value.isEmpty) return null;
    if (_isUri(value)) return value;
    final migrated = _legacyAliases[_legacyAliasKey(value)];
    return migrated == null ? value : _absoluteValue(migrated);
  }

  Future<String?> putBytes({
    required String logicalKey,
    required List<int> bytes,
    CoverArtworkNamespace namespace = CoverArtworkNamespace.generated,
    String? fileStem,
  }) {
    if (logicalKey.isEmpty || bytes.isEmpty) return Future<String?>.value();
    final epoch = _clearEpoch;
    return _enqueue<String?>(() async {
      await initialize();
      if (epoch != _clearEpoch) return null;
      final stem = fileStem ?? sha256.convert(bytes).toString();
      final output = _artifactFile(namespace, '$stem.image');
      if (!await _isUsableFile(output.path)) await _writeBytes(output, bytes);
      final key = _canonicalLogicalKey(logicalKey);
      final stored = _storedValue(output.path);
      if (_bindings[key] != stored) {
        _bindings[key] = stored;
        await _persistIndex();
      }
      return output.path;
    });
  }

  Future<String?> putFile({
    required String logicalKey,
    required String sourcePath,
    CoverArtworkNamespace namespace = CoverArtworkNamespace.generated,
    String? fileStem,
  }) {
    final epoch = _clearEpoch;
    return _enqueue<String?>(() async {
      await initialize();
      if (epoch != _clearEpoch) return null;
      final source = File(sourcePath);
      if (!await source.exists() || await source.length() <= 0) return null;
      final stat = await source.stat();
      final stem =
          fileStem ??
          switch (namespace) {
            CoverArtworkNamespace.embedded =>
              await sha256.bind(source.openRead()).first,
            CoverArtworkNamespace.generated => sha256.convert(
              utf8.encode(logicalKey),
            ),
            _ => sha256.convert(
              utf8.encode(
                '$logicalKey|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
              ),
            ),
          };
      final output = _artifactFile(namespace, '$stem.image');
      if (!await _isUsableFile(output.path)) await _copyFile(source, output);
      final key = _canonicalLogicalKey(logicalKey);
      final stored = _storedValue(output.path);
      if (_bindings[key] != stored) {
        _bindings[key] = stored;
        await _persistIndex();
      }
      return output.path;
    });
  }

  Future<void> bind(String logicalKey, String resolvedPath) {
    if (logicalKey.isEmpty || resolvedPath.isEmpty) return Future<void>.value();
    final epoch = _clearEpoch;
    return _enqueue<void>(() async {
      await initialize();
      if (epoch != _clearEpoch) return;
      final key = _canonicalLogicalKey(logicalKey);
      final stored = _storedValue(resolvedPath);
      if (_bindings[key] == stored) return;
      _bindings[key] = stored;
      await _persistIndex();
    });
  }

  Future<void> invalidate(Iterable<String> logicalKeys) {
    if (!_initialized) return Future<void>.value();
    var changed = false;
    for (final key in logicalKeys) {
      changed = _bindings.remove(_canonicalLogicalKey(key)) != null || changed;
    }
    return changed ? _enqueue<void>(_persistIndex) : Future<void>.value();
  }

  Future<void> invalidateAllBindings() {
    if (!_initialized || _bindings.isEmpty) return Future<void>.value();
    _bindings.clear();
    return _enqueue<void>(_persistIndex);
  }

  RemoteCoverValidation? remoteValidation(String key) => _remoteValidation[key];

  Future<void> saveRemoteValidation(
    String key,
    RemoteCoverValidation validation,
  ) {
    final epoch = _clearEpoch;
    return _enqueue<void>(() async {
      await initialize();
      if (epoch != _clearEpoch || _remoteValidation[key] == validation) return;
      _remoteValidation[key] = validation;
      await _persistIndex();
    });
  }

  Future<int> migrateLegacyCaches({bool Function()? shouldCancel}) {
    return _enqueue<int>(() async {
      await initialize();
      final temp = await _temporaryDirectory();
      final support = await _persistentDirectory();
      final roots = <({Directory directory, bool remote})>[
        (
          directory: Directory(path.join(temp.path, 'notification_covers')),
          remote: true,
        ),
        (
          directory: Directory(path.join(support.path, 'remote_covers')),
          remote: true,
        ),
        for (final name in const <String>[
          'embedded_covers',
          'video_frames',
          'doujin_audio_covers',
        ])
          (directory: Directory(path.join(temp.path, name)), remote: false),
      ];
      var migrated = 0;
      for (final root in roots) {
        if (shouldCancel?.call() == true) break;
        if (!await root.directory.exists()) continue;
        await for (final entity in root.directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (shouldCancel?.call() == true) break;
          if (entity is! File || entity.path.endsWith('.part')) continue;
          final aliasKey = _legacyAliasKey(entity.path);
          if (await _validResolvedValue(_legacyAliases[aliasKey]) != null) {
            continue;
          }
          final namespace = root.remote
              ? CoverArtworkNamespace.remote
              : CoverArtworkNamespace.legacy;
          final outputName = root.remote
              ? path.basename(entity.path)
              : '${sha256.convert(utf8.encode(path.normalize(entity.path)))}.image';
          final output = _artifactFile(namespace, outputName);
          if (!await _isUsableFile(output.path)) {
            await _copyFile(entity, output);
          }
          _legacyAliases[aliasKey] = _storedValue(output.path);
          migrated++;
        }
      }
      if (migrated > 0) await _persistIndex();
      return migrated;
    });
  }

  Future<int> clear() {
    _clearEpoch++;
    return _enqueue<int>(() async {
      await initialize();
      final deletedBytes = await _artifactBytes(_root);
      if (await _root.exists()) await _root.delete(recursive: true);
      _bindings.clear();
      _legacyAliases.clear();
      _remoteValidation.clear();
      await _root.create(recursive: true);
      await _persistIndex();
      return deletedBytes;
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.warning(
          'cover_artwork_store_operation_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    return result;
  }

  File _artifactFile(CoverArtworkNamespace namespace, String fileName) =>
      File(path.join(_root.path, namespace.name, _safeFileName(fileName)));

  Future<void> _writeBytes(File output, List<int> bytes) async {
    await output.parent.create(recursive: true);
    final partial = File('${output.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (await output.exists()) await output.delete();
      await partial.rename(output.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _copyFile(File source, File output) async {
    await output.parent.create(recursive: true);
    final partial = File('${output.path}.part');
    try {
      await source.openRead().pipe(partial.openWrite());
      if (await output.exists()) await output.delete();
      await partial.rename(output.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _persistIndex() async {
    await _root.create(recursive: true);
    final partial = File('${_index.path}.part');
    final payload = json.encode(<String, Object>{
      'version': 2,
      'bindings': _bindings,
      'legacyAliases': _legacyAliases,
      'remoteValidation': {
        for (final entry in _remoteValidation.entries)
          entry.key: {
            'checkedAt': entry.value.checkedAt.toUtc().toIso8601String(),
            'etag': entry.value.etag,
            'lastModified': entry.value.lastModified,
          },
      },
    });
    try {
      await partial.writeAsString(payload, flush: true);
      if (await _index.exists()) await _index.delete();
      await partial.rename(_index.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<String?> _validResolvedValue(String? stored) async {
    if (stored == null || stored.isEmpty) return null;
    final value = _absoluteValue(stored);
    return _isUri(value) || await _isUsableFile(value) ? value : null;
  }

  String _storedValue(String value) =>
      !_isUri(value) && path.isWithin(_root.path, value)
      ? path.relative(value, from: _root.path)
      : value;

  String _absoluteValue(String value) => _isUri(value) || path.isAbsolute(value)
      ? value
      : path.join(_root.path, value);

  Future<bool> _isUsableFile(String value) async {
    try {
      final file = File(value);
      final stat = await file.stat();
      return stat.type == FileSystemEntityType.file && stat.size > 0;
    } on FileSystemException {
      return false;
    }
  }

  bool _isUri(String value) => value.contains('://');

  String _legacyAliasKey(String value) =>
      sha256.convert(utf8.encode(path.normalize(value))).toString();

  String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  Future<int> _artifactBytes(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File &&
          path.basename(entity.path) != coverArtworkStoreIndexFileName) {
        try {
          total += await entity.length();
        } catch (error, stackTrace) {
          AppLogService.warning(
            'cover_artwork_store_size_read_failed path=${entity.path}',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }
    return total;
  }
}
