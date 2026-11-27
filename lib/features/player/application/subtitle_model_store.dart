import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/platform/file_cache_platform_gateway.dart';

class SubtitleModelSpec {
  const SubtitleModelSpec(this.name, this.url, this.bytes, this.sha256);

  final String name;
  final String url;
  final int bytes;
  final String sha256;
}

enum SubtitleAsrBackend { whisperWithVad, qwen3WithVad }

class SubtitleAsrModelOption {
  const SubtitleAsrModelOption({
    required this.id,
    required this.titleKey,
    this.descriptionKey,
    required this.backend,
    required this.primaryModel,
    this.vadModel,
    this.supportedLanguages = const <String>['ja'],
  });

  final String id;
  final String titleKey;
  final String? descriptionKey;
  final SubtitleAsrBackend backend;
  final SubtitleModelSpec primaryModel;
  final SubtitleModelSpec? vadModel;
  final List<String> supportedLanguages;

  List<SubtitleModelSpec> get bundleSpecs => <SubtitleModelSpec>[
    ?vadModel,
    primaryModel,
  ];

  int get totalBytes =>
      bundleSpecs.fold<int>(0, (sum, spec) => sum + spec.bytes);

  String get checkpointSignature =>
      bundleSpecs.map((spec) => spec.sha256).join(':');
}

class SubtitleModelStatus {
  const SubtitleModelStatus({
    required this.ready,
    required this.bytes,
    required this.availableBytes,
  });

  final bool ready;
  final int bytes;
  final int? availableBytes;
}

class SubtitleModelDownloadSnapshot {
  const SubtitleModelDownloadSnapshot({
    required this.received,
    required this.total,
    required this.active,
    this.error,
  });

  final int received;
  final int total;
  final bool active;
  final Object? error;

  double get fraction => (received / total).clamp(0.0, 1.0);
}

class SubtitleModelStore extends ChangeNotifier {
  SubtitleModelStore({
    FileCachePlatformGateway? storage,
    Future<Directory> Function()? directoryResolver,
    HttpClient Function()? clientFactory,
    Duration connectionTimeout = const Duration(seconds: 30),
    Duration responseTimeout = const Duration(seconds: 30),
    Duration idleTimeout = const Duration(seconds: 30),
  }) : _storage = storage ?? FileCachePlatformGateway.instance,
       _directoryResolver = directoryResolver ?? _defaultDirectory,
       _clientFactory = clientFactory ?? HttpClient.new,
       _connectionTimeout = connectionTimeout,
       _responseTimeout = responseTimeout,
       _idleTimeout = idleTimeout;

  static const japaneseCtc = SubtitleModelSpec(
    'wav2vec2-large-xlsr-53-japanese-q8_0.gguf',
    'https://huggingface.co/cstr/wav2vec2-large-xlsr-53-japanese-GGUF/resolve/16c3b21fe7858426806f4bf795578497e0b5dad2/wav2vec2-large-xlsr-53-japanese-q8_0.gguf',
    382763008,
    '12ebea2f51f2376a271f4115772c750000c1e3c2835f8c4021479fa1ee7b0a77',
  );

  static const japaneseAsrVad = SubtitleModelSpec(
    'whisper-vad-asmr-q4_k.gguf',
    'https://huggingface.co/cstr/whisper-vad-encdec-asmr-GGUF/resolve/f7f32c7d5d1730830c7bb3b6521a185561e82357/whisper-vad-asmr-q4_k.gguf',
    25418080,
    'b5b984de4e390158f33f307104635423409c2638ab07977caf836b05671c455d',
  );

  static const japaneseAsr = SubtitleModelSpec(
    'ggml-kotoba-whisper-v2.0-q5_0.bin',
    'https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/e3a0cf6a62b95911703cfb97d819292e058f12c3/ggml-kotoba-whisper-v2.0-q5_0.bin',
    537819875,
    '4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658',
  );

