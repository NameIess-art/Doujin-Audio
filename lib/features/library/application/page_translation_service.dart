import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/persistence/json_document_store.dart';

const pageTranslationBatchMaxCharacters = 4000;
const pageTranslationBatchMaxItems = 50;
const pageTranslationCacheDirectoryName = 'page_translations';

enum PageTranslationFailure {
  unavailable,
  invalidResponse,
  rateLimited,
  unusualTraffic,
}

class PageTranslationRequest {
  final Completer<void> _cancellation = Completer<void>();
  void Function()? _abort;
  void Function()? _onCancel;

  bool get cancelled => _cancellation.isCompleted;

  void cancel() {
    if (cancelled) return;
    _cancellation.complete();
    _abort?.call();
    _onCancel?.call();
  }

  Future<T> _active<T>(Future<T> future) {
    if (cancelled) throw const _TranslationCancelled();
    return Future.any([
      future,
      _cancellation.future.then<T>((_) => throw const _TranslationCancelled()),
    ]);
  }
}

class PageTranslationResult {
  PageTranslationResult({
    Map<String, String> translations = const {},
    this.failure,
  }) : translations = Map.unmodifiable(translations);

  final Map<String, String> translations;
  final PageTranslationFailure? failure;
}

typedef _TranslationKey = (String, String);

class PageTranslationService {
  PageTranslationService({
    HttpClient Function()? clientFactory,
    Uri? endpoint,
    JsonDocumentStore? documentStore,
    Future<Directory> Function()? temporaryDirectory,
    DateTime Function()? now,
    Duration requestInterval = const Duration(milliseconds: 250),
    Duration requestTimeout = const Duration(seconds: 20),
    int memoryCapacity = 1000,
    int diskCapacity = 3000,
  }) : assert(memoryCapacity > 0),
       assert(diskCapacity >= memoryCapacity),
       _clientFactory = clientFactory ?? (() => HttpClient()),
       _endpoint =
           endpoint ?? Uri.https('translate.googleapis.com', '/translate_a/t'),
       _documentStore = documentStore,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _now = now ?? DateTime.now,
       _requestInterval = requestInterval,
       _requestTimeout = requestTimeout,
       _memoryCapacity = memoryCapacity,
       _diskCapacity = diskCapacity;

  final HttpClient Function() _clientFactory;
  final Uri _endpoint;
  JsonDocumentStore? _documentStore;
  final Future<Directory> Function() _temporaryDirectory;
  final DateTime Function() _now;
  final Duration _requestInterval;
  final Duration _requestTimeout;
  final int _memoryCapacity;
  final int _diskCapacity;
  final _memory = <_TranslationKey, String>{};
  final _requests = <PageTranslationRequest>{};
  Future<void> _operations = Future<void>.value();
  Future<void> _writes = Future<void>.value();
  Future<JsonDocumentLocation?>? _location;
  DateTime? _lastRequestAt;
  DateTime? _cooldownUntil;
  PageTranslationFailure? _cooldownFailure;
  bool _disposed = false;
  int _cacheEpoch = 0;

  JsonDocumentStore get _store => _documentStore ??= DefaultJsonDocumentStore();

  PageTranslationRequest newRequest() {
    final request = PageTranslationRequest();
    request._onCancel = () => _requests.remove(request);
    if (_disposed) {
      request.cancel();
    } else {
      _requests.add(request);
    }
    return request;
  }

  String? cached(String text, String target) {
    final key = (text, target);
    final value = _memory.remove(key);
    if (value != null) _memory[key] = value;
    return value;
  }

