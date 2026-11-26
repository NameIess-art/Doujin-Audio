import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:characters/characters.dart';
import 'package:charset/charset.dart';
import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as paths;

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/playback_media_reference.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

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
class PreparedWorkText {
  PreparedWorkText({
    required this.encoding,
    required List<String> textBlocks,
    required List<md.Node> markdownNodes,
  }) : textBlocks = List.unmodifiable(textBlocks),
       markdownNodes = List.unmodifiable(markdownNodes);

  final WorkTextEncoding encoding;
  final List<String> textBlocks;
  final List<md.Node> markdownNodes;
  bool get isEmpty => textBlocks.isEmpty && markdownNodes.isEmpty;
}

PreparedWorkText _prepareWorkText(
  (Uint8List, WorkDocType, WorkTextEncoding?) request,
) {
  final decoded = decodeWorkText(request.$1, overrideEncoding: request.$3);
  final text = decoded.text;
  if (request.$2 == WorkDocType.markdown) {
    // Parse the complete document so references and block syntax cross display boundaries.
    final nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseLines(const LineSplitter().convert(text));
    return PreparedWorkText(
      encoding: decoded.encoding,
      textBlocks: const [],
      markdownNodes: nodes,
    );
  }
  final blocks = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = start + 16 * 1024;
    if (end >= text.length) {
      end = text.length;
    } else {
      // Prefer a nearby line ending, but bound single-line layout and searching
      // as well. A missing newline must not turn a whole script into one Text.
      final lookaheadEnd = (end + 1024).clamp(0, text.length);
      final newline = text.substring(end, lookaheadEnd).indexOf('\n');
      if (newline >= 0) end += newline + 1;
      if (end < text.length) {
        final boundary = CharacterRange.at(text, end);
        end = boundary.stringBeforeLength;
        // An exceptionally large single grapheme stays intact even when it
        // exceeds the normal block limit (for example, many combining marks).
        if (end <= start) end = text.length - boundary.stringAfterLength;
      }
    }
    blocks.add(text.substring(start, end));
    start = end;
  }
  return PreparedWorkText(
    encoding: decoded.encoding,
    textBlocks: blocks,
    markdownNodes: const [],
  );
}

@immutable
class WorkTextFile {
  const WorkTextFile({
    required this.name,
    required this.relativePath,
    required this.path,
    this.fallbackUrls = const [],
    this.fileSizeBytes,
  });

  final String name;
  final String relativePath;
  final String path;
  final List<String> fallbackUrls;
  final int? fileSizeBytes;

  WorkDocType get docType {
    final namedType = WorkDocType.fromPath(name);
    return namedType != WorkDocType.text
        ? namedType
        : WorkDocType.fromPath(path);
  }

  bool get isPdf => docType == WorkDocType.pdf;
  bool get isMarkdown => docType == WorkDocType.markdown;

  bool get isSubtitle {
    final extension = paths.extension(name).toLowerCase();
    // Plain TXT scripts are also accepted by the parser, but their extension
    // alone does not establish that a work contains subtitles.
    return extension != '.txt' &&
        supportedSubtitleExtensions.contains(extension);
  }

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
          fileSizeBytes == other.fileSizeBytes &&
          listEquals(fallbackUrls, other.fallbackUrls);