  static const whisperLargeV3TurboQ8 = SubtitleModelSpec(
    'ggml-large-v3-turbo-q8_0.bin',
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q8_0.bin',
    874188075,
    '317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1',
  );

  static const whisperLargeV3Q5 = SubtitleModelSpec(
    'ggml-large-v3-q5_0.bin',
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin',
    1081140203,
    'd75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1',
  );

  static const kotobaWhisperFp16 = SubtitleModelSpec(
    'ggml-kotoba-whisper-v2.0.bin',
    'https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/e3a0cf6a62b95911703cfb97d819292e058f12c3/ggml-kotoba-whisper-v2.0.bin',
    1519521155,
    'eff70a8a236e731abba774ba71e1f6d0fce53302137208c32207e694e0bf4546',
  );

  static const qwen3AsrJaAnimeQ4K = SubtitleModelSpec(
    'qwen3-asr-1.7b-ja-anime-q4_k.gguf',
    'https://huggingface.co/cstr/qwen3-asr-1.7b-ja-anime-GGUF/resolve/1906c1f812b598d5e9dae091c79656d73b41ec28/qwen3-asr-1.7b-ja-anime-q4_k.gguf',
    1490917376,
    'da00cec556885a60d47234b4def0dbdd08394df4d4df13866d7cd9726c23ccd9',
  );

  static const List<SubtitleModelSpec> japaneseAsrBundle = <SubtitleModelSpec>[
    japaneseAsrVad,
    japaneseAsr,
  ];

  static const defaultAsrModelId = 'kotoba-whisper-v2.0-ja';

  static const kotobaWhisperJa = SubtitleAsrModelOption(
    id: defaultAsrModelId,
    titleKey: 'asr_model_kotoba_whisper_v2',
    descriptionKey: 'asr_model_kotoba_whisper_v2_desc',
    backend: SubtitleAsrBackend.whisperWithVad,
    primaryModel: japaneseAsr,
    vadModel: japaneseAsrVad,
  );

  static const whisperLargeV3TurboJa = SubtitleAsrModelOption(
    id: 'whisper-large-v3-turbo-q8_0',
    titleKey: 'asr_model_whisper_large_v3_turbo_q8',
    descriptionKey: 'asr_model_whisper_large_v3_turbo_q8_desc',
    backend: SubtitleAsrBackend.whisperWithVad,
    primaryModel: whisperLargeV3TurboQ8,
    vadModel: japaneseAsrVad,
    supportedLanguages: <String>['ja', 'zh', 'en'],
  );

  static const whisperLargeV3Ja = SubtitleAsrModelOption(
    id: 'whisper-large-v3-q5_0',
    titleKey: 'asr_model_whisper_large_v3_q5',
    descriptionKey: 'asr_model_whisper_large_v3_q5_desc',
    backend: SubtitleAsrBackend.whisperWithVad,
    primaryModel: whisperLargeV3Q5,
    vadModel: japaneseAsrVad,
    supportedLanguages: <String>['ja', 'zh', 'en'],
  );

  static const kotobaWhisperFp16Ja = SubtitleAsrModelOption(
    id: 'kotoba-whisper-v2.0-fp16',
    titleKey: 'asr_model_kotoba_whisper_v2_fp16',
    descriptionKey: 'asr_model_kotoba_whisper_v2_fp16_desc',
    backend: SubtitleAsrBackend.whisperWithVad,
    primaryModel: kotobaWhisperFp16,
    vadModel: japaneseAsrVad,
  );

  static const qwen3JaAnime = SubtitleAsrModelOption(
    id: 'qwen3-asr-1.7b-ja-anime-q4_k',
    titleKey: 'asr_model_qwen3_ja_anime_q4_k',
    descriptionKey: 'asr_model_qwen3_ja_anime_q4_k_desc',
    backend: SubtitleAsrBackend.qwen3WithVad,
    primaryModel: qwen3AsrJaAnimeQ4K,
    vadModel: japaneseAsrVad,
    supportedLanguages: <String>['ja', 'zh', 'en'],
  );

