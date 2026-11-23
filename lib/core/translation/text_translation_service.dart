import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../logging/app_log_service.dart';
import '../persistence/json_document_store.dart';

const textTranslationBatchMaxCharacters = 4000;
const textTranslationBatchMaxItems = 50;
const textTranslationCacheDirectoryName = 'page_translations';

enum TextTranslationFailure {
  unavailable,
  invalidResponse,
  rateLimited,
  unusualTraffic,
}

class TextTranslationRequest {
  bool _cancelled = false;
  final Set<void Function()> _pendingCancellations = {};
  void Function()? _abort;
  void Function()? _onCancel;

  bool get cancelled => _cancelled;

  @visibleForTesting
  int get pendingOperationCount => _pendingCancellations.length;

  void cancel() {
    if (cancelled) return;
    _cancelled = true;
    final pending = _pendingCancellations.toList(growable: false);
    _pendingCancellations.clear();
    for (final cancel in pending) {
      cancel();
    }
    _abort?.call();
    _onCancel?.call();
  }

  Future<T> _active<T>(Future<T> future) async {
    if (cancelled) throw const _TranslationCancelled();
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) {
        result.completeError(const _TranslationCancelled());
      }
    }

    _pendingCancellations.add(cancel);
    // Observe late errors after cancellation, but release the cancellation
    // listener on completion so a live page cannot retain old result snapshots.
    unawaited(
      future.then<void>(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    try {
      return await result.future;
    } finally {
      _pendingCancellations.remove(cancel);
    }
  }
}

class TextTranslationResult {
  TextTranslationResult({
    Map<String, String> translations = const {},
    this.failure,
  }) : translations = Map.unmodifiable(translations);

  final Map<String, String> translations;
  final TextTranslationFailure? failure;
}

typedef _TranslationKey = (String, String, String);

class TextTranslationService {
  TextTranslationService({
    HttpClient Function()? clientFactory,
    Uri? endpoint,
    JsonDocumentStore? documentStore,
    Future<Directory> Function()? temporaryDirectory,
    DateTime Function()? now,
    Duration requestInterval = const Duration(milliseconds: 250),
    Duration requestTimeout = const Duration(seconds: 20),
    Duration diskWriteDebounce = const Duration(milliseconds: 500),
    int memoryCapacity = 1000,
    int diskCapacity = 3000,
  }) : assert(memoryCapacity > 0),
       assert(diskCapacity >= memoryCapacity),
       _clientFactory = clientFactory ?? (() => HttpClient()),
       _endpoint =
           endpoint ?? Uri.https('translate.googleapis.com', '/translate_a/t'),
       _documentStore = documentStore,
       _cacheStoreIdentity = documentStore,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _now = now ?? DateTime.now,
       _requestInterval = requestInterval,
       _requestTimeout = requestTimeout,
       _diskWriteDebounce = diskWriteDebounce,
       _memoryCapacity = memoryCapacity,
       _diskCapacity = diskCapacity;

  final HttpClient Function() _clientFactory;
  final Uri _endpoint;
  JsonDocumentStore? _documentStore;
  final JsonDocumentStore? _cacheStoreIdentity;
  final Future<Directory> Function() _temporaryDirectory;
  final DateTime Function() _now;
  final Duration _requestInterval;
  final Duration _requestTimeout;
  final Duration _diskWriteDebounce;
  final int _memoryCapacity;
  final int _diskCapacity;
  final _memory = <_TranslationKey, String>{};
  final _recentlyAccessed = <_TranslationKey, String>{};
  final _pendingDiskAdditions = <_TranslationKey, String>{};
  final _requests = <TextTranslationRequest>{};
  // Pages and subtitle jobs share the same file even when they own different
  // service instances. Serialize read/modify/write and clearing as one operation.
  static Future<void> _diskTail = Future<void>.value();
  static final _cacheUsers = <TextTranslationService>{};
  HttpClient? _httpClient;
  Timer? _diskSaveTimer;
  ({String path, JsonDocumentStore? store})? _cacheKey;
  Future<Map<_TranslationKey, String>>? _diskEntries;
  Future<void> _operations = Future<void>.value();
  Future<JsonDocumentLocation?>? _location;
  DateTime? _lastRequestAt;
  DateTime? _cooldownUntil;
  TextTranslationFailure? _cooldownFailure;
  bool _disposed = false;
  int _cacheEpoch = 0;

  JsonDocumentStore get _store => _documentStore ??= DefaultJsonDocumentStore();

  TextTranslationRequest newRequest() {
    final request = TextTranslationRequest();
    request._onCancel = () => _requests.remove(request);
    if (_disposed) {
      request.cancel();
    } else {
      _requests.add(request);
    }
    return request;
  }