  @override
  int get hashCode => Object.hash(
    name,
    relativePath,
    path,
    fileSizeBytes,
    Object.hashAll(fallbackUrls),
  );
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
  String stripBom(String value) =>
      value.startsWith('\uFEFF') ? value.substring(1) : value;
  try {
    switch (encoding) {
      case WorkTextEncoding.utf8:
        return stripBom(utf8.decode(bytes, allowMalformed: true));
      case WorkTextEncoding.utf16Le:
        return stripBom(_decodeUtf16(bytes, littleEndian: true, start: 0));
      case WorkTextEncoding.utf16Be:
        return stripBom(_decodeUtf16(bytes, littleEndian: false, start: 0));
      case WorkTextEncoding.shiftJis:
        return shiftJis.decode(bytes);
      case WorkTextEncoding.gbk:
        return gbk.decode(bytes);
    }
  } catch (_) {
    return stripBom(utf8.decode(bytes, allowMalformed: true));
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
  static const Duration defaultDirectoryCacheTtl = Duration(seconds: 60);

  WorkTextService({
    FileCachePlatformGateway? platformGateway,
    HttpClient Function()? httpClientFactory,
    Future<List<CoverImageReference>> Function(String)? discoverImages,
    Future<List<CoverImageReference>> Function(String, {required bool refresh})?
    discoverImagesWithRefresh,
    bool combineWindowsLocalDiscovery = false,
    void Function(String folderPath)? onCombinedImagesRefreshed,
    Duration directoryCacheTtl = defaultDirectoryCacheTtl,
    DateTime Function()? clock,
  }) : _platformGateway = platformGateway ?? FileCachePlatformGateway.instance,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _discoverImages = discoverImages,
       _discoverImagesWithRefresh = discoverImagesWithRefresh,
       _combineWindowsLocalDiscovery = combineWindowsLocalDiscovery,
       _onCombinedImagesRefreshed = onCombinedImagesRefreshed,
       _directoryCacheTtl = directoryCacheTtl,
       _clock = clock ?? DateTime.now;

  final FileCachePlatformGateway _platformGateway;
  final HttpClient Function() _httpClientFactory;
  final Future<List<CoverImageReference>> Function(String)? _discoverImages;
  final Future<List<CoverImageReference>> Function(
    String, {
    required bool refresh,
  })?
  _discoverImagesWithRefresh;
  final bool _combineWindowsLocalDiscovery;
  final void Function(String folderPath)? _onCombinedImagesRefreshed;
  final Duration _directoryCacheTtl;
  final DateTime Function() _clock;
  final _directoryFiles = <String, Future<List<WorkTextFile>>>{};
  final _textSnapshots = <String, List<WorkTextFile>>{};
  final _textSnapshotTimes = <String, DateTime>{};
  final _imageRequests = <String, Future<List<CoverImageReference>>>{};
  final _imageSnapshots = <String, List<CoverImageReference>>{};
  final _imageSnapshotTimes = <String, DateTime>{};
  final _combinedRequests =
      <
        String,
        Future<({List<WorkTextFile> texts, List<CoverImageReference> images})>
      >{};
  int _cacheGeneration = 0;
  bool _disposed = false;
  final _activeReads = <WorkTextReadRequest>{};

  Future<void> dispose() async {
    _disposed = true;
    for (final request in _activeReads.toList(growable: false)) {
      request.cancel();
    }
    await clearDirectoryCache();
  }

  String sourcePathForWorkImage(String folderPath, String displayPath) {
    final files = _imageSnapshots[PathMatcher.equivalenceKey(folderPath)];
    if (files != null) {
      for (final file in files) {
        if (file.displayPath == displayPath) return file.sourcePath;
      }
    }
    return displayPath;
  }

  Future<List<WorkTextFile>> findWorkTextFiles(String folderPath) =>
      _findWorkTexts(folderPath);

  List<WorkTextFile>? resolvedWorkTextFiles(String folderPath) =>
      _textSnapshots[PathMatcher.equivalenceKey(folderPath)];

  List<CoverImageReference>? resolvedWorkImageFiles(String folderPath) =>
      _imageSnapshots[PathMatcher.equivalenceKey(folderPath)];

  Future<List<WorkTextFile>> refreshWorkTextFiles(String folderPath) =>
      _findWorkTexts(folderPath, refresh: true);

  Future<List<WorkTextFile>> _findWorkTexts(
    String folderPath, {
    bool refresh = false,
  }) => _findDirectoryFiles(
    folderPath: folderPath,
    requests: _directoryFiles,
    snapshots: _textSnapshots,
    snapshotTimes: _textSnapshotTimes,
    discover: _discoverWorkTextFiles,
    refresh: refresh,
  );

  Future<List<CoverImageReference>> findWorkImageFiles(String folderPath) =>
      _findWorkImages(folderPath);

  Future<List<CoverImageReference>> refreshWorkImageFiles(String folderPath) =>
      _findWorkImages(folderPath, refresh: true);

  Future<List<CoverImageReference>> _findWorkImages(
    String folderPath, {
    bool refresh = false,
  }) => _findDirectoryFiles(
    folderPath: folderPath,
    requests: _imageRequests,
    snapshots: _imageSnapshots,
    snapshotTimes: _imageSnapshotTimes,
    discover: (folder) =>
        _discoverImagesWithRefresh?.call(folder, refresh: refresh) ??
        _discoverImages?.call(folder) ??
        _platformGateway.discoverRootImages(
          path: folder,
          rootFolder: folder,
        ),
    refresh: refresh,
  );

  bool canCombineWorkFiles(String folderPath) =>
      _canUseCombinedWindowsDiscovery(folderPath);

  bool _canUseCombinedWindowsDiscovery(String folderPath) {
    if (!Platform.isWindows ||
        defaultTargetPlatform != TargetPlatform.windows ||
        folderPath.trim().isEmpty ||
        PathMatcher.isContentUri(folderPath) ||
        PathMatcher.isRemoteUri(folderPath)) {
      return false;
    }
    if (!identical(_platformGateway, FileCachePlatformGateway.instance)) {
      return false;
    }
    if (_discoverImages != null) return false;
    return _discoverImagesWithRefresh == null || _combineWindowsLocalDiscovery;
  }

  /// Discovers both work text files and work image references together.
  /// On Windows local folders, uses a single recursive filesystem traversal in
  /// one background isolate; on Android or custom test harnesses, runs the
  /// existing independent discovery methods concurrently.
  Future<({List<WorkTextFile>? texts, List<CoverImageReference>? images})>
  findWorkFiles(String folderPath, {bool refresh = false}) async {
    if (_disposed) {
      throw StateError('WorkTextService is disposed.');
    }
    if (folderPath.trim().isEmpty) {
      return (
        texts: const <WorkTextFile>[],
        images: const <CoverImageReference>[],
      );
    }
    if (_canUseCombinedWindowsDiscovery(folderPath)) {
      final key = PathMatcher.equivalenceKey(folderPath);
      final cachedTexts = _textSnapshots[key];
      final cachedImages = _imageSnapshots[key];
      final textTime = _textSnapshotTimes[key];
      final imageTime = _imageSnapshotTimes[key];
      final now = _clock();
      final textsFresh =
          cachedTexts != null &&
          textTime != null &&
          now.difference(textTime) < _directoryCacheTtl;
      final imagesFresh =
          cachedImages != null &&
          imageTime != null &&
          now.difference(imageTime) < _directoryCacheTtl;
      if (!refresh && textsFresh && imagesFresh) {
        return (texts: cachedTexts, images: cachedImages);
      }
      final existing = _combinedRequests[key];
      if (existing != null) {
        try {
          final result = await existing;
          if (refresh) _onCombinedImagesRefreshed?.call(folderPath);
          return (texts: result.texts, images: result.images);
        } catch (_) {
          return (texts: cachedTexts, images: cachedImages);
        }
      }
      final generation = _cacheGeneration;
      late final Future<
        ({List<WorkTextFile> texts, List<CoverImageReference> images})
      >
      request;
      request =
          (() async {
            final discovered = await _platformGateway.discoverWindowsWorkFiles(
              folderPath,
            );
            final discoveredTexts = _parseWorkTextFiles(discovered.texts);
            final texts =
                cachedTexts != null && listEquals(cachedTexts, discoveredTexts)
                ? cachedTexts
                : List<WorkTextFile>.unmodifiable(discoveredTexts);
            final images =
                cachedImages != null &&
                    listEquals(cachedImages, discovered.images)
                ? cachedImages
                : List<CoverImageReference>.unmodifiable(discovered.images);
            if (generation == _cacheGeneration &&
                identical(_combinedRequests[key], request)) {
              final stamp = _clock();
              _textSnapshots[key] = texts;
              _textSnapshotTimes[key] = stamp;
              _imageSnapshots[key] = images;
              _imageSnapshotTimes[key] = stamp;
            }
            return (texts: texts, images: images);
          })().whenComplete(() {
            if (!identical(_combinedRequests[key], request)) return;
            _combinedRequests.remove(key);
            if (_textSnapshots.length > 32) {
              final evictedKey = _textSnapshots.keys.first;
              _textSnapshots.remove(evictedKey);
              _textSnapshotTimes.remove(evictedKey);
            }
            if (_imageSnapshots.length > 32) {
              final evictedKey = _imageSnapshots.keys.first;
              _imageSnapshots.remove(evictedKey);
              _imageSnapshotTimes.remove(evictedKey);
            }
          });
      _combinedRequests[key] = request;
      try {
        final result = await request;
        if (refresh) _onCombinedImagesRefreshed?.call(folderPath);
        return (texts: result.texts, images: result.images);
      } catch (error, stackTrace) {
        AppLogService.warning(
          'discover_local_directory_failed',
          error: error,
          stackTrace: stackTrace,
        );
        return (texts: cachedTexts, images: cachedImages);
      }
    }

    List<WorkTextFile>? texts;
    List<CoverImageReference>? images;
    await Future.wait<void>([
      () async {
        try {
          texts = refresh
              ? await refreshWorkTextFiles(folderPath)
              : await findWorkTextFiles(folderPath);
        } catch (_) {
          // Keep indexed audio and image files available if text discovery fails.
        }
      }(),
      () async {
        try {
          images = refresh
              ? await refreshWorkImageFiles(folderPath)
              : await findWorkImageFiles(folderPath);
        } catch (_) {
          // Keep indexed audio and text files available if image discovery fails.
        }
      }(),
    ]);
    return (texts: texts, images: images);
  }

  Future<void> clearDirectoryCache() async {
    _cacheGeneration++;
    _directoryFiles.clear();
    _imageRequests.clear();
    _combinedRequests.clear();
    _textSnapshots.clear();
    _textSnapshotTimes.clear();
    _imageSnapshots.clear();
    _imageSnapshotTimes.clear();
  }

  Future<List<T>> _findDirectoryFiles<T>({
    required String folderPath,
    required Map<String, Future<List<T>>> requests,
    required Map<String, List<T>> snapshots,
    required Map<String, DateTime> snapshotTimes,
    required Future<List<T>> Function(String) discover,
    bool refresh = false,
  }) {
    if (_disposed) {
      return Future.error(StateError('WorkTextService is disposed.'));
    }
    if (folderPath.trim().isEmpty) return Future.value(const []);
    final key = PathMatcher.equivalenceKey(folderPath);
    final cached = snapshots[key];
    final cachedAt = snapshotTimes[key];
    final isFresh =
        cached != null &&
        cachedAt != null &&
        _clock().difference(cachedAt) < _directoryCacheTtl;
    if (!refresh && isFresh) return Future.value(cached);
    final pending = requests[key];
    if (pending != null) return pending;
    final generation = _cacheGeneration;
    late final Future<List<T>> request;
    request =
        (() async {
          try {
            final discovered = await discover(folderPath);
            // Directory indexes use snapshot identity. Keep it stable when a
            // real refresh finds the same files, including an empty folder.
            final files = cached != null && listEquals(cached, discovered)
                ? cached
                : List<T>.unmodifiable(discovered);
            if (generation == _cacheGeneration &&
                identical(requests[key], request)) {
              snapshots[key] = files;
              snapshotTimes[key] = _clock();
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
          if (snapshots.length > 32) {
            final evictedKey = snapshots.keys.first;
            snapshots.remove(evictedKey);
            snapshotTimes.remove(evictedKey);
          }
        });
    requests[key] = request;
    return request;
  }

  Future<List<WorkTextFile>> _discoverWorkTextFiles(
    String workFolderPath,
  ) async {
    final rawList = await _platformGateway.discoverWorkTexts(workFolderPath);
    return _parseWorkTextFiles(rawList);
  }

  static List<WorkTextFile> _parseWorkTextFiles(
    List<Map<String, String>> rawList,
  ) {
    return rawList
        .map((map) {
          return WorkTextFile(
            name: map['name'] ?? '',
            relativePath: map['relativePath'] ?? '',
            path: map['path'] ?? '',
            fileSizeBytes: int.tryParse(map['fileSizeBytes'] ?? ''),
          );
        })
        .where((f) => f.name.isNotEmpty && f.path.isNotEmpty)
        .toList(growable: false);
  }

  Future<({String text, WorkTextEncoding encoding})> readDecodedText(
    WorkTextFile file, {
    WorkTextEncoding? encodingOverride,
    WorkTextReadRequest? request,
  }) async {
    final bytes = await readDocumentBytes(file, request: request);
    _checkReadActive(request);
    if (bytes == null) {
      return (text: '', encoding: encodingOverride ?? WorkTextEncoding.utf8);
    }
    return decodeWorkText(bytes, overrideEncoding: encodingOverride);
  }

  Future<PreparedWorkText> readPreparedDocument(
    WorkTextFile file, {
    WorkTextEncoding? encodingOverride,
    WorkTextReadRequest? request,
  }) async {
    if (file.isPdf) throw ArgumentError('PDF uses readDocumentBytes.');
    final bytes = await readDocumentBytes(file, request: request);
    _checkReadActive(request);
    final prepared = await prepareDocument(
      bytes ?? Uint8List(0),
      type: file.docType,
      encodingOverride: encodingOverride,
    );
    _checkReadActive(request);
    return prepared;
  }

  Future<PreparedWorkText> prepareDocument(
    Uint8List bytes, {
    required WorkDocType type,
    WorkTextEncoding? encodingOverride,
  }) {
    final request = (bytes, type, encodingOverride);
    return bytes.length >= 64 * 1024
        ? compute(
            _prepareWorkText,
            request,
            debugLabel: 'work_document_prepare',
          )
        : Future.value(_prepareWorkText(request));
  }

  void _checkReadActive(WorkTextReadRequest? request) {
    if (_disposed || request?.cancelled == true) {
      throw const WorkTextReadCancelled();
    }
  }

  Future<Uint8List?> readDocumentBytes(
    WorkTextFile file, {
    WorkTextReadRequest? request,
  }) async {
    final active = request ?? WorkTextReadRequest();
    _checkReadActive(active);
    _activeReads.add(active);
    try {
      final bytes = await _readDocumentBytes(file, active);
      _checkReadActive(active);
      return bytes;
    } finally {
      _activeReads.remove(active);
    }
  }

  Future<Uint8List?> _readDocumentBytes(
    WorkTextFile file,
    WorkTextReadRequest active,
  ) async {
    final filePath = file.path.trim();
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
      final client = _httpClientFactory();
      active._abort = () => client.close(force: true);
      try {
        try {
          client.connectionTimeout = const Duration(seconds: 15);
        } catch (_) {
          // Timeout configuration is optional for custom test clients.
        }
        Object? lastError;
        for (final url in <String>{filePath, ...file.fallbackUrls}) {
          _checkReadActive(active);
          final uri = Uri.tryParse(url);
          if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
          HttpClientRequest? request;
          try {
            request = await client
                .getUrl(uri)
                .timeout(const Duration(seconds: 15));
            for (final header
                in PlaybackMediaReference.requestHeadersForUri(uri).entries) {
              request.headers.set(header.key, header.value);
            }
            _checkReadActive(active);
            final response = await request.close().timeout(
              const Duration(seconds: 15),
            );
            _checkReadActive(active);
            if (response.statusCode < 200 || response.statusCode >= 300) {
              lastError = HttpException(
                'Document request failed (${response.statusCode}).',
                uri: uri,
              );
              await response.listen(null).cancel();
              continue;
            }
            final bytesBuilder = BytesBuilder(copy: false);
            await for (final chunk in response.timeout(
              const Duration(seconds: 30),
            )) {
              _checkReadActive(active);
              bytesBuilder.add(chunk);
            }
            return bytesBuilder.takeBytes();
          } catch (error) {
            request?.abort(error);
            _checkReadActive(active);
            lastError = error;
          }
        }
        throw lastError ??
            HttpException('No valid document URL.', uri: Uri.parse(filePath));
      } on WorkTextReadCancelled {
        rethrow;
      } catch (error, stackTrace) {
        AppLogService.warning(
          'read_remote_document_bytes_failed',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      } finally {
        active._abort = null;
        client.close(force: true);
      }
    }
    return _platformGateway.readDocumentBytes(file.path);
  }
}

final class WorkTextReadRequest {
  bool _cancelled = false;
  void Function()? _abort;
  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _abort?.call();
    _abort = null;
  }
}

final class WorkTextReadCancelled implements Exception {
  const WorkTextReadCancelled();
}