  static const List<SubtitleAsrModelOption> builtInAsrModels =
      <SubtitleAsrModelOption>[
        kotobaWhisperJa,
        whisperLargeV3TurboJa,
        whisperLargeV3Ja,
        kotobaWhisperFp16Ja,
        qwen3JaAnime,
      ];

  static SubtitleAsrModelOption resolveAsrModel(String? id) {
    if (id != null && id.isNotEmpty) {
      for (final model in builtInAsrModels) {
        if (model.id == id) return model;
      }
    }
    return kotobaWhisperJa;
  }

  final FileCachePlatformGateway _storage;
  final Future<Directory> Function() _directoryResolver;
  final HttpClient Function() _clientFactory;
  final Duration _connectionTimeout;
  final Duration _responseTimeout;
  final Duration _idleTimeout;
  final Map<String, _ActiveModelDownload> _activeDownloads = {};
  final Map<String, SubtitleModelDownloadSnapshot> _snapshots = {};
  final Map<String, int> _modelRevisions = {};
  int _modelRevision = 0;
  final Map<String, ({DateTime modified, DateTime changed, String sha256})>
  _verifiedFiles = {};
  final _pendingVerification =
      <
        ({String filePath, DateTime modified, DateTime changed, String sha256}),
        Future<bool>
      >{};

  int bundleRevision(List<SubtitleModelSpec> specs) {
    var revision = 0;
    for (final spec in specs) {
      final itemRevision = _modelRevisions[spec.name] ?? 0;
      if (itemRevision > revision) revision = itemRevision;
    }
    return revision;
  }

  SubtitleModelDownloadSnapshot snapshot(SubtitleModelSpec spec) =>
      _snapshots[spec.name] ??
      SubtitleModelDownloadSnapshot(
        received: 0,
        total: spec.bytes,
        active: false,
      );

  SubtitleModelDownloadSnapshot bundleSnapshot(List<SubtitleModelSpec> specs) {
    if (specs.isEmpty) {
      return const SubtitleModelDownloadSnapshot(
        received: 0,
        total: 1,
        active: false,
      );
    }
    if (specs.length == 1) return snapshot(specs.single);
    var received = 0;
    var total = 0;
    var active = false;
    Object? error;
    for (final spec in specs) {
      final item = snapshot(spec);
      received += item.received.clamp(0, item.total);
      total += item.total;
      active = active || item.active;
      error ??= item.error;
    }
    return SubtitleModelDownloadSnapshot(
      received: received,
      total: total,
      active: active,
      error: error,
    );
  }

  void cancelDownload(SubtitleModelSpec spec) {
    final active = _activeDownloads[spec.name];
    if (active == null) return;
    active.hasUncancellableCaller = false;
    active.cancelling = true;
    for (final entry in active.entries) {
      entry.cancelled = true;
    }
  }

  void cancelBundleDownload(List<SubtitleModelSpec> specs) {
    for (final spec in specs) {
      cancelDownload(spec);
    }
  }

  Future<int> deleteBundle(
    List<SubtitleModelSpec> specs, {
    Set<String> retainedSpecNames = const <String>{},
  }) async {
    final targets = [
      for (final spec in specs)
        if (!retainedSpecNames.contains(spec.name)) spec,
    ];
    if (targets.isEmpty) return 0;
    for (final spec in targets) {
      cancelDownload(spec);
    }
    for (final spec in targets) {
      final active = _activeDownloads[spec.name];
      if (active != null) {
        try {
          await active.task;
        } catch (_) {
          // Wait for open file sinks to close before unlinking on Windows.
        }
      }
    }
    final directory = await _directoryResolver();
    var deletedBytes = 0;
    for (final spec in targets) {
      final target = File(path.join(directory.path, spec.name));
      final partial = File('${target.path}.download');
      for (final file in <File>[target, partial]) {
        if (await file.exists()) {
          final size = await file.length();
          await file.delete();
          deletedBytes += size;
        }
        _verifiedFiles.remove(file.path);
      }
      _snapshots.remove(spec.name);
      _modelRevisions[spec.name] = ++_modelRevision;
    }
    notifyListeners();
    return deletedBytes;
  }

