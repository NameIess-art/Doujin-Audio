import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'library_scan_models.dart';
import 'app_log_service.dart';
import 'media_file_support.dart';
import 'path_display.dart';
import 'platform_channels.dart';

class FileCachePlatformGateway {
  FileCachePlatformGateway({
    MethodChannel? channel,
    EventChannel? scanEvents,
    bool Function()? isAndroid,
  }) : _channel = channel ?? const MethodChannel(FileCacheChannel.name),
       _scanEvents =
           scanEvents ?? const EventChannel(FileCacheChannel.scanEvents),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  static final FileCachePlatformGateway instance = FileCachePlatformGateway();

  final MethodChannel _channel;
  final EventChannel _scanEvents;
  final bool Function() _isAndroid;

  int _scanSessionSeed = 0;

  Future<NativeScanResult> scanFolder(String folderPath) async {
    if (!_isAndroid()) return const NativeScanResult.notSupported();
    final streamedScan = await _scanFolderStream(folderPath);
    if (streamedScan.ok || !streamedScan.notSupported) return streamedScan;
    return _scanFolderLegacy(folderPath);
  }

  Future<List<String>?> listChildFolders(String folderPath) async {
    if (!_isAndroid()) return null;
    try {
      final data = await _channel.invokeMethod<List<dynamic>>(
        FileCacheMethod.listChildFolders,
        {'folder': folderPath},
      );
      return data
          ?.map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // Native listing is optional; the scanner falls back to file-system I/O.
      return null;
    }
  }

