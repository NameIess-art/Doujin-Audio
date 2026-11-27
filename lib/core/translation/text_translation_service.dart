import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, compute;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../logging/app_log_service.dart';
import '../persistence/json_document_store.dart';
import 'translation_service_settings.dart';

export 'translation_service_settings.dart';

const textTranslationBatchMaxCharacters = 4000;
const textTranslationBatchMaxItems = 50;
const textTranslationLlmBatchMaxCharacters = 1800;
const textTranslationLlmBatchMaxItems = 20;
const textTranslationCacheDirectoryName = 'page_translations';

enum TextTranslationFailure {
  unavailable,
  invalidResponse,
  rateLimited,
  unusualTraffic,
  unauthorized,
  misconfigured,
}

class CustomTranslationTestOutcome {
  const CustomTranslationTestOutcome({
    this.sampleTranslation,
    this.elapsedMilliseconds,
    this.failure,
  });

  final String? sampleTranslation;
  final int? elapsedMilliseconds;
  final TextTranslationFailure? failure;

  bool get isSuccess => failure == null && sampleTranslation != null;
}

class TextTranslationRequest {
  ({TranslationServiceSettings settings, String? apiKey})? _configuration;
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

typedef _TranslationKey = (String, String, String, String);

class TextTranslationService {
  TextTranslationService({
    HttpClient Function()? clientFactory,
    Uri? endpoint,
    JsonDocumentStore? documentStore,
    Future<Directory> Function()? temporaryDirectory,
    DateTime Function()? now,
    Duration requestInterval = const Duration(milliseconds: 250),
    Duration requestTimeout = const Duration(seconds: 20),
    Duration llmRequestTimeout = const Duration(seconds: 90),
    Duration diskWriteDebounce = const Duration(milliseconds: 500),
    int memoryCapacity = 1000,
    int diskCapacity = 3000,
    TranslationServiceSettings initialSettings =
        const TranslationServiceSettings(),
    String? initialApiKey,
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
       _llmRequestTimeout = llmRequestTimeout,
       _diskWriteDebounce = diskWriteDebounce,
       _memoryCapacity = memoryCapacity,
       _diskCapacity = diskCapacity,
       _settings = initialSettings,
       _apiKey = _normalizeSecret(initialApiKey);

  final HttpClient Function() _clientFactory;
  final Uri _endpoint;
  JsonDocumentStore? _documentStore;
  final JsonDocumentStore? _cacheStoreIdentity;
  final Future<Directory> Function() _temporaryDirectory;
  final DateTime Function() _now;
  final Duration _requestInterval;
  final Duration _requestTimeout;
  final Duration _llmRequestTimeout;
  final Duration _diskWriteDebounce;
  final int _memoryCapacity;
  final int _diskCapacity;
  TranslationServiceSettings _settings;
  String? _apiKey;
  final ValueNotifier<int> _configurationRevision = ValueNotifier<int>(0);
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
  DateTime? _llmCooldownUntil;
  TextTranslationFailure? _llmCooldownFailure;
  bool _disposed = false;
  int _cacheEpoch = 0;

  static String? _normalizeSecret(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  JsonDocumentStore get _store => _documentStore ??= DefaultJsonDocumentStore();

  ValueListenable<int> get configurationRevision => _configurationRevision;

  TranslationServiceSettings get settings => _settings;

  bool usesCustomBackendFor(TextTranslationScene scene) =>
      _settings.usesCustomFor(scene);

  String backendSignatureFor(TextTranslationScene scene) =>
      _settings.backendSignatureFor(scene);

  void configure(TranslationServiceSettings settings, [String? apiKey]) {
    final normalizedKey = _normalizeSecret(apiKey);
    if (_settings == settings && _apiKey == normalizedKey) return;
    _settings = settings;
    _apiKey = normalizedKey;
    _llmCooldownUntil = null;
    _llmCooldownFailure = null;
    if (!_disposed) {
      _configurationRevision.value++;
    }
  }

  TextTranslationRequest newRequest({bool pinConfiguration = false}) {
    final request = TextTranslationRequest();
    if (pinConfiguration) {
      request._configuration = (settings: _settings, apiKey: _apiKey);
    }
    request._onCancel = () => _requests.remove(request);
    if (_disposed) {
      request.cancel();
    } else {
      _requests.add(request);
    }
    return request;
  }

  String? cached(String text, String target, {String source = 'auto'}) =>
      _cachedInternal(text, target, source: source, scene: TextTranslationScene.browse);

  String? cachedInScene(
    String text,
    String target, {
    String source = 'auto',
    TextTranslationScene scene = TextTranslationScene.browse,
  }) {
    if (runtimeType != TextTranslationService) {
      return cached(text, target, source: source);
    }
    return _cachedInternal(text, target, source: source, scene: scene);
  }

  String? _cachedInternal(
    String text,
    String target, {
    required String source,
    required TextTranslationScene scene,
    String? backend,
  }) {
    final key = (backend ?? backendSignatureFor(scene), text, source, target);
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
  }) => _enqueueTranslate(
    texts,
    target: target,
    source: source,
    scene: TextTranslationScene.browse,
    contextBefore: const <String>[],
    request: request,
  );

  Future<TextTranslationResult> translateInScene(
    List<String> texts, {
    required String target,
    required TextTranslationRequest request,
    String source = 'auto',
    TextTranslationScene scene = TextTranslationScene.browse,
    List<String> contextBefore = const <String>[],
  }) {
    if (runtimeType != TextTranslationService) {
      return translate(texts, target: target, source: source, request: request);
    }
    return _enqueueTranslate(
      texts,
      target: target,
      source: source,
      scene: scene,
      contextBefore: contextBefore,
      request: request,
    );
  }

  Future<TextTranslationResult> _enqueueTranslate(
    List<String> texts, {
    required String target,
    required String source,
    required TextTranslationScene scene,
    required List<String> contextBefore,
    required TextTranslationRequest request,
  }) async {
    if (_disposed || request.cancelled) return TextTranslationResult();
    final task = _operations.then(
      (_) => _translate(
        texts,
        target: target,
        source: source,
        scene: scene,
        contextBefore: contextBefore,
        request: request,
      ),
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
    required TextTranslationScene scene,
    required List<String> contextBefore,
    required TextTranslationRequest request,
  }) async {
    final result = <String, String>{};
    final additions = <_TranslationKey, String>{};
    final epoch = _cacheEpoch;
    final configuration =
        request._configuration ?? (settings: _settings, apiKey: _apiKey);
    final activeSettings = configuration.settings;
    final activeApiKey = configuration.apiKey;
    final useCustom = activeSettings.usesCustomFor(scene);
    final backend = activeSettings.backendSignatureFor(scene);
    try {
      if (request.cancelled || _disposed) return TextTranslationResult();
      if (useCustom && !activeSettings.isCustomReady) {
        return TextTranslationResult(
          failure: TextTranslationFailure.misconfigured,
        );
      }
      final unique = texts.where(canTranslateText).toSet();
      for (final text in unique) {
        final value = _cachedInternal(
          text,
          target,
          source: source,
          scene: scene,
          backend: backend,
        );
        if (value != null) result[text] = value;
      }
      if (result.length == unique.length) {
        return TextTranslationResult(translations: result);
      }
      final entries = await request._active(_readDisk());
      for (final text in unique.where((text) => !result.containsKey(text))) {
        final key = (backend, text, source, target);
        final value = entries.remove(key);
        if (value == null) continue;
        entries[key] = value;
        _remember(key, value);
        result[text] = value;
      }
      final missing = unique
          .where((text) => !result.containsKey(text))
          .toList();
      final batches = useCustom
          ? textTranslationBatches(
              missing,
              maxItems: textTranslationLlmBatchMaxItems,
              maxCharacters: textTranslationLlmBatchMaxCharacters,
            )
          : textTranslationBatches(missing);
      var rollingContext = contextBefore
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (rollingContext.length > 4) {
        rollingContext = rollingContext.sublist(rollingContext.length - 4);
      }
      for (final batch in batches) {
        final currentConfiguration =
            activeSettings == _settings && activeApiKey == _apiKey;
        final cooldown = useCustom
            ? (currentConfiguration ? _llmCooldownUntil : null)
            : _cooldownUntil;
        final cooldownFailure = useCustom
            ? _llmCooldownFailure
            : _cooldownFailure;
        if (cooldown != null && _now().isBefore(cooldown)) {
          return TextTranslationResult(
            translations: result,
            failure: cooldownFailure,
          );
        }
        final last = _lastRequestAt;
        if (last != null) {
          final delay = _requestInterval - _now().difference(last);
          if (delay > Duration.zero) {
            await request._active(Future<void>.delayed(delay));
          }
        }
        final translated = useCustom
            ? await _fetchOpenAiCompatible(
                batch,
                source,
                target,
                request,
                contextBefore: rollingContext,
                settings: activeSettings,
                apiKey: activeApiKey,
              )
            : await _fetchGoogle(batch, source, target, request);
        for (var index = 0; index < batch.length; index++) {
          final key = (backend, batch[index], source, target);
          result[batch[index]] = translated[index];
          _remember(key, translated[index]);
          entries.remove(key);
          entries[key] = translated[index];
          additions[key] = translated[index];
        }
        if (useCustom) {
          rollingContext = [
            ...rollingContext,
            ...batch.map((line) => line.trim()).where((line) => line.isNotEmpty),
          ];
          if (rollingContext.length > 4) {
            rollingContext = rollingContext.sublist(rollingContext.length - 4);
          }
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

  Future<List<String>> fetchAvailableModels({
    required String apiBaseUrl,
    String? apiKey,
    bool useSavedApiKeyIfEmpty = false,
  }) async {
    if (_disposed) return const <String>[];
    final modelsUri = TranslationServiceSettings.resolveModelsUri(apiBaseUrl);
    if (modelsUri == null) {
      throw TextTranslationFailure.misconfigured;
    }
    final normalizedKey =
        _normalizeSecret(apiKey) ?? (useSavedApiKeyIfEmpty ? _apiKey : null);
    try {
      final (status, body) = await _getJson(
        modelsUri,
        apiKey: normalizedKey,
        timeout: _requestTimeout,
      );
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        throw TextTranslationFailure.unauthorized;
      }
      if (status == HttpStatus.ok) {
        final parsed = _parseModelList(body);
        if (parsed.isNotEmpty) return parsed;
      }
      if (status == HttpStatus.notFound) {
        final tagsUri = TranslationServiceSettings.resolveOllamaTagsUri(
          apiBaseUrl,
        );
        if (tagsUri != null && tagsUri != modelsUri) {
          final (ollamaStatus, ollamaBody) = await _getJson(
            tagsUri,
            apiKey: normalizedKey,
            timeout: _requestTimeout,
          );
          if (ollamaStatus == HttpStatus.ok) {
            return _parseModelList(ollamaBody);
          }
        }
      }
      throw TextTranslationFailure.unavailable;
    } on TextTranslationFailure {
      rethrow;
    } on FormatException {
      throw TextTranslationFailure.invalidResponse;
    } on IOException {
      throw TextTranslationFailure.unavailable;
    } on TimeoutException {
      throw TextTranslationFailure.unavailable;
    }
  }

  Future<CustomTranslationTestOutcome> testCustomConfiguration({
    required TranslationServiceSettings settings,
    String? apiKey,
    bool useSavedApiKeyIfEmpty = false,
    String target = 'zh-CN',
  }) async {
    if (_disposed) {
      return const CustomTranslationTestOutcome(
        failure: TextTranslationFailure.unavailable,
      );
    }
    final candidate = settings.copyWith(
      provider: TranslationProviderKind.openAiCompatible,
    );
    if (!candidate.isCustomReady) {
      return const CustomTranslationTestOutcome(
        failure: TextTranslationFailure.misconfigured,
      );
    }
    final resolvedKey =
        _normalizeSecret(apiKey) ?? (useSavedApiKeyIfEmpty ? _apiKey : null);
    final request = newRequest();
    final stopwatch = Stopwatch()..start();
    try {
      final translated = await _fetchOpenAiCompatible(
        const <String>['お疲れ様でした。今日もゆっくり休んでね。'],
        'ja',
        target,
        request,
        contextBefore: const <String>[],
        settings: candidate,
        apiKey: resolvedKey,
        recordCooldown: false,
      );
      stopwatch.stop();
      return CustomTranslationTestOutcome(
        sampleTranslation: translated.single,
        elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      );
    } on _TranslationError catch (error) {
      return CustomTranslationTestOutcome(failure: error.failure);
    } on IOException {
      return const CustomTranslationTestOutcome(
        failure: TextTranslationFailure.unavailable,
      );
    } on TimeoutException {
      return const CustomTranslationTestOutcome(
        failure: TextTranslationFailure.unavailable,
      );
    } finally {
      request.cancel();
    }
  }

  Future<(int, String)> _getJson(
    Uri uri, {
    required String? apiKey,
    required Duration timeout,
  }) async {
    final client = _ensureClient();
    HttpClientRequest? pendingRequest;
    try {
      pendingRequest = await client.getUrl(uri).timeout(timeout);
      pendingRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) {
        pendingRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $apiKey',
        );
      }
      final response = await pendingRequest.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      return (response.statusCode, body);
    } finally {
      pendingRequest?.abort();
    }
  }

  HttpClient _ensureClient() {
    final existing = _httpClient;
    if (existing != null) return existing;
    final client = _clientFactory();
    client.connectionTimeout = _requestTimeout;
    return _httpClient = client;
  }

  Future<List<String>> _fetchGoogle(
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
      final body = await _readResponseBody(
        response,
        request: request,
        timeout: _requestTimeout,
        onSubscription: (sub) => responseSubscription = sub,
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
        final delay = _resolveCooldownDelay(
          response,
          minimum: Duration(minutes: unusual ? 5 : 1),
        );
        _cooldownUntil = _now().add(delay);
        _cooldownFailure = failure;
        throw _TranslationError(failure);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw const _TranslationError(TextTranslationFailure.unavailable);
      }
      return _parseGoogle(body, texts.length);
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

  Future<List<String>> _fetchOpenAiCompatible(
    List<String> texts,
    String source,
    String target,
    TextTranslationRequest request, {
    required List<String> contextBefore,
    required TranslationServiceSettings settings,
    required String? apiKey,
    bool recordCooldown = true,
  }) async {
    if (request.cancelled || _disposed) throw const _TranslationCancelled();
    final uri = TranslationServiceSettings.resolveChatCompletionsUri(
      settings.apiBaseUrl,
    );
    final modelName = settings.model.trim();
    if (uri == null || modelName.isEmpty) {
      throw const _TranslationError(TextTranslationFailure.misconfigured);
    }
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
      pending.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      pending.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) {
        pending.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $apiKey',
        );
      }
      final targetLabel = _languageLabel(target);
      final sourceLabel = source == 'auto'
          ? 'auto-detected source language'
          : _languageLabel(source);
      final systemPrompt =
          '${settings.effectivePrompt}\n\n'
          'Strict output protocol:\n'
          '- Source language: $sourceLabel\n'
          '- Target language: $targetLabel\n'
          '- Input is a JSON object with "items" (mapping string indices "0".."${texts.length - 1}" to source texts) '
          'and optional "context" (preceding lines for reference only; do NOT include "context" in output).\n'
          '- Output ONLY a valid JSON object with the exact same keys "0".."${texts.length - 1}" '
          'mapped to their translated strings in $targetLabel. Never merge, split, omit, or add keys.';
      final userPayload = <String, Object>{
        if (contextBefore.isNotEmpty) 'context': contextBefore,
        'items': <String, String>{
          for (var i = 0; i < texts.length; i++) '$i': texts[i],
        },
      };
      pending.add(
        utf8.encode(
          jsonEncode(<String, Object>{
            'model': modelName,
            'temperature': 0.3,
            'stream': false,
            'messages': <Map<String, String>>[
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': jsonEncode(userPayload)},
            ],
          }),
        ),
      );
      final response = await request._active(
        pending.close().timeout(_llmRequestTimeout),
      );
      final body = await _readResponseBody(
        response,
        request: request,
        timeout: _llmRequestTimeout,
        onSubscription: (sub) => responseSubscription = sub,
      );
      responseCompleted = true;
      if (request.cancelled) throw const _TranslationCancelled();
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        throw const _TranslationError(TextTranslationFailure.unauthorized);
      }
      if (response.statusCode == HttpStatus.tooManyRequests) {
        if (recordCooldown && settings == _settings && apiKey == _apiKey) {
          final delay = _resolveCooldownDelay(
            response,
            minimum: const Duration(seconds: 15),
          );
          _llmCooldownUntil = _now().add(delay);
          _llmCooldownFailure = TextTranslationFailure.rateLimited;
        }
        throw const _TranslationError(TextTranslationFailure.rateLimited);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw const _TranslationError(TextTranslationFailure.unavailable);
      }
      return _parseOpenAiTranslations(body, texts.length);
    } finally {
      aborted = true;
      if (recordCooldown) {
        _lastRequestAt = _now();
      }
      request._abort = null;
      await responseSubscription?.cancel();
      if (!responseCompleted) {
        pendingRequest?.abort();
      }
    }
  }