  Future<int> deleteAsrModel(SubtitleAsrModelOption option) async {
    final retained = <String>{};
    final vad = option.vadModel;
    if (vad != null) {
      for (final other in builtInAsrModels) {
        if (other.id == option.id || other.vadModel?.name != vad.name) {
          continue;
        }
        if ((await status(other.primaryModel)).ready) {
          retained.add(vad.name);
          break;
        }
      }
    }
    return deleteBundle(option.bundleSpecs, retainedSpecNames: retained);
  }

  Future<SubtitleModelStatus> status(SubtitleModelSpec spec) async {
    final directory = await _directoryResolver();
    final ready = await _valid(
      File(path.join(directory.path, spec.name)),
      spec,
    );
    final usage = ready ? null : await _storage.readStorageUsage();
    return SubtitleModelStatus(
      ready: ready,
      bytes: spec.bytes,
      availableBytes: usage?.availableBytes,
    );
  }

  Future<SubtitleModelStatus> bundleStatus(
    List<SubtitleModelSpec> specs,
  ) async {
    if (specs.length == 1) return status(specs.single);
    if (runtimeType != SubtitleModelStore) {
      var totalBytes = 0;
      var missingBytes = 0;
      int? availableBytes;
      for (final spec in specs) {
        final item = await status(spec);
        totalBytes += spec.bytes;
        if (!item.ready) {
          missingBytes += item.bytes > 0 ? item.bytes : spec.bytes;
          availableBytes ??= item.availableBytes;
        }
      }
      final allReady = missingBytes == 0;
      return SubtitleModelStatus(
        ready: allReady,
        bytes: allReady ? totalBytes : missingBytes,
        availableBytes: allReady ? null : availableBytes,
      );
    }
    final directory = await _directoryResolver();
    var totalBytes = 0;
    var missingBytes = 0;
    for (final spec in specs) {
      totalBytes += spec.bytes;
      final ready = await _valid(
        File(path.join(directory.path, spec.name)),
        spec,
      );
      if (!ready) missingBytes += spec.bytes;
    }
    final allReady = missingBytes == 0;
    final usage = allReady ? null : await _storage.readStorageUsage();
    return SubtitleModelStatus(
      ready: allReady,
      bytes: allReady ? totalBytes : missingBytes,
      availableBytes: usage?.availableBytes,
    );
  }

