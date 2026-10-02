import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:charset/charset.dart';
import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../domain/local_directory_cache_repository.dart';

enum WorkTextEncoding {
  utf8('UTF-8'),
  utf16Le('UTF-16 LE'),
  utf16Be('UTF-16 BE'),
  shiftJis('Shift-JIS'),
  gbk('GBK');

  const WorkTextEncoding(this.label);
  final String label;
}

enum WorkDocType {
  text,
  markdown,
  pdf;

  static WorkDocType fromPath(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.md')) return WorkDocType.markdown;
    if (lower.endsWith('.pdf')) return WorkDocType.pdf;
    return WorkDocType.text;
  }
}

@immutable
class WorkTextFile {
  const WorkTextFile({
    required this.name,
    required this.relativePath,
    required this.path,
    this.fallbackUrls = const [],
  });

  final String name;
  final String relativePath;
  final String path;
  final List<String> fallbackUrls;

  WorkDocType get docType {
    final namedType = WorkDocType.fromPath(name);
    return namedType != WorkDocType.text
        ? namedType
        : WorkDocType.fromPath(path);
  }

  bool get isPdf => docType == WorkDocType.pdf;
  bool get isMarkdown => docType == WorkDocType.markdown;

  String get displayName {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      return name.substring(0, dotIndex);
    }
    return name;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkTextFile &&
          name == other.name &&
          relativePath == other.relativePath &&
          path == other.path &&
          listEquals(fallbackUrls, other.fallbackUrls);

  @override
  int get hashCode =>
      Object.hash(name, relativePath, path, Object.hashAll(fallbackUrls));
}

({String text, WorkTextEncoding encoding}) decodeWorkText(
  Uint8List bytes, {
  WorkTextEncoding? overrideEncoding,
}) {
  if (bytes.isEmpty) {
    return (text: '', encoding: overrideEncoding ?? WorkTextEncoding.utf8);
  }

  if (overrideEncoding != null) {
    final text = _decodeWithEncoding(bytes, overrideEncoding);
    return (text: text, encoding: overrideEncoding);
  }

  // 1. Check for UTF-8 BOM: 0xEF, 0xBB, 0xBF
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    final text = utf8.decode(bytes.sublist(3), allowMalformed: true);
    return (text: text, encoding: WorkTextEncoding.utf8);
  }

  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return (
      text: _decodeUtf16(bytes, littleEndian: true, start: 2),
      encoding: WorkTextEncoding.utf16Le,
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return (
      text: _decodeUtf16(bytes, littleEndian: false, start: 2),
      encoding: WorkTextEncoding.utf16Be,
    );
  }

  // 2. Try strict UTF-8
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    return (text: text, encoding: WorkTextEncoding.utf8);
  } on FormatException {
    // Not valid UTF-8, proceed to Shift-JIS vs GBK
  }

  // 3. Detect between Shift-JIS and GBK
  final detected = Charset.detect(bytes, orders: [shiftJis, gbk]);
  if (detected == gbk) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.gbk),
      encoding: WorkTextEncoding.gbk,
    );
  } else if (detected == shiftJis) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.shiftJis),
      encoding: WorkTextEncoding.shiftJis,
    );
  }

  final canShiftJis = Charset.canDecode(shiftJis, bytes);
  final canGbk = Charset.canDecode(gbk, bytes);
  if (canShiftJis && !canGbk) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.shiftJis),
      encoding: WorkTextEncoding.shiftJis,
    );
  }
  if (canGbk && !canShiftJis) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.gbk),
      encoding: WorkTextEncoding.gbk,
    );
  }

  // Default fallback: Shift-JIS (standard for Japanese voice drama) -> GBK -> UTF-8
  try {
    final text = shiftJis.decode(bytes);
    return (text: text, encoding: WorkTextEncoding.shiftJis);
  } catch (_) {
    try {
      final text = gbk.decode(bytes);
      return (text: text, encoding: WorkTextEncoding.gbk);
    } catch (_) {
      return (
        text: utf8.decode(bytes, allowMalformed: true),
        encoding: WorkTextEncoding.utf8,
      );
    }
  }
}

