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
  }) : _storage = storage ?? FileCachePlatformGateway.instance,
       _directoryResolver = directoryResolver ?? _defaultDirectory,
       _clientFactory = clientFactory ?? HttpClient.new;

  static const japaneseCtc = SubtitleModelSpec(
    'wav2vec2-large-xlsr-53-japanese-q8_0.gguf',
    'https://huggingface.co/cstr/wav2vec2-large-xlsr-53-japanese-GGUF/resolve/16c3b21fe7858426806f4bf795578497e0b5dad2/wav2vec2-large-xlsr-53-japanese-q8_0.gguf',
    382763008,
    '12ebea2f51f2376a271f4115772c750000c1e3c2835f8c4021479fa1ee7b0a77',
  );

  static const translation = SubtitleModelSpec(
    'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    1117320736,
    '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
  );

  final FileCachePlatformGateway _storage;
  final Future<Directory> Function() _directoryResolver;
  final HttpClient Function() _clientFactory;
  final Map<String, Future<String>> _activeDownloads = {};
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
    final active = _activeDownloads[spec.name];
    if (active != null) return active;
    final task = _download(
      spec,
      isCancelled: isCancelled,
      onProgress: (fraction, received, total) {
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
        onProgress?.call(fraction, received, total);
      },
    );
    _activeDownloads[spec.name] = task;
    task.then(
      (_) {
        _activeDownloads.remove(spec.name);
        _snapshots[spec.name] = SubtitleModelDownloadSnapshot(
          received: spec.bytes,
          total: spec.bytes,
          active: false,
        );
        notifyListeners();
      },
      onError: (Object error, StackTrace stack) {
        _activeDownloads.remove(spec.name);
        final last = snapshot(spec);
        _snapshots[spec.name] = SubtitleModelDownloadSnapshot(
          received: last.received,
          total: spec.bytes,
          active: false,
          error: error,
        );
        notifyListeners();
      },
    );
    return task;
  }

  Future<String> _download(
    SubtitleModelSpec spec, {
    void Function(double fraction, int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
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
    _snapshots[spec.name] = SubtitleModelDownloadSnapshot(
      received: received,
      total: spec.bytes,
      active: true,
    );
    notifyListeners();
    onProgress?.call(received / spec.bytes, received, spec.bytes);
    final usage = await _storage.readStorageUsage();
    final requiredBytes = spec.bytes - received + 128 * 1024 * 1024;
    if (usage != null && usage.availableBytes < requiredBytes) {
      throw FileSystemException(
        'Insufficient space for subtitle model',
        target.path,
      );
    }

    final client = _clientFactory();
    try {
      final request = await client.getUrl(Uri.parse(spec.url));
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await request.close();
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
      try {
        await for (final chunk in response) {
          if (isCancelled?.call() == true) {
            throw const SubtitleModelDownloadCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          if (received > spec.bytes) {
            throw const FormatException('Model exceeds expected size');
          }
          onProgress?.call(received / spec.bytes, received, spec.bytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (!await _valid(partial, spec)) {
        await partial.delete();
        throw const FormatException('Subtitle model checksum mismatch');
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      _verifiedFiles.remove(partial.path);
      return target.path;
    } finally {
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
