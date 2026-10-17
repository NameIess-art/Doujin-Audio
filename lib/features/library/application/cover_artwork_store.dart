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
const int _androidGeneratedArtworkVersion = 2;

enum CoverArtworkNamespace { remote, embedded, generated, legacy }

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
    bool Function()? isAndroid,
    DateTime Function()? now,
  }) : _persistentDirectory =
           persistentDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _isAndroid = isAndroid ?? (() => Platform.isAndroid),
       _now = now ?? DateTime.now;

  final Future<Directory> Function() _persistentDirectory;
  final Future<Directory> Function() _temporaryDirectory;
  final bool Function() _isAndroid;
  final DateTime Function() _now;
  Directory? _androidTemporaryDirectory;
  final Map<String, String> _bindings = <String, String>{};
  final Map<String, String> _legacyAliases = <String, String>{};
  // Only new artifacts are eligible. Zero permanently protects authored paths,
  // including references retained by old sidecars or database backups.
  final Map<String, int> _managedArtifacts = <String, int>{};
  final Map<String, int> _pendingReferences = <String, int>{};
  final Set<String> _accessedArtifacts = <String>{};
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
    if (_isAndroid()) _androidTemporaryDirectory = await _temporaryDirectory();
    var androidGeneratedVersion = 0;
    try {
      if (await _index.exists()) {
        final decoded = json.decode(await _index.readAsString());
        if (decoded is Map &&
            (decoded['version'] == 1 || decoded['version'] == 2)) {
          _decodeMap(decoded['bindings'], _bindings);
          _decodeMap(decoded['legacyAliases'], _legacyAliases);
          final managed = decoded['managedArtifacts'];
          if (managed is Map) {
            for (final entry in managed.entries) {
              final createdAt = entry.value;
              if (entry.key is String && createdAt is int && createdAt >= 0) {
                _managedArtifacts[entry.key as String] = createdAt;
              }
            }
          }
          final generatedVersion = decoded['androidGeneratedVersion'];
          androidGeneratedVersion = generatedVersion is num
              ? generatedVersion.toInt()
              : 0;
        }
      }
    } catch (_) {
      _bindings.clear();
      _legacyAliases.clear();
      _managedArtifacts.clear();
    }
    _initialized = true;
    final migrated = <String, String>{
      for (final entry in _bindings.entries)
        _canonicalLogicalKey(entry.key): entry.value,
    };
    var changed = false;
    if (_isAndroid() &&
        androidGeneratedVersion != _androidGeneratedArtworkVersion) {
      migrated.removeWhere((key, value) {
        final resolved = _absoluteValue(value);
        return _isAutomaticKey(key) &&
            !key.contains('remote-cover:') &&
            !_isUri(resolved) &&
            !path.isWithin(path.join(_root.path, 'remote'), resolved) &&
            !path.isWithin(
              path.join(_root.parent.path, 'portable_card_covers'),
              resolved,
            );
      });
      changed = true;
    }
    if (changed ||
        migrated.keys.any((key) => !_bindings.containsKey(key)) ||
        migrated.length != _bindings.length) {
      _bindings
        ..clear()
        ..addAll(migrated);
      await _persistIndex();
    }
  }

  bool _isAutomaticKey(String key) => const [
    'video:',
    'native:',
    'embedded:',
    'track:',
    'folder:',
    'source-image:',
  ].any(key.startsWith);

  // Old derived files stay on disk because an explicit selection may own them.
  bool isObsoleteAndroidAutomaticPath(String value) {
    if (!_isAndroid() || !_initialized || _isUri(value)) return false;
    if (path.isWithin(_root.path, value)) {
      final parts = path.split(path.relative(value, from: _root.path));
      return parts.length > 1 &&
          const ['generated', 'embedded', 'legacy'].contains(parts.first) &&
          parts[1] != 'android-v$_androidGeneratedArtworkVersion';
    }
    final temporary = _androidTemporaryDirectory;
    if (temporary == null || !path.isWithin(temporary.path, value)) {
      return false;
    }
    final parts = path.split(path.relative(value, from: temporary.path));
    if (parts.isEmpty) return false;
    if (parts.first == 'video_frames' || parts.first == 'embedded_covers') {
      return true;
    }
    return parts.first == 'doujin_audio_covers' &&
        RegExp(
          r'^(cover|video_frame)_-?[0-9]{1,10}\.[a-zA-Z]+$',
        ).hasMatch(path.basename(value));
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
    final resolved = stored == null ? null : _absoluteValue(stored);
    if (resolved != null) _rememberAccess(resolved);
    return resolved;
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
    if (resolved != null) _rememberAccess(resolved);
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
    if (usable) _rememberAccess(candidate.path);
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
      final managedCount = _managedArtifacts.length;
      if (!await _isUsableFile(output.path)) {
        final existed = await output.exists();
        await _writeBytes(output, bytes);
        if (!existed) _recordCreatedArtifact(output);
      }
      final key = _canonicalLogicalKey(logicalKey);
      final stored = _storedValue(output.path);
      if (_bindings[key] != stored ||
          managedCount != _managedArtifacts.length) {
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
      final managedCount = _managedArtifacts.length;
      final output = await _storeFile(
        logicalKey: logicalKey,
        sourcePath: sourcePath,
        namespace: namespace,
        fileStem: fileStem,
      );
      if (output == null) return null;
      final key = _canonicalLogicalKey(logicalKey);
      final stored = _storedValue(output);
      if (_bindings[key] != stored ||
          managedCount != _managedArtifacts.length) {
        _bindings[key] = stored;
        await _persistIndex();
      }
      return output;
    });
  }

  /// A directory discovery commits its bindings with one durable index write.
  /// Hash reuse is limited to this batch and its source revisions.
  Future<List<String?>> putFiles(
    List<({String logicalKey, String sourcePath})> sources, {
    CoverArtworkNamespace namespace = CoverArtworkNamespace.embedded,
    bool Function()? shouldCancel,
  }) {
    final epoch = _clearEpoch;
    return _enqueue(() async {
      await initialize();
      final results = List<String?>.filled(sources.length, null);
      final hashes = <(String, int, int, int), String>{};
      final managedCount = _managedArtifacts.length;
      var changed = false;
      try {
        for (var index = 0; index < sources.length; index++) {
          if (epoch != _clearEpoch || (shouldCancel?.call() ?? false)) break;
          final source = sources[index];
          String? output;
          try {
            output = _isUri(source.sourcePath)
                ? source.sourcePath
                : await _storeFile(
                    logicalKey: source.logicalKey,
                    sourcePath: source.sourcePath,
                    namespace: namespace,
                    hashes: hashes,
                  );
          } on FileSystemException catch (error, stackTrace) {
            AppLogService.warning(
              'cover_artwork_batch_source_failed path=${source.sourcePath}',
              error: error,
              stackTrace: stackTrace,
            );
          }
          if (epoch != _clearEpoch || (shouldCancel?.call() ?? false)) break;
          if (output == null) continue;
          results[index] = output;
          final key = _canonicalLogicalKey(source.logicalKey);
          final stored = _storedValue(output);
          if (_bindings[key] == stored) continue;
          _bindings[key] = stored;
          changed = true;
        }
      } finally {
        if (changed || managedCount != _managedArtifacts.length) {
          await _persistIndex();
        }
      }
      return results;
    });
  }

  Future<String?> _storeFile({
    required String logicalKey,
    required String sourcePath,
    required CoverArtworkNamespace namespace,
    String? fileStem,
    Map<(String, int, int, int), String>? hashes,
  }) async {
    final source = File(sourcePath);
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    final fingerprint = (
      PathMatcher.equivalenceKey(sourcePath),
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      stat.changed.microsecondsSinceEpoch,
    );
    final String stem;
    if (fileStem != null) {
      stem = fileStem;
    } else if (namespace == CoverArtworkNamespace.embedded) {
      final cached = hashes?[fingerprint];
      stem = cached ?? (await sha256.bind(source.openRead()).first).toString();
      hashes?[fingerprint] = stem;
    } else {
      stem = sha256
          .convert(
            utf8.encode(
              namespace == CoverArtworkNamespace.generated
                  ? logicalKey
                  : '$logicalKey|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
            ),
          )
          .toString();
    }
    final output = _artifactFile(namespace, '$stem.image');
    if (!await _isUsableFile(output.path)) {
      final existed = await output.exists();
      await _copyFile(source, output);
      if (!existed) _recordCreatedArtifact(output);
    }
    return output.path;
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

  /// Commit this before persisting a user/backup reference to a store artifact.
  Future<void> preserveReference(String value) {
    if (!isStoreArtifactPath(value)) return Future<void>.value();
    final resolved = resolveStoredPath(value) ?? value;
    final reference = _referenceKey(resolved);
    final epoch = _clearEpoch;
    _pendingReferences.update(
      reference,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    return _enqueue<void>(() async {
      await initialize();
      if (epoch != _clearEpoch) {
        throw StateError(
          'Cover storage changed before preserving a reference.',
        );
      }
      final key = _artifactRelativePath(resolveStoredPath(value) ?? value);
      if (key == null) return;
      // An already-dispatched delete may finish before this queued pin runs.
      // Refuse the selection rather than persist a reference to a removed file.
      if (!await _isUsableFile(path.join(_root.path, key))) {
        throw FileSystemException(
          'Selected cover is no longer available.',
          value,
        );
      }
      if (_managedArtifacts[key] == 0) return;
      final previous = _managedArtifacts[key];
      _managedArtifacts[key] = 0;
      try {
        await _persistIndex();
      } catch (_) {
        if (previous == null) {
          _managedArtifacts.remove(key);
        } else {
          _managedArtifacts[key] = previous;
        }
        rethrow;
      }
    }).whenComplete(() {
      final count = _pendingReferences[reference]!;
      if (count == 1) {
        _pendingReferences.remove(reference);
      } else {
        _pendingReferences[reference] = count - 1;
      }
    });
  }

  Future<int> collectOrphanedArtifacts({
    Iterable<String> retainedPaths = const [],
    bool Function()? shouldCancel,
  }) {
    final epoch = _clearEpoch;
    return _enqueue<int>(() async {
      await initialize();
      bool cancelled() =>
          epoch != _clearEpoch || (shouldCancel?.call() ?? false);
      if (cancelled() || !await _isPlainDirectory(_root.path)) return 0;
      final cutoff = _now().subtract(const Duration(days: 1));
      final retained = <String>{
        ..._bindings.values.map(
          (value) => _referenceKey(_absoluteValue(value)),
        ),
        ..._legacyAliases.values.map(
          (value) => _referenceKey(_absoluteValue(value)),
        ),
        ...retainedPaths.map(_referenceKey),
      };
      var deletedBytes = 0;
      var changed = false;
      try {
        for (final entry in _managedArtifacts.entries.toList()) {
          if (cancelled()) break;
          if (entry.value == 0 ||
              entry.value >= cutoff.millisecondsSinceEpoch) {
            continue;
          }
          final absolute = path.join(_root.path, entry.key);
          if (_artifactRelativePath(absolute) != entry.key) continue;
          // Do not traverse a namespace/version replaced by a link or junction.
          var plain = true;
          var parent = path.dirname(absolute);
          while (parent != _root.path) {
            if (!await _isPlainDirectory(parent)) {
              plain = false;
              break;
            }
            parent = path.dirname(parent);
          }
          if (!plain || cancelled()) continue;
          if (await FileSystemEntity.type(absolute, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
          final file = File(absolute);
          final stat = await file.stat();
          if (stat.modified.isAfter(cutoff) || cancelled()) continue;
          final reference = _referenceKey(absolute);
          // A selection can begin while an earlier cleanup is awaiting I/O.
          if (_managedArtifacts[entry.key] == 0 ||
              _pendingReferences.containsKey(reference) ||
              _accessedArtifacts.contains(reference) ||
              retained.contains(reference)) {
            continue;
          }
          await file.delete();
          deletedBytes += stat.size;
          _managedArtifacts.remove(entry.key);
          changed = true;
        }
      } finally {
        if (changed) await _persistIndex();
      }
      return deletedBytes;
    });
  }

  void _recordCreatedArtifact(File file) {
    final key = _artifactRelativePath(file.path);
    if (key != null) {
      _managedArtifacts.putIfAbsent(key, () => _now().millisecondsSinceEpoch);
    }
  }

  void _rememberAccess(String value) {
    final key = _artifactRelativePath(value);
    if (key != null && (_managedArtifacts[key] ?? 0) > 0) {
      _accessedArtifacts.add(_referenceKey(value));
    }
  }

  static bool isStoreArtifactPath(String value) =>
      !value.contains('://') &&
      value.toLowerCase().endsWith('.image') &&
      path
          .split(value)
          .any((part) => part.toLowerCase() == coverArtworkStoreDirectoryName);

  String? _artifactRelativePath(String value) {
    if (_isUri(value) || !path.isWithin(_root.path, value)) return null;
    final original = path.relative(value, from: _root.path);
    final relative = Platform.isWindows ? original.toLowerCase() : original;
    final parts = path.split(relative);
    if ((parts.length != 2 && parts.length != 3) ||
        !CoverArtworkNamespace.values.any((item) => item.name == parts.first) ||
        (parts.length == 3 &&
            !RegExp(r'^android-v[0-9]+$').hasMatch(parts[1])) ||
        !parts.last.endsWith('.image')) {
      return null;
    }
    return relative;
  }

  String _referenceKey(String value) => PathMatcher.equivalenceKey(value);

  Future<bool> _isPlainDirectory(String value) async =>
      await FileSystemEntity.type(value, followLinks: false) ==
      FileSystemEntityType.directory;

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
        if (_isAndroid() && !root.remote) continue;
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
      // Legacy remote files are reconstructible artwork too. Leaving them here
      // would let post-clear migration repopulate the store from stale files.
      final legacy = Directory(path.join(_root.parent.path, 'remote_covers'));
      final legacyBytes = await _artifactBytes(legacy);
      if (await FileSystemEntity.type(legacy.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await legacy.delete(recursive: true);
      }
      _bindings.clear();
      _legacyAliases.clear();
      _managedArtifacts.clear();
      _accessedArtifacts.clear();
      await _root.create(recursive: true);
      await _persistIndex();
      return deletedBytes + legacyBytes;
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

  File _artifactFile(CoverArtworkNamespace namespace, String fileName) => File(
    path.joinAll([
      _root.path,
      namespace.name,
      if (_isAndroid() && namespace != CoverArtworkNamespace.remote)
        'android-v$_androidGeneratedArtworkVersion',
      _safeFileName(fileName),
    ]),
  );

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
      if (_isAndroid())
        'androidGeneratedVersion': _androidGeneratedArtworkVersion,
      'bindings': _bindings,
      'legacyAliases': _legacyAliases,
      'managedArtifacts': _managedArtifacts,
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