  Future<PageTranslationResult> translate(
    List<String> texts, {
    required String target,
    required PageTranslationRequest request,
  }) async {
    if (_disposed || request.cancelled) return PageTranslationResult();
    final task = _operations.then(
      (_) => _translate(texts, target: target, request: request),
    );
    // A failed caller must not poison the queue for later page requests.
    _operations = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      return await request._active(task);
    } on _TranslationCancelled {
      return PageTranslationResult();
    }
  }

  Future<PageTranslationResult> _translate(
    List<String> texts, {
    required String target,
    required PageTranslationRequest request,
  }) async {
    final result = <String, String>{};
    try {
      if (request.cancelled || _disposed) return PageTranslationResult();
      final unique = texts.where(shouldTranslatePageText).toSet();
      for (final text in unique) {
        final value = cached(text, target);
        if (value != null) result[text] = value;
      }
      if (result.length == unique.length) {
        return PageTranslationResult(translations: result);
      }
      await request._active(_writes);
      final entries = await request._active(_readDisk());
      for (final text in unique.where((text) => !result.containsKey(text))) {
        final key = (text, target);
        final value = entries.remove(key);
        if (value == null) continue;
        entries[key] = value;
        _remember(key, value);
        result[text] = value;
      }
      final missing = unique
          .where((text) => !result.containsKey(text))
          .toList();
      if (missing.isEmpty) _saveDisk(entries);
      for (final batch in pageTranslationBatches(missing)) {
        final cooldown = _cooldownUntil;
        if (cooldown != null && _now().isBefore(cooldown)) {
          return PageTranslationResult(
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
        final translated = await _fetch(batch, target, request);
        for (var index = 0; index < batch.length; index++) {
          final key = (batch[index], target);
          result[batch[index]] = translated[index];
          _remember(key, translated[index]);
          entries.remove(key);
          entries[key] = translated[index];
        }
        _saveDisk(entries);
      }
      return PageTranslationResult(translations: result);
    } on _TranslationCancelled {
      return PageTranslationResult(translations: result);
    } on _TranslationError catch (error) {
      return PageTranslationResult(
        translations: result,
        failure: error.failure,
      );
    } on IOException {
      return PageTranslationResult(
        translations: result,
        failure: PageTranslationFailure.unavailable,
      );
    } on TimeoutException {
      return PageTranslationResult(
        translations: result,
        failure: PageTranslationFailure.unavailable,
      );
    }
  }

  Future<List<String>> _fetch(
    List<String> texts,
    String target,
    PageTranslationRequest request,
  ) async {
    if (request.cancelled) throw const _TranslationCancelled();
    final client = _clientFactory();
    client.connectionTimeout = _requestTimeout;
    request._abort = () => client.close(force: true);
    try {
      final uri = _endpoint.replace(
        queryParameters: {
          'client': 'dict-chrome-ex',
          'sl': 'auto',
          'tl': target,
        },
      );
      final pending = await request._active(
        client.postUrl(uri).timeout(_requestTimeout),
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
      final body = await request._active(
        utf8.decoder
            .bind(response)
            .join()
            .timeout(_requestTimeout)
            .onError<FormatException>(
              (_, _) => throw const _TranslationError(
                PageTranslationFailure.invalidResponse,
              ),
            ),
      );
      if (request.cancelled) throw const _TranslationCancelled();
      final unusual =
          response.statusCode != HttpStatus.ok &&
          body.toLowerCase().contains('unusual traffic');
      if (unusual || response.statusCode == 429 || response.statusCode == 403) {
        final failure = unusual
            ? PageTranslationFailure.unusualTraffic
            : PageTranslationFailure.rateLimited;
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
        throw const _TranslationError(PageTranslationFailure.unavailable);
      }
      return _parse(body, texts.length);
    } finally {
      _lastRequestAt = _now();
      request._abort = null;
      client.close(force: true);
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
      return JsonDocumentLocation.folderChild(
        folder: path.join(root.path, pageTranslationCacheDirectoryName),
        name: 'cache.json',
      );
    } on Object {
      AppLogService.warning('page_translation_cache_directory_unavailable');
      return null;
    }
  })();

  Future<Map<_TranslationKey, String>> _readDisk() async {
    final entries = <_TranslationKey, String>{};
    try {
      final location = await _cacheLocation();
      if (location == null) return entries;
      final snapshot = (await _store.read(location)).snapshot;
      if (snapshot == null) return entries;
      final decoded = jsonDecode(snapshot.text);
      if (decoded is! Map || decoded['version'] != 1) return entries;
      final rows = decoded['entries'];
      if (rows is! List) return entries;
      for (final row in rows) {
        if (row is List &&
            row.length == 3 &&
            row.every((value) => value is String)) {
          final source = row[1] as String;
          final translated = row[2] as String;
          if (!shouldTranslatePageText(source) || translated.trim().isEmpty) {
            continue;
          }
          entries[(source, row[0] as String)] = translated;
        }
      }
      while (entries.length > _diskCapacity) {
        entries.remove(entries.keys.first);
      }
    } on Object {
      AppLogService.warning('page_translation_cache_read_failed');
    }
    return entries;
  }

  void _saveDisk(Map<_TranslationKey, String> entries) {
    for (final entry in _memory.entries) {
      entries.remove(entry.key);
      entries[entry.key] = entry.value;
    }
    while (entries.length > _diskCapacity) {
      entries.remove(entries.keys.first);
    }
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'entries': [
            for (final entry in entries.entries)
              [entry.key.$2, entry.key.$1, entry.value],
          ],
        }),
      ),
    );
    final epoch = _cacheEpoch;
    _writes = _writes.then((_) async {
      try {
        if (epoch != _cacheEpoch) return;
        final location = await _cacheLocation();
        if (location == null || epoch != _cacheEpoch) return;
        final previous = await _store.read(location);
        if (previous.status == JsonDocumentReadStatus.unreadable) return;
        final snapshot = previous.snapshot;
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
        }
      } on Object {
        // Cache I/O must not discard a successfully translated batch.
        AppLogService.warning('page_translation_cache_write_failed');
      }
    });
  }

  Future<void> clearCache() {
    _cacheEpoch++;
    for (final request in _requests.toList()) {
      request.cancel();
    }
    _memory.clear();
    final clearing = _operations.then((_) async {
      _memory.clear();
      await _writes;
      final location = await _cacheLocation();
      if (location == null) return;
      final snapshot = (await _store.read(location)).snapshot;
      if (snapshot != null) {
        await _store.delete(
          location: location,
          expectedRevision: snapshot.revision,
        );
      }
    });
    _operations = clearing.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return clearing;
  }

  void dispose() {
    _disposed = true;
    for (final request in _requests.toList()) {
      request.cancel();
    }
    _memory.clear();
  }
}