String _decodeWithEncoding(Uint8List bytes, WorkTextEncoding encoding) {
  try {
    switch (encoding) {
      case WorkTextEncoding.utf8:
        return utf8.decode(bytes, allowMalformed: true);
      case WorkTextEncoding.utf16Le:
        return _decodeUtf16(bytes, littleEndian: true, start: 0);
      case WorkTextEncoding.utf16Be:
        return _decodeUtf16(bytes, littleEndian: false, start: 0);
      case WorkTextEncoding.shiftJis:
        return shiftJis.decode(bytes);
      case WorkTextEncoding.gbk:
        return gbk.decode(bytes);
    }
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

String _decodeUtf16(
  Uint8List bytes, {
  required bool littleEndian,
  required int start,
}) {
  final codeUnits = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    codeUnits.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(codeUnits);
}

class WorkTextService {
  WorkTextService({
    FileCachePlatformGateway? platformGateway,
    HttpClient Function()? httpClientFactory,
    Object Function()? directoryRevision,
    LocalDirectoryCacheRepository? directoryCache,
    Future<List<CoverImageReference>> Function(String)? discoverImages,
  }) : _platformGateway = platformGateway ?? FileCachePlatformGateway.instance,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _directoryRevision = directoryRevision,
       _directoryCache = directoryCache,
       _discoverImages = discoverImages;

  final FileCachePlatformGateway _platformGateway;
  final HttpClient Function() _httpClientFactory;
  final Object Function()? _directoryRevision;
  final LocalDirectoryCacheRepository? _directoryCache;
  final Future<List<CoverImageReference>> Function(String)? _discoverImages;
  final _directoryFiles = <String, Future<List<WorkTextFile>>>{};
  final _textSnapshots = <String, List<WorkTextFile>>{};
  final _imageRequests =
      <String, Future<List<({String path, String sourcePath})>>>{};
  final _imageSnapshots = <String, List<({String path, String sourcePath})>>{};
  final _staleKeys = <String>{};
  final _pendingDirectoryWrites = <Future<void>>{};
  final _directoryChanges = StreamController<String>.broadcast();
  Object? _cachedDirectoryRevision;
  int _cacheGeneration = 0;
  bool _disposed = false;
  Future<void>? _clearTask;

  Stream<String> get directoryChanges => _directoryChanges.stream;

  Future<void> dispose() async {
    _disposed = true;
    await flushDirectoryCache();
    await _directoryChanges.close();
  }

  /// Completes discoveries already underway and their persistence before exit.
  Future<void> flushDirectoryCache() async {
    while (true) {
      final requests = <Future<Object?>>{
        ?_clearTask,
        ..._directoryFiles.values,
        ..._imageRequests.values,
        ..._pendingDirectoryWrites,
      };
      if (requests.isEmpty) return;
      await Future.wait(
        requests.map(
          (request) =>
              request.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ),
      );
    }
  }

  List<WorkTextFile>? cachedWorkTextFiles(String folderPath) =>
      _textSnapshots[PathMatcher.equivalenceKey(folderPath)];

  List<String>? cachedWorkImageFiles(String folderPath) =>
      _imageSnapshots[PathMatcher.equivalenceKey(folderPath)]
          ?.map((image) => image.path)
          .toList(growable: false);

  String sourcePathForWorkImage(String folderPath, String displayPath) {
    final files = _imageSnapshots[PathMatcher.equivalenceKey(folderPath)];
    if (files != null) {
      for (final file in files) {
        if (file.path == displayPath) return file.sourcePath;
      }
    }
    return displayPath;
  }

  Future<List<WorkTextFile>> findWorkTextFiles(String workFolderPath) =>
      _findWorkTexts(workFolderPath);

  Future<List<WorkTextFile>> refreshWorkTextFiles(String workFolderPath) =>
      _findWorkTexts(workFolderPath, refresh: true);

  Future<List<WorkTextFile>> _findWorkTexts(
    String workFolderPath, {
    bool refresh = false,
  }) => _findDirectoryFiles(
    kind: 'work_texts',
    folderPath: workFolderPath,
    requests: _directoryFiles,
    snapshots: _textSnapshots,
    discover: _discoverWorkTextFiles,
    decode: (map) => WorkTextFile(
      name: map['name'] as String,
      relativePath: map['relativePath'] as String,
      path: map['path'] as String,
    ),
    encode: (file) => {
      'name': file.name,
      'relativePath': file.relativePath,
      'path': file.path,
    },
    refresh: refresh,
  );

  Future<List<String>> findWorkImageFiles(String folderPath) =>
      _findWorkImages(folderPath);

  Future<List<String>> refreshWorkImageFiles(String folderPath) =>
      _findWorkImages(folderPath, refresh: true);

  Future<List<String>> _findWorkImages(
    String folderPath, {
    bool refresh = false,
  }) => _findDirectoryFiles(
    kind: 'work_images',
    folderPath: folderPath,
    requests: _imageRequests,
    snapshots: _imageSnapshots,
    discover: (folder) async {
      if (_discoverImages != null) {
        final images = await _discoverImages(folder);
        return images
            .map(
              (image) =>
                  (path: image.displayPath, sourcePath: image.sourcePath),
            )
            .toList(growable: false);
      }
      return (await _platformGateway.discoverRootImages(
            path: folder,
            rootFolder: folder,
          ))
          .map(
            (image) => (path: image.displayPath, sourcePath: image.sourcePath),
          )
          .toList(growable: false);
    },
    decode: (map) =>
        (path: map['path'] as String, sourcePath: map['sourcePath'] as String),
    encode: (file) => {'path': file.path, 'sourcePath': file.sourcePath},
    refresh: refresh,
  ).then((images) => images.map((image) => image.path).toList(growable: false));

  Future<void> clearDirectoryCache() {
    final pending = _clearTask;
    if (pending != null) return pending;
    late final Future<void> task;
    task = _clearDirectoryCache().whenComplete(() {
      if (identical(_clearTask, task)) _clearTask = null;
    });
    _clearTask = task;
    return task;
  }

  Future<void> _clearDirectoryCache() async {
    _cacheGeneration++;
    _directoryFiles.clear();
    _imageRequests.clear();
    _textSnapshots.clear();
    _imageSnapshots.clear();
    _staleKeys.clear();
    await Future.wait(
      _pendingDirectoryWrites.map(
        (write) =>
            write.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await _directoryCache?.clearDirectorySnapshots();
  }

  Future<List<T>> _findDirectoryFiles<T>({
    required String kind,
    required String folderPath,
    required Map<String, Future<List<T>>> requests,
    required Map<String, List<T>> snapshots,
    required Future<List<T>> Function(String) discover,
    required T Function(Map<String, Object?>) decode,
    required Map<String, Object?> Function(T) encode,
    bool refresh = false,
  }) {
    if (_disposed) {
      return Future.error(StateError('WorkTextService is disposed.'));
    }
    final clearing = _clearTask;
    if (clearing != null) {
      return clearing.then(
        (_) => _findDirectoryFiles(
          kind: kind,
          folderPath: folderPath,
          requests: requests,
          snapshots: snapshots,
          discover: discover,
          decode: decode,
          encode: encode,
          refresh: refresh,
        ),
      );
    }
    if (folderPath.trim().isEmpty) return Future.value(const []);
    final revision = _directoryRevision?.call();
    if (_cachedDirectoryRevision != revision) {
      _staleKeys.addAll(_textSnapshots.keys.map((key) => 'work_texts:$key'));
      _staleKeys.addAll(_imageSnapshots.keys.map((key) => 'work_images:$key'));
      _directoryFiles.clear();
      _imageRequests.clear();
      _cachedDirectoryRevision = revision;
    }
    final key = PathMatcher.equivalenceKey(folderPath);
    if (refresh) _staleKeys.remove('$kind:$key');
    final cached = snapshots[key];
    if (!refresh && cached != null) {
      if (_staleKeys.remove('$kind:$key')) {
        unawaited(
          _findDirectoryFiles(
            kind: kind,
            folderPath: folderPath,
            requests: requests,
            snapshots: snapshots,
            discover: discover,
            decode: decode,
            encode: encode,
            refresh: true,
          ),
        );
      }
      return Future.value(cached);
    }
    final pending = requests[key];
    if (pending != null) return pending;
    final generation = _cacheGeneration;
    var restored = false;
    late final Future<List<T>> request;
    request =
        (() async {
          if (!refresh && _directoryCache != null) {
            try {
              final payload = await _directoryCache.loadDirectorySnapshot(
                kind: kind,
                key: key,
              );
              if (payload != null && payload['version'] == 1) {
                final files = List<T>.unmodifiable(
                  (payload['files'] as List)
                      .map(
                        (item) =>
                            decode(Map<String, Object?>.from(item as Map)),
                      )
                      .toList(growable: false),
                );
                if (generation == _cacheGeneration &&
                    identical(requests[key], request)) {
                  snapshots[key] = files;
                  restored = true;
                  if (!_disposed) _directoryChanges.add(key);
                }
                return files;
              }
            } catch (error, stackTrace) {
              AppLogService.warning(
                'load_local_directory_snapshot_failed',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
          try {
            final files = List<T>.unmodifiable(await discover(folderPath));
            if (generation == _cacheGeneration &&
                identical(requests[key], request)) {
              final changed = !listEquals(snapshots[key], files);
              snapshots[key] = files;
              if (changed && !_disposed) _directoryChanges.add(key);
              try {
                final write = _directoryCache?.saveDirectorySnapshot(
                  kind: kind,
                  key: key,
                  payload: {
                    'version': 1,
                    'files': files.map(encode).toList(growable: false),
                  },
                );
                if (write != null) {
                  _pendingDirectoryWrites.add(write);
                  try {
                    await write;
                  } finally {
                    _pendingDirectoryWrites.remove(write);
                  }
                }
              } catch (error, stackTrace) {
                AppLogService.warning(
                  'save_local_directory_snapshot_failed',
                  error: error,
                  stackTrace: stackTrace,
                );
              }
            }
            return files;
          } catch (error, stackTrace) {
            AppLogService.warning(
              'discover_local_directory_failed',
              error: error,
              stackTrace: stackTrace,
            );
            if (cached != null) return cached;
            Error.throwWithStackTrace(error, stackTrace);
          }
        })().whenComplete(() {
          if (!identical(requests[key], request)) return;
          requests.remove(key);
          if (snapshots.length > 32) snapshots.remove(snapshots.keys.first);
          if (restored && generation == _cacheGeneration && !_disposed) {
            unawaited(
              _findDirectoryFiles(
                kind: kind,
                folderPath: folderPath,
                requests: requests,
                snapshots: snapshots,
                discover: discover,
                decode: decode,
                encode: encode,
                refresh: true,
              ),
            );
          }
        });
    requests[key] = request;
    return request;
  }

  Future<List<WorkTextFile>> _discoverWorkTextFiles(
    String workFolderPath,
  ) async {
    final rawList = await _platformGateway.discoverWorkTexts(workFolderPath);
    return rawList
        .map((map) {
          return WorkTextFile(
            name: map['name'] ?? '',
            relativePath: map['relativePath'] ?? '',
            path: map['path'] ?? '',
          );
        })
        .where((f) => f.name.isNotEmpty && f.path.isNotEmpty)
        .toList(growable: false);
  }

  Future<({String text, WorkTextEncoding encoding})> readDecodedText(
    WorkTextFile file, {
    WorkTextEncoding? encodingOverride,
  }) async {
    final bytes = await readDocumentBytes(file);
    if (bytes == null) {
      return (text: '', encoding: encodingOverride ?? WorkTextEncoding.utf8);
    }
    return decodeWorkText(bytes, overrideEncoding: encodingOverride);
  }

  Future<Uint8List?> readDocumentBytes(WorkTextFile file) async {
    final filePath = file.path.trim();
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
      final client = _httpClientFactory();
      try {
        try {
          client.connectionTimeout = const Duration(seconds: 15);
        } catch (_) {
          // Timeout configuration is optional for custom test clients.
        }
        Object? lastError;
        for (final url in <String>{filePath, ...file.fallbackUrls}) {
          final uri = Uri.tryParse(url);
          if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
          HttpClientRequest? request;
          try {
            request = await client
                .getUrl(uri)
                .timeout(const Duration(seconds: 15));
            final response = await request.close().timeout(
              const Duration(seconds: 15),
            );
            if (response.statusCode < 200 || response.statusCode >= 300) {
              lastError = HttpException(
                'Document request failed (${response.statusCode}).',
                uri: uri,
              );
              await response.drain<void>();
              continue;
            }
            final bytesBuilder = BytesBuilder(copy: false);
            await for (final chunk in response.timeout(
              const Duration(seconds: 30),
            )) {
              bytesBuilder.add(chunk);
            }
            return bytesBuilder.takeBytes();
          } catch (error) {
            request?.abort(error);
            lastError = error;
          }
        }
        throw lastError ??
            HttpException('No valid document URL.', uri: Uri.parse(filePath));
      } catch (error, stackTrace) {
        AppLogService.warning(
          'read_remote_document_bytes_failed',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    return _platformGateway.readDocumentBytes(file.path);
  }
}
