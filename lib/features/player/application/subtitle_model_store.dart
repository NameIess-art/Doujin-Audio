import 'dart:async';
import 'dart:io';

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

  final FileCachePlatformGateway _storage;
  final Future<Directory> Function() _directoryResolver;
  final HttpClient Function() _clientFactory;
  final Duration _connectionTimeout;
  final Duration _responseTimeout;
  final Duration _idleTimeout;
  final Map<String, _ActiveModelDownload> _activeDownloads = {};
  final Map<String, SubtitleModelDownloadSnapshot> _snapshots = {};
  final Map<String, ({DateTime modified, DateTime changed, String sha256})>
  _verifiedFiles = {};

  SubtitleModelDownloadSnapshot snapshot(SubtitleModelSpec spec) =>
      _snapshots[spec.name] ??
      SubtitleModelDownloadSnapshot(
        received: 0,
        total: spec.bytes,
        active: false,
      );

  void cancelDownload(SubtitleModelSpec spec) {
    final active = _activeDownloads[spec.name];
    if (active == null) return;
    active.hasUncancellableCaller = false;
    active.cancelling = true;
    for (final entry in active.entries) {
      entry.cancelled = true;
    }
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
      return true;
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != spec.sha256) {
      _verifiedFiles.remove(file.path);
      return false;
    }
    _verifiedFiles[file.path] = (
      modified: stat.modified,
      changed: stat.changed,
      sha256: spec.sha256,
    );
    return true;
  }
}

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