  String? cached(String text, String target, {String source = 'auto'}) {
    final key = (text, source, target);
    final value = _memory.remove(key);
    if (value != null) {
      _memory[key] = value;
      _recentlyAccessed.remove(key);
      _recentlyAccessed[key] = value;
      while (_recentlyAccessed.length > _memoryCapacity) {
        _recentlyAccessed.remove(_recentlyAccessed.keys.first);
      }
    }
    return value;
  }

  Future<TextTranslationResult> translate(
    List<String> texts, {
    required String target,
    required TextTranslationRequest request,
    String source = 'auto',
  }) async {
    if (_disposed || request.cancelled) return TextTranslationResult();
    final task = _operations.then(
      (_) =>
          _translate(texts, target: target, source: source, request: request),
    );
    // A failed caller must not poison the queue for later page requests.
    _operations = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      return await request._active(task);
    } on _TranslationCancelled {
      return TextTranslationResult();
    }
  }

  Future<TextTranslationResult> _translate(
    List<String> texts, {
    required String target,
    required String source,
    required TextTranslationRequest request,
  }) async {
    final result = <String, String>{};
    final additions = <_TranslationKey, String>{};
    final epoch = _cacheEpoch;
    try {
      if (request.cancelled || _disposed) return TextTranslationResult();
      final unique = texts.where(canTranslateText).toSet();
      for (final text in unique) {
        final value = cached(text, target, source: source);
        if (value != null) result[text] = value;
      }
      if (result.length == unique.length) {
        return TextTranslationResult(translations: result);
      }
      final entries = await request._active(_readDisk());
      for (final text in unique.where((text) => !result.containsKey(text))) {
        final key = (text, source, target);
        final value = entries.remove(key);
        if (value == null) continue;
        entries[key] = value;
        _remember(key, value);
        result[text] = value;
      }
      final missing = unique
          .where((text) => !result.containsKey(text))
          .toList();
      for (final batch in textTranslationBatches(missing)) {
        final cooldown = _cooldownUntil;
        if (cooldown != null && _now().isBefore(cooldown)) {
          return TextTranslationResult(
            translations: result,
            failure: _cooldownFailure,
          );
        }
        final last = _lastRequestAt;
        if (last != null) {
          final delay = _requestInterval - _now().difference(last);
          if (delay > Duration.zero) {
            await request._active(Future<void>.delayed(delay));
          }
        }
        final translated = await _fetch(batch, source, target, request);
        for (var index = 0; index < batch.length; index++) {
          final key = (batch[index], source, target);
          result[batch[index]] = translated[index];
          _remember(key, translated[index]);
          entries.remove(key);
          entries[key] = translated[index];
          additions[key] = translated[index];
        }
        while (entries.length > _diskCapacity) {
          entries.remove(entries.keys.first);
        }
      }
      return TextTranslationResult(translations: result);
    } on _TranslationCancelled {
      return TextTranslationResult(translations: result);
    } on _TranslationError catch (error) {
      return TextTranslationResult(
        translations: result,
        failure: error.failure,
      );
    } on IOException {
      return TextTranslationResult(
        translations: result,
        failure: TextTranslationFailure.unavailable,
      );
    } on TimeoutException {
      return TextTranslationResult(
        translations: result,
        failure: TextTranslationFailure.unavailable,
      );
    } finally {
      if (additions.isNotEmpty && epoch == _cacheEpoch) {
        _saveDisk(additions);
      }
    }
  }

  HttpClient _ensureClient() {
    final existing = _httpClient;
    if (existing != null) return existing;
    final client = _clientFactory();
    client.connectionTimeout = _requestTimeout;
    return _httpClient = client;
  }

  Future<List<String>> _fetch(
    List<String> texts,
    String source,
    String target,
    TextTranslationRequest request,
  ) async {
    if (request.cancelled || _disposed) throw const _TranslationCancelled();
    final client = _ensureClient();
    HttpClientRequest? pendingRequest;
    StreamSubscription<String>? responseSubscription;
    var aborted = false;
    var responseCompleted = false;
    request._abort = () {
      aborted = true;
      pendingRequest?.abort(const _TranslationCancelled());
      unawaited(responseSubscription?.cancel());
    };
    try {
      final uri = _endpoint.replace(
        queryParameters: {
          'client': 'dict-chrome-ex',
          'sl': source,
          'tl': target,
        },
      );
      final pending = await request._active(
        client
            .postUrl(uri)
            .then((req) {
              if (aborted || request.cancelled || _disposed) {
                req.abort(const _TranslationCancelled());
                throw const _TranslationCancelled();
              }
              return pendingRequest = req;
            })
            .timeout(_requestTimeout),
      );
      pending.followRedirects = false;
      pending.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      pending.write(
        texts.map((text) => 'q=${Uri.encodeQueryComponent(text)}').join('&'),
      );
      final response = await request._active(
        pending.close().timeout(_requestTimeout),
      );
      final bodyBuffer = StringBuffer();
      final bodyCompleter = Completer<String>();
      responseSubscription = utf8.decoder
          .bind(response)
          .listen(
            bodyBuffer.write,
            onError: (Object error, StackTrace stack) {
              if (bodyCompleter.isCompleted) return;
              if (error is FormatException) {
                bodyCompleter.completeError(
                  const _TranslationError(
                    TextTranslationFailure.invalidResponse,
                  ),
                  stack,
                );
              } else {
                bodyCompleter.completeError(error, stack);
              }
            },
            onDone: () {
              if (!bodyCompleter.isCompleted) {
                bodyCompleter.complete(bodyBuffer.toString());
              }
            },
            cancelOnError: true,
          );
      final body = await request._active(
        bodyCompleter.future.timeout(_requestTimeout),
      );
      responseCompleted = true;
      if (request.cancelled) throw const _TranslationCancelled();
      final unusual =
          response.statusCode != HttpStatus.ok &&
          body.toLowerCase().contains('unusual traffic');
      if (unusual || response.statusCode == 429 || response.statusCode == 403) {
        final failure = unusual
            ? TextTranslationFailure.unusualTraffic
            : TextTranslationFailure.rateLimited;
        var delay = Duration(minutes: unusual ? 5 : 1);
        final retry = response.headers.value(HttpHeaders.retryAfterHeader);
        final seconds = int.tryParse(retry ?? '');
        Duration? requested;
        if (seconds != null) {
          requested = Duration(seconds: seconds);
        } else if (retry != null) {
          try {
            requested = HttpDate.parse(retry).difference(_now());
          } on FormatException {
            // Invalid Retry-After values do not shorten the minimum cooldown.
          }
        }
        if (requested != null && requested > delay) delay = requested;
        _cooldownUntil = _now().add(delay);
        _cooldownFailure = failure;
        throw _TranslationError(failure);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw const _TranslationError(TextTranslationFailure.unavailable);
      }
      return _parse(body, texts.length);
    } finally {
      aborted = true;
      _lastRequestAt = _now();
      request._abort = null;
      await responseSubscription?.cancel();
      if (!responseCompleted) {
        pendingRequest?.abort();
      }
    }
  }

  void _remember(_TranslationKey key, String value) {
    _memory.remove(key);
    _memory[key] = value;
    while (_memory.length > _memoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<JsonDocumentLocation?> _cacheLocation() => _location ??= (() async {
    try {
      final root = await _temporaryDirectory();
      final location = JsonDocumentLocation.folderChild(
        folder: path.join(root.path, textTranslationCacheDirectoryName),
        name: 'cache.json',
      );
      _cacheKey = (path: location.lockKey, store: _cacheStoreIdentity);
      if (!_disposed) _cacheUsers.add(this);
      return location;
    } on Object {
      AppLogService.warning('page_translation_cache_directory_unavailable');
      return null;
    }
  })();

  static Future<T> _serializeDisk<T>(Future<T> Function() operation) {
    final task = _diskTail.then((_) => operation());
    _diskTail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<Map<_TranslationKey, String>> _readDisk() =>
      _diskEntries ??= _loadDisk();

  Future<Map<_TranslationKey, String>> _loadDisk() async {
    try {
      final location = await _cacheLocation();
      if (location == null) return {};
      final snapshot = await _serializeDisk(() => _store.read(location));
      final bytes = snapshot.snapshot?.bytes;
      final capacity = _diskCapacity;
      return await compute(_decodeTranslationCache, (bytes, capacity));
    } on Object {
      AppLogService.warning('page_translation_cache_read_failed');
      return {};
    }
  }

  void _saveDisk(Map<_TranslationKey, String> additions) {
    for (final entry in additions.entries) {
      _pendingDiskAdditions.remove(entry.key);
      _pendingDiskAdditions[entry.key] = entry.value;
    }
    if (_diskWriteDebounce <= Duration.zero) {
      _flushDiskAdditions();
      return;
    }
    _diskSaveTimer?.cancel();
    _diskSaveTimer = Timer(_diskWriteDebounce, _flushDiskAdditions);
  }

  void _flushDiskAdditions() {
    _diskSaveTimer?.cancel();
    _diskSaveTimer = null;
    if (_pendingDiskAdditions.isEmpty) return;
    final changes = <_TranslationKey, String>{};
    for (final entry in _recentlyAccessed.entries) {
      if (_memory.containsKey(entry.key)) {
        changes[entry.key] = entry.value;
      }
    }
    _recentlyAccessed.clear();
    for (final entry in _pendingDiskAdditions.entries) {
      changes.remove(entry.key);
      changes[entry.key] = entry.value;
    }
    _pendingDiskAdditions.clear();
    final epoch = _cacheEpoch;
    unawaited(
      _serializeDisk(() async {
        try {
          if (epoch != _cacheEpoch) return;
          final location = await _cacheLocation();
          if (location == null || epoch != _cacheEpoch) return;
          final previous = await _store.read(location);
          if (previous.status == JsonDocumentReadStatus.unreadable) return;
          final snapshot = previous.snapshot;
          final previousBytes = snapshot?.bytes;
          final capacity = _diskCapacity;
          final bytes = await compute(_mergeTranslationCache, (
            previousBytes,
            changes,
            capacity,
          ));
          if (epoch != _cacheEpoch) return;
          final written = await _store.write(
            location: location,
            bytes: bytes,
            mode: snapshot == null
                ? JsonDocumentWriteMode.createIfAbsent
                : JsonDocumentWriteMode.replaceIfRevision,
            expectedRevision: snapshot?.revision,
          );
          if (!written.committed) {
            AppLogService.warning('page_translation_cache_write_failed');
          } else {
            _syncPeerCaches(changes);
          }
        } on Object {
          // Cache I/O must not discard a successfully translated batch.
          AppLogService.warning('page_translation_cache_write_failed');
        }
      }),
    );
  }

  void _syncPeerCaches(Map<_TranslationKey, String> changes) {
    for (final peer in _cacheUsers) {
      if (peer._cacheKey != _cacheKey || identical(peer, this)) continue;
      final peerDiskFuture = peer._diskEntries;
      if (peerDiskFuture != null) {
        unawaited(
          peerDiskFuture.then((entries) {
            if (peer._disposed || !identical(peer._diskEntries, peerDiskFuture)) {
              return;
            }
            for (final entry in changes.entries) {
              entries.remove(entry.key);
              entries[entry.key] = entry.value;
            }
            while (entries.length > peer._diskCapacity) {
              entries.remove(entries.keys.first);
            }
          }),
        );
      }
      for (final entry in changes.entries) {
        if (peer._memory.containsKey(entry.key)) {
          peer._remember(entry.key, entry.value);
        }
      }
    }
  }

  void _invalidatePeerCaches({bool clearing = false}) {
    for (final peer in _cacheUsers) {
      if (peer._cacheKey != _cacheKey || identical(peer, this)) continue;
      peer._diskEntries = null;
      peer._memory.clear();
      if (clearing) peer._cancelCacheRequests();
    }
  }

  void _cancelCacheRequests() {
    _cacheEpoch++;
    _diskSaveTimer?.cancel();
    _diskSaveTimer = null;
    _pendingDiskAdditions.clear();
    _recentlyAccessed.clear();
    _diskEntries = null;
    _memory.clear();
    for (final request in _requests.toList()) {
      request.cancel();
    }
  }

  Future<void> clearCache() {
    _cancelCacheRequests();
    final clearing = (() async {
      final location = await _cacheLocation();
      if (location == null) return;
      _invalidatePeerCaches(clearing: true);
      await _serializeDisk(() async {
        final snapshot = (await _store.read(location)).snapshot;
        if (snapshot != null) {
          await _store.delete(
            location: location,
            expectedRevision: snapshot.revision,
          );
        }
      });
    })();
    _operations = Future.wait([
      _operations,
      clearing,
    ]).then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return clearing;
  }

  void dispose() {
    _disposed = true;
    _flushDiskAdditions();
    for (final request in _requests.toList()) {
      request.cancel();
    }
    _httpClient?.close(force: true);
    _httpClient = null;
    _memory.clear();
    _recentlyAccessed.clear();
    _diskEntries = null;
    _cacheUsers.remove(this);
  }
}

Map<_TranslationKey, String> _decodeTranslationCache(
  (Uint8List?, int) request,
) {
  final (bytes, capacity) = request;
  final entries = <_TranslationKey, String>{};
  if (bytes == null) return entries;
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map || decoded['version'] != 2) return entries;
  final rows = decoded['entries'];
  if (rows is! List) return entries;
  for (final row in rows) {
    if (row is! List ||
        row.length != 4 ||
        !row.every((value) => value is String)) {
      continue;
    }
    final original = row[2] as String;
    final translated = row[3] as String;
    if (canTranslateText(original) && translated.trim().isNotEmpty) {
      entries[(original, row[1] as String, row[0] as String)] = translated;
    }
  }
  while (entries.length > capacity) {
    entries.remove(entries.keys.first);
  }
  return entries;
}

Uint8List _mergeTranslationCache(
  (Uint8List?, Map<_TranslationKey, String>, int) request,
) {
  final (previous, changes, capacity) = request;
  Map<_TranslationKey, String> entries;
  try {
    entries = _decodeTranslationCache((previous, capacity));
  } on FormatException {
    entries = {};
  }
  for (final entry in changes.entries) {
    entries.remove(entry.key);
    entries[entry.key] = entry.value;
  }
  while (entries.length > capacity) {
    entries.remove(entries.keys.first);
  }
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 2,
        'entries': [
          for (final entry in entries.entries)
            [entry.key.$3, entry.key.$2, entry.key.$1, entry.value],
        ],
      }),
    ),
  );
}

