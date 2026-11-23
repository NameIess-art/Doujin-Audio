import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
    var videoAt = -1;
    if (prefix == 'video:') {
      final lastColon = source.lastIndexOf(':');
      if (lastColon > 0) {
        videoAt = source.lastIndexOf(':', lastColon - 1);
      }
    }
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
  Map<String, String> _bindings = <String, String>{};
  Map<String, String> _legacyAliases = <String, String>{};
  // Only new artifacts are eligible. Zero permanently protects authored paths,
  // including references retained by old sidecars or database backups.
  Map<String, int> _managedArtifacts = <String, int>{};
  final Map<String, int> _pendingReferences = <String, int>{};
  static const int _maxAccessedArtifacts = 1024;
  static const int _trimmedAccessedArtifacts = 256;
  final Set<String> _accessedArtifacts = <String>{};
  final Set<Future<void>> _activeFileWrites = <Future<void>>{};
  final Map<
    String,
    Future<
      ({
        String outputPath,
        bool created,
        (String, int, int, int)? fingerprint,
        String? computedStem,
      })?
    >
  >
  _inFlightFilePrepares = {};
  Future<void>? _initializeFuture;
  Future<void> _operations = Future<void>.value();
  Completer<void>? _pendingCommit;
  int _pendingBatchSize = 0;
  int _queuedOperations = 0;
  int _activeCoalescedPrepares = 0;
  int _partSequence = 0;
  bool _indexDirty = false;
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
    final android = _isAndroid();
    if (android) _androidTemporaryDirectory = await _temporaryDirectory();
    final indexPath = _index.path;
    final rootPath = _root.path;
    var loaded = _decodeCoverIndex(null, rootPath, android);
    try {
      if (await _index.exists()) {
        // Reading and migrating a large index must not occupy the UI isolate.
        loaded = await _index.length() > 64 * 1024
            ? await Isolate.run(
                () => _decodeCoverIndex(
                  File(indexPath).readAsStringSync(),
                  rootPath,
                  android,
                ),
              )
            : _decodeCoverIndex(await _index.readAsString(), rootPath, android);
      }
    } catch (_) {
      final fallback = _decodeCoverIndex(null, rootPath, android);
      loaded = (
        bindings: fallback.bindings,
        aliases: fallback.aliases,
        managed: fallback.managed,
        changed: true,
      );
    }
    // The worker transfers the maps; copying every entry here defeats offloading.
    _bindings = loaded.bindings;
    _legacyAliases = loaded.aliases;
    _managedArtifacts = loaded.managed;
    _initialized = true;
    if (loaded.changed) await _persistIndex(immediate: true);
  }

  static final RegExp _legacyTempCoverNamePattern = RegExp(
    r'^(cover|video_frame)_-?[0-9]{1,10}\.[a-zA-Z]+$',
  );
  static final RegExp _androidVersionSegmentPattern = RegExp(
    r'^android-v[0-9]+$',
  );
  static final RegExp _unsafeFileNameChars = RegExp(r'[^a-zA-Z0-9._-]');

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
        _legacyTempCoverNamePattern.hasMatch(path.basename(value));
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
    }, coalesce: true);
  }

  Future<String?> putFile({
    required String logicalKey,
    required String sourcePath,
    CoverArtworkNamespace namespace = CoverArtworkNamespace.generated,
    String? fileStem,
  }) async {
    final epoch = _clearEpoch;
    _activeCoalescedPrepares++;
    var enteredQueue = false;
    try {
      await initialize();
      if (epoch != _clearEpoch) return null;
      final outputDir = _namespaceDirectoryPath(namespace);
      final prepareKey =
          '$epoch|${namespace.name}|${fileStem ?? ''}|'
          '${namespace == CoverArtworkNamespace.embedded ? '' : logicalKey}|'
          '${PathMatcher.equivalenceKey(sourcePath)}';
      final storedResult = await _inFlightFilePrepares.putIfAbsent(prepareKey, () {
        late final Future<
          ({
            String outputPath,
            bool created,
            (String, int, int, int)? fingerprint,
            String? computedStem,
          })?
        >
        task;
        task = _trackFileWrite(() async {
          if (epoch != _clearEpoch) return null;
          final partId = ++_partSequence;
          return _runStoreCoverFileOnDisk(
            logicalKey: logicalKey,
            sourcePath: sourcePath,
            outputDirectoryPath: outputDir,
            namespace: namespace,
            fileStem: fileStem,
            knownHashes: null,
            partId: partId,
          );
        }).whenComplete(() {
          if (identical(_inFlightFilePrepares[prepareKey], task)) {
            _inFlightFilePrepares.remove(prepareKey);
          }
        });
        return task;
      });
      if (storedResult == null || epoch != _clearEpoch) return null;
      enteredQueue = true;
      _activeCoalescedPrepares--;
      return await _enqueue<String?>(() async {
        if (epoch != _clearEpoch) return null;
        final managedCount = _managedArtifacts.length;
        if (storedResult.created) {
          _recordCreatedArtifact(File(storedResult.outputPath));
        }
        final key = _canonicalLogicalKey(logicalKey);
        final stored = _storedValue(storedResult.outputPath);
        if (_bindings[key] != stored ||
            managedCount != _managedArtifacts.length) {
          _bindings[key] = stored;
          await _persistIndex();
        }
        return storedResult.outputPath;
      }, coalesce: true);
    } finally {
      if (!enteredQueue) {
        _activeCoalescedPrepares--;
        _flushPendingCommitIfIdle();
      }
    }
  }

  /// A directory discovery commits its bindings with one durable index write.
  /// Hash reuse is limited to this batch and its source revisions.
  Future<List<String?>> putFiles(
    List<({String logicalKey, String sourcePath})> sources, {
    CoverArtworkNamespace namespace = CoverArtworkNamespace.embedded,
    bool Function()? shouldCancel,
  }) async {
    final epoch = _clearEpoch;
    await initialize();
    final results = List<String?>.filled(sources.length, null);
    if (sources.isEmpty || epoch != _clearEpoch) {
      return results;
    }
    final hashes = <(String, int, int, int), String>{};
    final outputDir = _namespaceDirectoryPath(namespace);
    final prepared =
        <({String logicalKey, String outputPath, bool created})>[];
    await _trackFileWrite(() async {
      for (var index = 0; index < sources.length; index++) {
        if (epoch != _clearEpoch || (shouldCancel?.call() ?? false)) break;
        final source = sources[index];
        String? output;
        var created = false;
        try {
          if (_isUri(source.sourcePath)) {
            output = source.sourcePath;
          } else {
            final partId = ++_partSequence;
            final knownHashes = hashes.isEmpty
                ? null
                : Map<(String, int, int, int), String>.of(hashes);
            final stored = await _runStoreCoverFileOnDisk(
              logicalKey: source.logicalKey,
              sourcePath: source.sourcePath,
              outputDirectoryPath: outputDir,
              namespace: namespace,
              fileStem: null,
              knownHashes: knownHashes,
              partId: partId,
            );
            if (stored != null) {
              output = stored.outputPath;
              created = stored.created;
              if (stored.fingerprint != null && stored.computedStem != null) {
                hashes[stored.fingerprint!] = stored.computedStem!;
              }
            }
          }
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
        prepared.add((
          logicalKey: source.logicalKey,
          outputPath: output,
          created: created,
        ));
      }
    });
    if (epoch != _clearEpoch) {
      return List<String?>.filled(sources.length, null);
    }
    if (prepared.isEmpty) return results;
    return _enqueue(() async {
      if (epoch != _clearEpoch) {
        return List<String?>.filled(sources.length, null);
      }
      final managedCount = _managedArtifacts.length;
      var changed = false;
      try {
        for (final item in prepared) {
          if (item.created) {
            _recordCreatedArtifact(File(item.outputPath));
          }
          final key = _canonicalLogicalKey(item.logicalKey);
          final stored = _storedValue(item.outputPath);
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

  Future<T> _trackFileWrite<T>(Future<T> Function() action) {
    final done = Completer<void>();
    _activeFileWrites.add(done.future);
    return action().whenComplete(() {
      _activeFileWrites.remove(done.future);
      done.complete();
    });
  }

  static Future<
    ({
      String outputPath,
      bool created,
      (String, int, int, int)? fingerprint,
      String? computedStem,
    })?
  >
  _runStoreCoverFileOnDisk({
    required String logicalKey,
    required String sourcePath,
    required String outputDirectoryPath,
    required CoverArtworkNamespace namespace,
    required String? fileStem,
    required Map<(String, int, int, int), String>? knownHashes,
    required int partId,
  }) {
    if (IOOverrides.current != null) {
      return _storeCoverFileOnDisk(
        logicalKey: logicalKey,
        sourcePath: sourcePath,
        outputDirectoryPath: outputDirectoryPath,
        namespace: namespace,
        fileStem: fileStem,
        knownHashes: knownHashes,
        partId: partId,
      );
    }
    return Isolate.run(
      () => _storeCoverFileOnDisk(
        logicalKey: logicalKey,
        sourcePath: sourcePath,
        outputDirectoryPath: outputDirectoryPath,
        namespace: namespace,
        fileStem: fileStem,
        knownHashes: knownHashes,
        partId: partId,
      ),
    );
  }

  String _namespaceDirectoryPath(CoverArtworkNamespace namespace) =>
      path.joinAll([
        _root.path,
        namespace.name,
        if (_isAndroid() && namespace != CoverArtworkNamespace.remote)
          'android-v$_androidGeneratedArtworkVersion',
      ]);

  static final RegExp _sha256HexPattern = RegExp(r'^[0-9a-f]{64}$');

  static String? _sha256HexStem(String stem) =>
      stem.length == 64 && _sha256HexPattern.hasMatch(stem) ? stem : null;

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
    }, coalesce: true);
  }

  bool get hasBindings => _bindings.isNotEmpty;

  Future<void> invalidate(Iterable<String> logicalKeys) {
    if (!_initialized) return Future<void>.value();
    var changed = false;
    for (final key in logicalKeys) {
      changed = _bindings.remove(_canonicalLogicalKey(key)) != null || changed;
    }
    return changed ? _enqueue<void>(_persistIndex) : Future<void>.value();
  }

  Future<void> invalidateMatching(
    Iterable<String> logicalKeys, {
    bool Function(String trackIdentity)? trackIdentityMatches,
  }) {
    if (!_initialized || _bindings.isEmpty) return Future<void>.value();
    var changed = false;
    for (final key in logicalKeys) {
      changed = _bindings.remove(_canonicalLogicalKey(key)) != null || changed;
    }
    if (trackIdentityMatches != null && _bindings.isNotEmpty) {
      final matched = <String>[];
      for (final key in _bindings.keys) {
        if (!key.startsWith('track:')) continue;
        final source = key.substring('track:'.length);
        final pipeAt = source.indexOf('|');
        final identity = pipeAt < 0 ? source : source.substring(0, pipeAt);
        if (trackIdentityMatches(identity)) matched.add(key);
      }
      for (final key in matched) {
        changed = _bindings.remove(key) != null || changed;
      }
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
        await _persistIndex(immediate: true);
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
          _accessedArtifacts.remove(reference);
          changed = true;
        }
      } finally {
        if (changed) await _persistIndex();
      }
      return deletedBytes;
    });
  }

  void trimMemory() {
    while (_accessedArtifacts.length > _trimmedAccessedArtifacts) {
      _accessedArtifacts.remove(_accessedArtifacts.first);
    }
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
      final reference = _referenceKey(value);
      _accessedArtifacts.remove(reference);
      _accessedArtifacts.add(reference);
      while (_accessedArtifacts.length > _maxAccessedArtifacts) {
        _accessedArtifacts.remove(_accessedArtifacts.first);
      }
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
            !_androidVersionSegmentPattern.hasMatch(parts[1])) ||
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
      while (_activeFileWrites.isNotEmpty) {
        await Future.wait(_activeFileWrites.toList(growable: false));
      }
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

  Future<T> _enqueue<T>(
    Future<T> Function() operation, {
    bool coalesce = false,
  }) {
    final precedingCommit = coalesce ? null : _pendingCommit;
    if (!coalesce) {
      _pendingCommit = null;
      _pendingBatchSize = 0;
    }
    final commit = _pendingCommit ??= Completer<void>();
    // Bound how long callers wait if other producers keep adding artwork.
    final closesBatch = !coalesce || ++_pendingBatchSize == 32;
    if (closesBatch) {
      _pendingCommit = null;
      _pendingBatchSize = 0;
    }
    _queuedOperations++;
    final result = _operations.then((_) async {
      // Bulk import, maintenance and authored references are barriers: earlier
      // small writes must finish before the potentially long operation starts.
      if (precedingCommit != null) await _commitIndex(precedingCommit);
      try {
        return await operation();
      } finally {
        _queuedOperations--;
        if (closesBatch ||
            (_queuedOperations == 0 && _activeCoalescedPrepares == 0)) {
          if (identical(_pendingCommit, commit)) {
            _pendingCommit = null;
            _pendingBatchSize = 0;
          }
          await _commitIndex(commit);
        }
      }
    });
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
    // The operation queue can advance without writing the full index for each
    // cover, but callers still observe a durable commit before completion.
    return Future.wait<Object?>([
      result,
      commit.future,
    ]).then((values) => values.first as T);
  }

  void _flushPendingCommitIfIdle() {
    if (_queuedOperations != 0 ||
        _activeCoalescedPrepares != 0 ||
        _pendingCommit == null) {
      return;
    }
    final commit = _pendingCommit!;
    _pendingCommit = null;
    _pendingBatchSize = 0;
    _operations = _operations.then((_) => _commitIndex(commit));
  }

  Future<void> _commitIndex(Completer<void> commit) async {
    if (commit.isCompleted) return;
    try {
      if (_indexDirty) await _writeIndex();
      commit.complete();
    } catch (error, stackTrace) {
      commit.completeError(error, stackTrace);
    }
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

  Future<void> _persistIndex({bool immediate = false}) async {
    _indexDirty = true;
    if (immediate || _queuedOperations == 0) await _writeIndex();
  }

  Future<void> _writeIndex() async {
    await _root.create(recursive: true);
    final partial = File('${_index.path}.part');
    final snapshot = <String, Object>{
      'version': 2,
      if (_isAndroid())
        'androidGeneratedVersion': _androidGeneratedArtworkVersion,
      'bindings': _bindings,
      'legacyAliases': _legacyAliases,
      'managedArtifacts': _managedArtifacts,
    };
    final payload =
        _bindings.length + _legacyAliases.length + _managedArtifacts.length >
            256
        ? await _encodeCoverIndex(snapshot)
        : json.encode(snapshot);
    try {
      await partial.writeAsString(payload, flush: true);
      if (await _index.exists()) await _index.delete();
      await partial.rename(_index.path);
      _indexDirty = false;
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
      value.replaceAll(_unsafeFileNameChars, '_');

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

Future<String> _encodeCoverIndex(Map<String, Object> snapshot) =>
    Isolate.run(() => json.encode(snapshot));

Future<
  ({
    String outputPath,
    bool created,
    (String, int, int, int)? fingerprint,
    String? computedStem,
  })?
>
_storeCoverFileOnDisk({
  required String logicalKey,
  required String sourcePath,
  required String outputDirectoryPath,
  required CoverArtworkNamespace namespace,
  required String? fileStem,
  required Map<(String, int, int, int), String>? knownHashes,
  required int partId,
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
  String? computedStem;
  if (fileStem != null) {
    stem = fileStem;
  } else if (namespace == CoverArtworkNamespace.embedded) {
    final existingStem = CoverArtworkStore._sha256HexStem(
      path.basenameWithoutExtension(sourcePath),
    );
    if (existingStem != null) {
      stem = existingStem;
    } else {
      final cached = knownHashes?[fingerprint];
      if (cached != null) {
        stem = cached;
      } else {
        stem = (await sha256.bind(source.openRead()).first).toString();
        computedStem = stem;
      }
    }
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
  final safeName = '$stem.image'.replaceAll(
    CoverArtworkStore._unsafeFileNameChars,
    '_',
  );
  final output = File(path.join(outputDirectoryPath, safeName));
  var created = false;
  if (!await _isUsableCoverFile(output.path)) {
    final existed = await output.exists();
    await _copyCoverFile(source, output, partId: partId);
    created = !existed;
  }
  return (
    outputPath: output.path,
    created: created,
    fingerprint: fingerprint,
    computedStem: computedStem,
  );
}

Future<bool> _isUsableCoverFile(String value) async {
  try {
    final stat = await File(value).stat();
    return stat.type == FileSystemEntityType.file && stat.size > 0;
  } on FileSystemException {
    return false;
  }
}

Future<void> _copyCoverFile(
  File source,
  File output, {
  required int partId,
}) async {
  await output.parent.create(recursive: true);
  final partial = File('${output.path}.$partId.part');
  try {
    await source.openRead().pipe(partial.openWrite());
    if (await _isUsableCoverFile(output.path)) return;
    if (await output.exists()) {
      try {
        await output.delete();
      } on PathNotFoundException {
        // Another concurrent writer already replaced the target.
      }
    }
    try {
      await partial.rename(output.path);
    } on FileSystemException {
      if (await _isUsableCoverFile(output.path)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (!await _isUsableCoverFile(output.path)) rethrow;
    }
  } finally {
    if (await partial.exists()) {
      try {
        await partial.delete();
      } on FileSystemException {
        // Ignore cleanup races on temporary staging files.
      }
    }
  }
}

typedef _CoverIndex = ({
  Map<String, String> bindings,
  Map<String, String> aliases,
  Map<String, int> managed,
  bool changed,
});

_CoverIndex _decodeCoverIndex(String? payload, String rootPath, bool android) {
  final raw = payload == null ? null : json.decode(payload);
  final hasValidHeader =
      raw is Map && (raw['version'] == 1 || raw['version'] == 2);
  final decoded = hasValidHeader ? raw : const <String, Object?>{};
  Map<String, String> stringMap(Object? value) => value is Map
      ? <String, String>{
          for (final entry in value.entries)
            if (entry.key.toString().isNotEmpty &&
                (entry.value?.toString() ?? '').isNotEmpty)
              entry.key.toString(): entry.value.toString(),
        }
      : <String, String>{};
  var changed = payload != null && !hasValidHeader;
  final bindings = <String, String>{};
  for (final entry in stringMap(decoded['bindings']).entries) {
    final key = _canonicalLogicalKey(entry.key);
    if (key != entry.key) changed = true;
    bindings[key] = entry.value;
  }
  final generatedVersion = decoded['androidGeneratedVersion'];
  if (android &&
      (generatedVersion is num ? generatedVersion.toInt() : 0) !=
          _androidGeneratedArtworkVersion) {
    bindings.removeWhere((key, value) {
      final uri = value.contains('://');
      final resolved = uri || path.isAbsolute(value)
          ? value
          : path.join(rootPath, value);
      return const [
            'video:',
            'native:',
            'embedded:',
            'track:',
            'folder:',
            'source-image:',
          ].any(key.startsWith) &&
          !key.contains('remote-cover:') &&
          !uri &&
          !path.isWithin(path.join(rootPath, 'remote'), resolved) &&
          !path.isWithin(
            path.join(path.dirname(rootPath), 'portable_card_covers'),
            resolved,
          );
    });
    changed = true;
  }
  final managed = decoded['managedArtifacts'];
  return (
    bindings: bindings,
    aliases: stringMap(decoded['legacyAliases']),
    managed: <String, int>{
      if (managed is Map)
        for (final entry in managed.entries)
          if (entry.key is String &&
              entry.value is int &&
              (entry.value as int) >= 0)
            entry.key as String: entry.value as int,
    },
    changed: changed,
  );
}