  Future<String?> pickAudioFolder() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      FileCacheMethod.pickAudioFolder,
    );
    final pathValue = raw?['path']?.toString().trim();
    return pathValue == null || pathValue.isEmpty ? null : pathValue;
  }

  Future<List<PickedAudioFile>?> pickAudioFiles() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      FileCacheMethod.pickAudioFiles,
    );
    final items = raw?['files'];
    if (items is! List) return null;
    final files = <PickedAudioFile>[];
    for (final item in items) {
      if (item is! Map) continue;
      final map = item.cast<Object?, Object?>();
      final uri = map['uri']?.toString().trim();
      final name = map['name']?.toString().trim();
      final audioTypeHint = name == null || name.isEmpty
          ? (uri ?? '')
          : path.normalize(name);
      if (uri == null || uri.isEmpty || !isSupportedMediaFile(audioTypeHint)) {
        continue;
      }
      files.add(
        PickedAudioFile(
          uri: uri,
          name: name == null || name.isEmpty
              ? PathDisplay.fileName(uri, withoutExtension: true)
              : name,
        ),
      );
    }
    return files;
  }

  Future<String?> cacheFromUri({
    required String uri,
    required String name,
    required int index,
  }) {
    return _channel.invokeMethod<String>(FileCacheMethod.cacheFromUri, {
      'uri': uri,
      'name': name,
      'index': index,
    });
  }

  Future<List<dynamic>?> scanFolderPayload(String folderPath) {
    return _channel.invokeMethod<List<dynamic>>(
      FileCacheMethod.scanFolder,
      <String, Object?>{'folder': folderPath},
    );
  }

  Future<Map<String, Object?>?> renameDocument({
    required String path,
    required String name,
  }) {
    return _channel.invokeMapMethod<String, Object?>(
      FileCacheMethod.renameDocument,
      <String, Object?>{'path': path, 'name': name},
    );
  }

  Future<List<String>> discoverRootImages({
    required String path,
    String? groupKey,
    required String rootFolder,
  }) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      FileCacheMethod.discoverRootImages,
      <String, Object?>{
        'path': path,
        'groupKey': groupKey,
        'rootFolder': rootFolder,
      },
    );
    return raw
            ?.map((item) => item?.toString().trim() ?? '')
            .where((item) => item.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
  }

  Future<String?> resolveTrackCover({
    required String path,
    String? groupKey,
    String? rootFolder,
  }) {
    return _channel.invokeMethod<String>(
      FileCacheMethod.resolveTrackCover,
      <String, Object?>{
        'path': path,
        'groupKey': groupKey,
        'rootFolder': rootFolder,
      },
    );
  }

  Future<String?> resolveVideoFrame({required String path, int? modifiedAtMs}) {
    return _channel.invokeMethod<String>(
      FileCacheMethod.resolveVideoFrame,
      <String, Object?>{'path': path, 'modifiedAtMs': ?modifiedAtMs},
    );
  }

  Future<Map<String, Object?>?> resolveTrackSubtitle({
    required String path,
    String? groupKey,
  }) {
    return _channel.invokeMapMethod<String, Object?>(
      FileCacheMethod.resolveTrackSubtitle,
      <String, Object?>{'path': path, 'groupKey': groupKey},
    );
  }

  Future<bool> writeAudioDetailBackup({
    required String folder,
    required String json,
  }) async {
    return await _channel.invokeMethod<bool>(
          FileCacheMethod.writeAudioDetailBackup,
          <String, Object?>{'folder': folder, 'json': json},
        ) ??
        false;
  }

  Future<String?> readAudioDetailBackup(String folder) {
    return _channel.invokeMethod<String>(
      FileCacheMethod.readAudioDetailBackup,
      <String, Object?>{'folder': folder},
    );
  }

  Future<String?> readSingleFileDetailBackup(String filePath) {
    return _channel.invokeMethod<String>(
      FileCacheMethod.readSingleFileDetailBackup,
      <String, Object?>{'filePath': filePath},
    );
  }

  Future<bool> writeSingleFileDetailBackup({
    required String filePath,
    required String json,
  }) async {
    return await _channel.invokeMethod<bool>(
          FileCacheMethod.writeSingleFileDetailBackup,
          <String, Object?>{'filePath': filePath, 'json': json},
        ) ??
        false;
  }

  Future<String?> writeFileBytesToFolder({
    required String folder,
    required String name,
    required Uint8List bytes,
    String? mimeType,
  }) {
    return _channel.invokeMethod<String>(
      FileCacheMethod.writeFileBytesToFolder,
      <String, Object?>{
        'folder': folder,
        'name': name,
        'bytes': bytes,
        'mimeType': mimeType,
      },
    );
  }

  Future<bool> documentPathExists(String path) async {
    return await _channel.invokeMethod<bool>(
          FileCacheMethod.documentPathExists,
          <String, Object?>{'path': path},
        ) ??
        false;
  }

  Future<bool> ensureFolderPath({
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    return await _channel.invokeMethod<bool>(
          FileCacheMethod.ensureFolderPath,
          <String, Object?>{
            'folder': folder,
            'relativePath': relativePath,
            'overwrite': overwrite,
          },
        ) ??
        false;
  }

  Future<bool> copyFileToFolder({
    required String sourcePath,
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    return await _channel.invokeMethod<bool>(
          FileCacheMethod.copyFileToFolder,
          <String, Object?>{
            'sourcePath': sourcePath,
            'folder': folder,
            'relativePath': relativePath,
            'overwrite': overwrite,
          },
        ) ??
        false;
  }

  Future<bool> deleteDocumentPath(String path) async {
    return await _channel.invokeMethod<bool>(
          FileCacheMethod.deleteDocumentPath,
          <String, Object?>{'path': path},
        ) ??
        false;
  }

  Future<void> setApplicationCacheLimit(int maxBytes) {
    return _channel.invokeMethod<void>(
      FileCacheMethod.setApplicationCacheLimit,
      <String, Object?>{'maxBytes': maxBytes},
    );
  }

  Future<int> clearApplicationCache() async {
    return await _channel.invokeMethod<int>(
          FileCacheMethod.clearApplicationCache,
        ) ??
        0;
  }

  Future<void> enforceApplicationCacheLimit(int maxBytes) {
    return _channel.invokeMethod<void>(
      FileCacheMethod.enforceApplicationCacheLimit,
      <String, Object?>{'maxBytes': maxBytes},
    );
  }

  Future<NativeScanResult> _scanFolderStream(String folderPath) async {
    final sessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${_scanSessionSeed++}';
    final tracks = <ScannedTrack>[];
    final paths = <String>{};
    final completer = Completer<NativeScanResult>();
    StreamSubscription<dynamic>? subscription;

    void complete(NativeScanResult result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    try {
      subscription = _scanEvents
          .receiveBroadcastStream(<String, Object?>{'sessionId': sessionId})
          .listen(
            (event) {
              if (event is! Map) return;
              final scanEvent = FolderScanSessionEvent.fromPayload(
                event.cast<Object?, Object?>(),
              );
              if (scanEvent.sessionId != sessionId) return;
              if (scanEvent.isChunk) {
                tracks.addAll(scanEvent.chunk.tracks);
                paths.addAll(scanEvent.chunk.paths);
              } else if (scanEvent.isDone) {
                complete(
                  NativeScanResult.success(
                    List<ScannedTrack>.unmodifiable(tracks),
                    Set<String>.unmodifiable(paths),
                  ),
                );
              } else if (scanEvent.isError) {
                complete(
                  NativeScanResult.failed(
                    code: scanEvent.errorCode,
                    message: scanEvent.errorMessage,
                  ),
                );
              }
            },
            onError: (Object error) => complete(
              NativeScanResult.failed(
                code: 'scan_event_error',
                message: error.toString(),
              ),
            ),
          );
      final started = await _channel.invokeMethod<bool>(
        FileCacheMethod.startFolderScan,
        <String, Object?>{
          'sessionId': sessionId,
          'folder': folderPath,
          'chunkSize': 120,
        },
      );
      if (started != true) return const NativeScanResult.notSupported();
      return await completer.future;
    } on MissingPluginException {
      return const NativeScanResult.notSupported();
    } on PlatformException catch (error) {
      if (error.code == 'notImplemented') {
        return const NativeScanResult.notSupported();
      }
      return NativeScanResult.failed(code: error.code, message: error.message);
    } catch (error, stackTrace) {
      AppLogService.error(
        'streamed_library_scan_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
    } finally {
      await subscription?.cancel();
      if (!completer.isCompleted) unawaited(_cancelFolderScan(sessionId));
    }
  }

  Future<void> _cancelFolderScan(String sessionId) async {
    try {
      await _channel.invokeMethod<bool>(
        FileCacheMethod.cancelFolderScan,
        <String, Object?>{'sessionId': sessionId},
      );
    } catch (_) {
      // Cancellation is best effort because the native scan may already end.
    }
  }

  Future<NativeScanResult> _scanFolderLegacy(String folderPath) async {
    try {
      final data = await _channel.invokeMethod<List<dynamic>>(
        FileCacheMethod.scanFolder,
        {'folder': folderPath},
      );
      if (data == null) {
        return const NativeScanResult.failed(
          code: 'scan_empty_response',
          message: 'Native scan returned null data.',
        );
      }
      final payload = await Isolate.run(() => parseNativeScanPayload(data));
      return NativeScanResult.success(payload.tracks, payload.paths);
    } on PlatformException catch (error) {
      return NativeScanResult.failed(code: error.code, message: error.message);
    } catch (error, stackTrace) {
      AppLogService.error(
        'legacy_library_scan_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
    }
  }
}