List<List<String>> textTranslationBatches(List<String> texts) {
  final batches = <List<String>>[];
  var current = <String>[];
  var characters = 0;
  for (final text in texts) {
    if (text.length > textTranslationBatchMaxCharacters) {
      throw ArgumentError.value(text.length, 'text.length');
    }
    if (current.isNotEmpty &&
        (current.length == textTranslationBatchMaxItems ||
            characters + text.length > textTranslationBatchMaxCharacters)) {
      batches.add(current);
      current = [];
      characters = 0;
    }
    current.add(text);
    characters += text.length;
  }
  if (current.isNotEmpty) batches.add(current);
  return batches;
}

/// Keep line boundaries and surrounding whitespace out of translation requests.
List<String> textTranslationSegments(String text) {
  final segments = <String>[];
  for (final line in RegExp(r'[^\r\n]+|[\r\n]+').allMatches(text)) {
    final value = line.group(0)!;
    var start = 0;
    while (start < value.length) {
      var end = (start + textTranslationBatchMaxCharacters).clamp(
        0,
        value.length,
      );
      if (end < value.length &&
          value.codeUnitAt(end - 1) >= 0xD800 &&
          value.codeUnitAt(end - 1) <= 0xDBFF &&
          value.codeUnitAt(end) >= 0xDC00 &&
          value.codeUnitAt(end) <= 0xDFFF) {
        end--;
      }
      final part = value.substring(start, end);
      final trimmed = part.trim();
      if (trimmed.isEmpty) {
        segments.add(part);
      } else {
        final offset = part.indexOf(trimmed);
        if (offset > 0) segments.add(part.substring(0, offset));
        segments.add(trimmed);
        if (offset + trimmed.length < part.length) {
          segments.add(part.substring(offset + trimmed.length));
        }
      }
      start = end;
    }
  }
  return segments;
}