List<List<String>> pageTranslationBatches(List<String> texts) {
  final batches = <List<String>>[];
  var current = <String>[];
  var characters = 0;
  for (final text in texts) {
    if (text.length > pageTranslationBatchMaxCharacters) {
      throw ArgumentError.value(text.length, 'text.length');
    }
    if (current.isNotEmpty &&
        (current.length == pageTranslationBatchMaxItems ||
            characters + text.length > pageTranslationBatchMaxCharacters)) {
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
List<String> pageTranslationSegments(String text) {
  final segments = <String>[];
  for (final line in RegExp(r'[^\r\n]+|[\r\n]+').allMatches(text)) {
    final value = line.group(0)!;
    var start = 0;
    while (start < value.length) {
      var end = (start + pageTranslationBatchMaxCharacters).clamp(
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

({String source, String suffix}) pageTranslationText(
  String text, {
  bool fileName = false,
}) {
  final suffix = fileName ? _fileSuffix.firstMatch(text)?.group(0) ?? '' : '';
  return (
    source: text.substring(0, text.length - suffix.length),
    suffix: suffix,
  );
}

bool shouldTranslatePageText(String text) =>
    text.trim().isNotEmpty &&
    text.length <= pageTranslationBatchMaxCharacters &&
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
    throw const _TranslationError(PageTranslationFailure.invalidResponse);
  }
}

class _TranslationCancelled implements Exception {
  const _TranslationCancelled();
}

class _TranslationError implements Exception {
  const _TranslationError(this.failure);
  final PageTranslationFailure failure;
}