  Future<List<String>> ensureBundle(
    List<SubtitleModelSpec> specs, {
    void Function(double fraction, int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) {
      throw const SubtitleModelDownloadCancelled();
    }
    if (specs.isEmpty) return const <String>[];
    if (specs.length == 1) {
      return <String>[
        await ensure(
          specs.single,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
      ];
    }
    if (runtimeType == SubtitleModelStore) {
      await _preflightBundleSpace(specs);
    }
    final total = specs.fold<int>(0, (sum, spec) => sum + spec.bytes);
    final receivedByIndex = List<int>.generate(
      specs.length,
      (index) => snapshot(specs[index]).received.clamp(0, specs[index].bytes),
    );
    void notifyCombined() {
      if (onProgress == null) return;
      final sum = receivedByIndex.fold<int>(0, (acc, value) => acc + value);
      onProgress(
        total <= 0 ? 0.0 : (sum / total).clamp(0.0, 1.0),
        sum,
        total,
      );
    }

    final paths = <String>[];
    for (var index = 0; index < specs.length; index++) {
      if (isCancelled?.call() == true) {
        throw const SubtitleModelDownloadCancelled();
      }
      final spec = specs[index];
      final modelPath = await ensure(
        spec,
        onProgress: onProgress == null
            ? null
            : (_, itemReceived, _) {
                receivedByIndex[index] = itemReceived.clamp(0, spec.bytes);
                notifyCombined();
              },
        isCancelled: isCancelled,
      );
      receivedByIndex[index] = spec.bytes;
      notifyCombined();
      paths.add(modelPath);
    }
    return paths;
  }

  Future<void> _preflightBundleSpace(List<SubtitleModelSpec> specs) async {
    final directory = await _directoryResolver();
    await directory.create(recursive: true);
    var remaining = 0;
    File? firstMissing;
    for (final spec in specs) {
      final target = File(path.join(directory.path, spec.name));
      if (await _valid(target, spec)) continue;
      firstMissing ??= target;
      final partial = File('${target.path}.download');
      final received = await partial.exists() ? await partial.length() : 0;
      final usable = received <= spec.bytes ? received : 0;
      remaining += spec.bytes - usable;
    }
    if (remaining <= 0) return;
    final usage = await _storage.readStorageUsage();
    final requiredBytes = remaining + 128 * 1024 * 1024;
    if (usage != null && usage.availableBytes < requiredBytes) {
      throw FileSystemException(
        'Insufficient space for subtitle model',
        firstMissing?.path,
      );
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(path.join(root.path, 'subtitle_models'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> ensure(
    SubtitleModelSpec spec, {
    void Function(double fraction, int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) {
    if (isCancelled?.call() == true) {
      return Future<String>.error(const SubtitleModelDownloadCancelled());
    }
    final existing = _activeDownloads[spec.name];
    if (existing != null) {
      if (existing.cancelling) {
        return existing.task.catchError(
          (_) => ensure(spec, onProgress: onProgress, isCancelled: isCancelled),
          test: (error) => error is SubtitleModelDownloadCancelled,
        );
      }
      if (onProgress == null && isCancelled == null) {
        existing.hasUncancellableCaller = true;
        return existing.task;
      }
      final entry = _ActiveDownloadEntry(
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      existing.entries.add(entry);
      return entry.completer.future;
    }

    final active = _ActiveModelDownload();
    _ActiveDownloadEntry? primaryEntry;
    if (onProgress == null && isCancelled == null) {
      active.hasUncancellableCaller = true;
    } else {
      primaryEntry = _ActiveDownloadEntry(
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      active.entries.add(primaryEntry);
    }
    _activeDownloads[spec.name] = active;
    final task = _download(spec, active);
    active.task = task;
    task.then(
      (modelPath) {
        if (identical(_activeDownloads[spec.name], active)) {
          _activeDownloads.remove(spec.name);
        }
        _snapshots[spec.name] = SubtitleModelDownloadSnapshot(
          received: spec.bytes,
          total: spec.bytes,
          active: false,
        );
        _modelRevisions[spec.name] = ++_modelRevision;
        notifyListeners();
        for (final entry in active.entries) {
          if (!entry.completer.isCompleted) {
            entry.completer.complete(modelPath);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_activeDownloads[spec.name], active)) {
          _activeDownloads.remove(spec.name);
        }
        final last = snapshot(spec);
        _snapshots[spec.name] = SubtitleModelDownloadSnapshot(
          received: last.received,
          total: spec.bytes,
          active: false,
          error: error is SubtitleModelDownloadCancelled ? null : error,
        );
        notifyListeners();
        for (final entry in active.entries) {
          if (!entry.completer.isCompleted) {
            entry.completer.completeError(error, stack);
          }
        }
      },
    );
    return primaryEntry?.completer.future ?? task;
  }

  Future<String> _download(
    SubtitleModelSpec spec,
    _ActiveModelDownload active,
  ) async {
    void reportProgress(double fraction, int received, int total) {
      final last = snapshot(spec);
      _snapshots[spec.name] = SubtitleModelDownloadSnapshot(
        received: received,
        total: total,
        active: true,
      );
      if (received == total ||
          received ~/ 1048576 > last.received ~/ 1048576) {
        notifyListeners();
      }
      for (final entry in List<_ActiveDownloadEntry>.of(active.entries)) {
        if (!entry.cancelled) {
          entry.onProgress?.call(fraction, received, total);
        }
      }
    }

    bool allCallersCancelled() {
      final entries = List<_ActiveDownloadEntry>.of(active.entries);
      for (final entry in entries) {
        entry.cancelled = entry.cancelled || entry.isCancelled?.call() == true;
      }
      if (!active.hasUncancellableCaller &&
          active.entries.every((entry) => entry.cancelled)) {
        // Resolve the last callers after cleanup so they can immediately retry.
        active.cancelling = true;
        return true;
      }
      for (final entry in entries) {
        if (entry.cancelled && !entry.completer.isCompleted) {
          entry.completer.completeError(const SubtitleModelDownloadCancelled());
        }
      }
      return false;
    }

    final directory = await _directoryResolver();
    await directory.create(recursive: true);
    final target = File(path.join(directory.path, spec.name));
    if (await _valid(target, spec)) return target.path;

    final partial = File('${target.path}.download');
    var received = await partial.exists() ? await partial.length() : 0;
    if (received > spec.bytes) {
      await partial.delete();
      received = 0;
    }
    if (received == spec.bytes) {
      if (await _valid(partial, spec)) {
        if (await target.exists()) await target.delete();
        await partial.rename(target.path);
        _verifiedFiles.remove(partial.path);
        return target.path;
      }
      await partial.delete();
      received = 0;
    }
    reportProgress(received / spec.bytes, received, spec.bytes);
    final usage = await _storage.readStorageUsage();
    final requiredBytes = spec.bytes - received + 128 * 1024 * 1024;
    if (usage != null && usage.availableBytes < requiredBytes) {
      throw FileSystemException(
        'Insufficient space for subtitle model',
        target.path,
      );
    }

    if (allCallersCancelled()) {
      throw const SubtitleModelDownloadCancelled();
    }
    final client = _clientFactory();
    var cancelled = false;
    void Function()? cancelWait;
    // Cancellation must wake connection/header/body waits even when the peer
    // sends no more bytes.
    final cancellationTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (!cancelled && allCallersCancelled()) {
          cancelled = true;
          cancelWait?.call();
        }
      },
    );
    Future<T> wait<T>(Future<T> operation, Duration timeout) async {
      if (cancelled) {
        operation.ignore();
        throw const SubtitleModelDownloadCancelled();
      }
      final expired = Completer<T>();
      cancelWait = () {
        if (!expired.isCompleted) {
          expired.completeError(const SubtitleModelDownloadCancelled());
        }
      };
      final timer = Timer(timeout, () {
        if (!expired.isCompleted) {
          expired.completeError(
            TimeoutException('Subtitle model download stalled', timeout),
          );
        }
      });
      try {
        return await Future.any<T>([operation, expired.future]);
      } finally {
        operation.ignore();
        timer.cancel();
        cancelWait = null;
      }
    }

    try {
      client.connectionTimeout = _connectionTimeout;
      final request = await wait(
        client.getUrl(Uri.parse(spec.url)),
        _connectionTimeout,
      );
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await wait(request.close(), _responseTimeout);
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException(
          'Model download failed: ${response.statusCode}',
          uri: Uri.parse(spec.url),
        );
      }
      if (received > 0 && response.statusCode == HttpStatus.ok) {
        await partial.delete();
        received = 0;
      } else if (received > 0) {
        final contentRange = response.headers.value(
          HttpHeaders.contentRangeHeader,
        );
        if (contentRange == null ||
            !contentRange.startsWith('bytes $received-') ||
            !contentRange.endsWith('/${spec.bytes}')) {
          throw const FormatException(
            'Model resume range does not match request',
          );
        }
      }
      final sink = partial.openWrite(
        mode: received == 0 ? FileMode.write : FileMode.append,
      );
      final chunks = StreamIterator(response);
      try {
        while (await wait(chunks.moveNext(), _idleTimeout)) {
          if (allCallersCancelled()) {
            throw const SubtitleModelDownloadCancelled();
          }
          final chunk = chunks.current;
          sink.add(chunk);
          received += chunk.length;
          if (received > spec.bytes) {
            throw const FormatException('Model exceeds expected size');
          }
          reportProgress(received / spec.bytes, received, spec.bytes);
        }
        await sink.flush();
      } finally {
        try {
          await chunks.cancel();
        } finally {
          await sink.close();
        }
      }
      final valid = await _valid(partial, spec);
      if (cancelled || allCallersCancelled()) {
        throw const SubtitleModelDownloadCancelled();
      }
      if (!valid) {
        await partial.delete();
        throw const FormatException('Subtitle model checksum mismatch');
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      _verifiedFiles.remove(partial.path);
      return target.path;
    } finally {
      cancellationTimer.cancel();
      client.close(force: true);
    }
  }

  Future<bool> _valid(File file, SubtitleModelSpec spec) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size != spec.bytes) {
      _verifiedFiles.remove(file.path);
      return false;
    }
    final verified = _verifiedFiles[file.path];
    if (verified != null &&
        verified.sha256 == spec.sha256 &&
        verified.modified == stat.modified &&
        verified.changed == stat.changed) {
      if (path.basename(file.path) == spec.name) {
        _snapshots[spec.name] ??= SubtitleModelDownloadSnapshot(
          received: spec.bytes,
          total: spec.bytes,
          active: false,
        );
      }
      return true;
    }
    final key = (
      filePath: file.path,
      modified: stat.modified,
      changed: stat.changed,
      sha256: spec.sha256,
    );
    final pending = _pendingVerification[key];
    if (pending != null) return pending;
    final task = _verifyModelDigest(file, spec, stat);
    _pendingVerification[key] = task;
    try {
      return await task;
    } finally {
      unawaited(_pendingVerification.remove(key));
    }
  }

  Future<bool> _verifyModelDigest(
    File file,
    SubtitleModelSpec spec,
    FileStat stat,
  ) async {
    final digest = await _readModelDigest(file.path);
    final current = await file.stat();
    if (current.type != stat.type ||
        current.size != stat.size ||
        current.modified != stat.modified ||
        current.changed != stat.changed) {
      return false;
    }
    if (digest.toString() != spec.sha256) {
      _verifiedFiles.remove(file.path);
      return false;
    }
    _verifiedFiles[file.path] = (
      modified: stat.modified,
      changed: stat.changed,
      sha256: spec.sha256,
    );
    if (path.basename(file.path) == spec.name) {
      _snapshots[spec.name] ??= SubtitleModelDownloadSnapshot(
        received: spec.bytes,
        total: spec.bytes,
        active: false,
      );
    }
    return true;
  }
}

Future<Digest> _readModelDigest(String filePath) =>
    Isolate.run(() => sha256.bind(File(filePath).openRead()).first);

class SubtitleModelDownloadCancelled implements Exception {
  const SubtitleModelDownloadCancelled();
}

class _ActiveDownloadEntry {
  _ActiveDownloadEntry({required this.onProgress, required this.isCancelled});

  final void Function(double fraction, int received, int total)? onProgress;
  final bool Function()? isCancelled;
  final Completer<String> completer = Completer<String>();
  bool cancelled = false;
}

class _ActiveModelDownload {
  final List<_ActiveDownloadEntry> entries = <_ActiveDownloadEntry>[];
  bool hasUncancellableCaller = false;
  bool cancelling = false;
  late final Future<String> task;
}