final _fileSuffix = RegExp(
  r'\.(wav|mp3|flac|m4a|aac|ogg|opus|wma|aiff|mp4|mkv|webm|avi|mov|m4v|3gp|jpg|jpeg|png|webp|gif|bmp|txt|md|srt|vtt|lrc|ass|ssa|pdf|zip|rar|7z)$',
  caseSensitive: false,
);
final _workNumber = RegExp(r'^(RJ|BJ|VJ)\d+$', caseSensitive: false);
final _letters = RegExp(r'\p{L}', unicode: true);

({String source, String suffix}) textTranslationText(
  String text, {
  bool fileName = false,
}) {
  final suffix = fileName ? _fileSuffix.firstMatch(text)?.group(0) ?? '' : '';
  return (
    source: text.substring(0, text.length - suffix.length),
    suffix: suffix,
  );
}

bool canTranslateText(String text) =>
    text.trim().isNotEmpty &&
    text.length <= textTranslationBatchMaxCharacters &&
    _letters.hasMatch(text) &&
    !_workNumber.hasMatch(text.trim());

List<String> _parse(String body, int count) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! List || decoded.length != count) {
      throw const FormatException();
    }
    return decoded.map<String>((item) {
      if (item is List) {
        if (item.length != 2 || item[1] is! String) {
          throw const FormatException();
        }
        item = item[0];
      }
      if (item is! String || item.trim().isEmpty) throw const FormatException();
      return item;
    }).toList();
  } on FormatException {
    throw const _TranslationError(TextTranslationFailure.invalidResponse);
  }
}

class _TranslationCancelled implements Exception {
  const _TranslationCancelled();
}

class _TranslationError implements Exception {
  const _TranslationError(this.failure);
  final TextTranslationFailure failure;
}