  Future<String> _readResponseBody(
    HttpClientResponse response, {
    required TextTranslationRequest request,
    required Duration timeout,
    required void Function(StreamSubscription<String>) onSubscription,
  }) async {
    final bodyBuffer = StringBuffer();
    final bodyCompleter = Completer<String>();
    final subscription = utf8.decoder
        .bind(response)
        .listen(
          bodyBuffer.write,
          onError: (Object error, StackTrace stack) {
            if (bodyCompleter.isCompleted) return;
            if (error is FormatException) {
              bodyCompleter.completeError(
                const _TranslationError(TextTranslationFailure.invalidResponse),
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
    onSubscription(subscription);
    try {
      return await request._active(bodyCompleter.future.timeout(timeout));
    } finally {
      await subscription.cancel();
    }
  }

  Duration _resolveCooldownDelay(
    HttpClientResponse response, {
    required Duration minimum,
  }) {
    var delay = minimum;
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
    return delay;
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
            if (peer._disposed ||
                !identical(peer._diskEntries, peerDiskFuture)) {
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
    if (_disposed) return;
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
    _configurationRevision.dispose();
  }
}

String _languageLabel(String code) => switch (code) {
  'zh' || 'zh-CN' => 'Simplified Chinese (简体中文)',
  'zh-TW' || 'zh-HK' => 'Traditional Chinese (繁體中文)',
  'en' => 'English',
  'ja' => 'Japanese (日本語)',
  _ => code,
};

List<String> _parseModelList(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw const FormatException('Invalid models payload');
  final seen = <String>{};
  final models = <String>[];
  final data = decoded['data'] ?? decoded['models'];
  if (data is! List) return models;
  for (final item in data) {
    if (item is Map) {
      final raw = (item['id'] ?? item['name'])?.toString().trim() ?? '';
      if (raw.isNotEmpty && seen.add(raw)) {
        models.add(raw);
      }
    } else if (item is String && item.trim().isNotEmpty) {
      final raw = item.trim();
      if (seen.add(raw)) models.add(raw);
    }
  }
  return models;
}

final RegExp _thinkingBlockPattern = RegExp(
  r'<think>[\s\S]*?(?:</think>|$)',
  caseSensitive: false,
);
final RegExp _codeFencePattern = RegExp(
  r'^```(?:json)?\s*([\s\S]*?)\s*```$',
  caseSensitive: false,
);

List<String> _parseOpenAiTranslations(String body, int count) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException();
    final choices = decoded['choices'];
    String? rawContent;
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map) {
          final content = message['content'];
          if (content is String) {
            rawContent = content;
          } else if (content is List) {
            rawContent = content
                .whereType<Map<Object?, Object?>>()
                .map((part) => part['text']?.toString() ?? '')
                .join();
          }
        }
      }
    }
    if (rawContent == null || rawContent.trim().isEmpty) {
      throw const FormatException();
    }
    var cleaned = rawContent.replaceAll(_thinkingBlockPattern, '').trim();
    final fenced = _codeFencePattern.firstMatch(cleaned);
    if (fenced != null) {
      cleaned = fenced.group(1)!.trim();
    }
    final openBrace = cleaned.indexOf('{');
    final closeBrace = cleaned.lastIndexOf('}');
    if (openBrace < 0 || closeBrace <= openBrace) {
      throw const FormatException();
    }
    var parsed = jsonDecode(cleaned.substring(openBrace, closeBrace + 1));
    if (parsed is! Map) throw const FormatException();
    if (parsed['items'] is Map && !parsed.containsKey('0')) {
      parsed = parsed['items'] as Map;
    }
    final results = <String>[];
    for (var i = 0; i < count; i++) {
      final value = parsed['$i'];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException();
      }
      results.add(value.trim());
    }
    return results;
  } on FormatException {
    throw const _TranslationError(TextTranslationFailure.invalidResponse);
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
        (row.length != 4 && row.length != 5) ||
        !row.every((value) => value is String)) {
      continue;
    }
    final original = row[2] as String;
    final translated = row[3] as String;
    final backend = row.length == 5 ? row[4] as String : 'google';
    if (backend.isNotEmpty &&
        canTranslateText(original) &&
        translated.trim().isNotEmpty) {
      entries[(backend, original, row[1] as String, row[0] as String)] =
          translated;
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
            if (entry.key.$1 == 'google')
              [entry.key.$4, entry.key.$3, entry.key.$2, entry.value]
            else
              [
                entry.key.$4,
                entry.key.$3,
                entry.key.$2,
                entry.value,
                entry.key.$1,
              ],
        ],
      }),
    ),
  );
}

List<List<String>> textTranslationBatches(
  List<String> texts, {
  int maxItems = textTranslationBatchMaxItems,
  int maxCharacters = textTranslationBatchMaxCharacters,
}) {
  final batches = <List<String>>[];
  var current = <String>[];
  var characters = 0;
  for (final text in texts) {
    if (text.length > textTranslationBatchMaxCharacters) {
      throw ArgumentError.value(text.length, 'text.length');
    }
    if (current.isNotEmpty &&
        (current.length == maxItems ||
            characters + text.length > maxCharacters)) {
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

List<String> _parseGoogle(String body, int count) {
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
