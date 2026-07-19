import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'library_scan_wire_models.dart';
import '../logging/app_log_service.dart';
import '../media/media_file_support.dart';
import '../errors/native_result.dart';
import '../media/path_display.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class FileCachePlatformGateway {
  FileCachePlatformGateway({
    MethodChannel? channel,
    EventChannel? scanEvents,
    bool Function()? isAndroid,
  }) : _client = PlatformMethodClient(
         channel ?? const MethodChannel(FileCacheChannel.name),
       ),
       _scanEvents =
           scanEvents ?? const EventChannel(FileCacheChannel.scanEvents),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  static final FileCachePlatformGateway instance = FileCachePlatformGateway();

  final PlatformMethodClient _client;
  final EventChannel _scanEvents;
  final bool Function() _isAndroid;

  void _logOptionalFailure<T>(String method, NativeResult<T> result) {
    if (result case NativeFailure<T>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'optional_native_file_operation_failed',
        error: <String, Object?>{
          'method': method,
          'code': code,
          'message': message,
          'details': details,
        },
      );
    }
  }

  int _scanSessionSeed = 0;
  int _scanGenerationSeed = 0;
  String? _activeScanTaskId;

  Future<NativeScanResult> scanFolder(String folderPath) async {
    if (!_isAndroid()) return const NativeScanResult.notSupported();
    final streamedScan = await _scanFolderStream(folderPath);
    if (streamedScan.ok || !streamedScan.notSupported) return streamedScan;
    return _scanFolderLegacy(folderPath);
  }

  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) async {
    if (!_isAndroid()) return const NativeScanResult.notSupported();
    final streamedScan = await _scanFolderStreamChunked(
      folderPath,
      onChunk,
      onProgress: onProgress,
    );
    if (streamedScan.ok || !streamedScan.notSupported) return streamedScan;
    return const NativeScanResult.notSupported();
  }

  Future<List<String>?> listChildFolders(String folderPath) async {
    if (!_isAndroid()) return null;
    final result = await _client.invoke<List<Object?>>(
      FileCacheMethod.listChildFolders,
      arguments: <String, Object?>{'folder': folderPath},
      decode: (value) => (value as List).cast<Object?>(),
    );
    if (result case NativeSuccess<List<Object?>>(:final value)) {
      return value
          ?.map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    _logOptionalFailure(FileCacheMethod.listChildFolders, result);
    return null;
  }

  Future<String?> pickAudioFolder() async {
    final result = await _client.invoke<Map<String, Object?>?>(
      FileCacheMethod.pickAudioFolder,
      decode: (value) =>
          value == null ? null : Map<String, Object?>.from(value as Map),
    );
    final raw = result.valueOrNull;
    final pathValue = raw?['path']?.toString().trim();
    return pathValue == null || pathValue.isEmpty ? null : pathValue;
  }

  Future<List<PickedAudioFile>?> pickAudioFiles() async {
    final result = await _client.invoke<Map<String, Object?>?>(
      FileCacheMethod.pickAudioFiles,
      decode: (value) =>
          value == null ? null : Map<String, Object?>.from(value as Map),
    );
    final raw = result.valueOrNull;
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
  }) async {
    final result = await _client.invoke<String?>(
      FileCacheMethod.cacheFromUri,
      arguments: <String, Object?>{'uri': uri, 'name': name, 'index': index},
      decode: (value) => value as String?,
    );
    return result.valueOrNull;
  }

  Future<List<dynamic>?> scanFolderPayload(String folderPath) async {
    final result = await _client.invoke<List<dynamic>?>(
      FileCacheMethod.scanFolder,
      arguments: <String, Object?>{'folder': folderPath},
      decode: (value) => value as List<dynamic>?,
    );
    return result.valueOrNull;
  }

  Future<Map<String, Object?>?> renameDocument({
    required String path,
    required String name,
  }) async {
    final result = await _client.invoke<Map<String, Object?>?>(
      FileCacheMethod.renameDocument,
      arguments: <String, Object?>{'path': path, 'name': name},
      decode: (value) =>
          value == null ? null : Map<String, Object?>.from(value as Map),
    );
    return result.valueOrNull;
  }

  Future<List<String>> discoverRootImages({
    required String path,
    String? groupKey,
    required String rootFolder,
  }) async {
    final result = await _client.invoke<List<Object?>>(
      FileCacheMethod.discoverRootImages,
      arguments: <String, Object?>{
        'path': path,
        'groupKey': groupKey,
        'rootFolder': rootFolder,
      },
      decode: (value) => (value as List).cast<Object?>(),
    );
    if (result is NativeFailure<List<Object?>>) {
      _logOptionalFailure(FileCacheMethod.discoverRootImages, result);
    }
    final raw = result.valueOrNull;
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
  }) async {
    final result = await _client.invoke<String?>(
      FileCacheMethod.resolveTrackCover,
      arguments: <String, Object?>{
        'path': path,
        'groupKey': groupKey,
        'rootFolder': rootFolder,
      },
      decode: (value) => value as String?,
    );
    if (result is NativeFailure<String?>) {
      _logOptionalFailure(FileCacheMethod.resolveTrackCover, result);
    }
    return result.valueOrNull;
  }

  Future<String?> resolveVideoFrame({
    required String path,
    int? modifiedAtMs,
  }) async {
    final result = await _client.invoke<String?>(
      FileCacheMethod.resolveVideoFrame,
      arguments: <String, Object?>{'path': path, 'modifiedAtMs': ?modifiedAtMs},
      decode: (value) => value as String?,
    );
    if (result is NativeFailure<String?>) {
      _logOptionalFailure(FileCacheMethod.resolveVideoFrame, result);
    }
    return result.valueOrNull;
  }

  Future<Duration?> resolveMediaDuration(String mediaPath) async {
    if (!_isAndroid()) return null;
    try {
      final result = await _client
          .invoke<num?>(
            FileCacheMethod.resolveMediaDuration,
            arguments: <String, Object?>{'path': mediaPath},
            decode: (value) => value as num?,
          )
          .timeout(const Duration(seconds: 8));
      if (result is NativeFailure<num?>) {
        _logOptionalFailure(FileCacheMethod.resolveMediaDuration, result);
      }
      final milliseconds = result.valueOrNull;
      if (milliseconds == null || milliseconds <= 0) return null;
      return Duration(milliseconds: milliseconds.toInt());
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>?> resolveTrackSubtitle({
    required String path,
    String? groupKey,
  }) async {
    final result = await _client.invoke<Map<String, Object?>?>(
      FileCacheMethod.resolveTrackSubtitle,
      arguments: <String, Object?>{'path': path, 'groupKey': groupKey},
      decode: (value) =>
          value == null ? null : Map<String, Object?>.from(value as Map),
    );
    if (result is NativeFailure<Map<String, Object?>?>) {
      _logOptionalFailure(FileCacheMethod.resolveTrackSubtitle, result);
    }
    return result.valueOrNull;
  }

  Future<bool> writeAudioDetailBackup({
    required String folder,
    required String json,
  }) async {
    final result = await _client.invoke<bool>(
      FileCacheMethod.writeAudioDetailBackup,
      arguments: <String, Object?>{'folder': folder, 'json': json},
      decode: (value) => value as bool,
    );
    return result.valueOrNull ?? false;
  }

  Future<String?> readAudioDetailBackup(String folder) async {
    final result = await _client.invoke<String?>(
      FileCacheMethod.readAudioDetailBackup,
      arguments: <String, Object?>{'folder': folder},
      decode: (value) => value as String?,
    );
    return result.valueOrNull;
  }

  Future<String?> readSingleFileDetailBackup(String filePath) async {
    final result = await _client.invoke<String?>(
      FileCacheMethod.readSingleFileDetailBackup,
      arguments: <String, Object?>{'filePath': filePath},
      decode: (value) => value as String?,
    );
    return result.valueOrNull;
  }

  Future<bool> writeSingleFileDetailBackup({
    required String filePath,
    required String json,
  }) async {
    final result = await _client.invoke<bool>(
      FileCacheMethod.writeSingleFileDetailBackup,
      arguments: <String, Object?>{'filePath': filePath, 'json': json},
      decode: (value) => value as bool,
    );
    return result.valueOrNull ?? false;
  }

  Future<String?> writeFileBytesToFolder({
    required String folder,
    required String name,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    final result = await _client.invoke<String?>(
      FileCacheMethod.writeFileBytesToFolder,
      arguments: <String, Object?>{
        'folder': folder,
        'name': name,
        'bytes': bytes,
        'mimeType': mimeType,
      },
      decode: (value) => value as String?,
    );
    return result.valueOrNull;
  }

  Future<bool> documentPathExists(String path) async {
    final result = await _client.invoke<bool>(
      FileCacheMethod.documentPathExists,
      arguments: <String, Object?>{'path': path},
      decode: (value) => value as bool,
    );
    return result.valueOrNull ?? false;
  }

  Future<bool> ensureFolderPath({
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    final result = await _client.invoke<bool>(
      FileCacheMethod.ensureFolderPath,
      arguments: <String, Object?>{
        'folder': folder,
        'relativePath': relativePath,
        'overwrite': overwrite,
      },
      decode: (value) => value as bool,
    );
    return result.valueOrNull ?? false;
  }

  Future<bool> copyFileToFolder({
    required String sourcePath,
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    final result = await _client.invoke<bool>(
      FileCacheMethod.copyFileToFolder,
      arguments: <String, Object?>{
        'sourcePath': sourcePath,
        'folder': folder,
        'relativePath': relativePath,
        'overwrite': overwrite,
      },
      decode: (value) => value as bool,
    );
    return result.valueOrNull ?? false;
  }

  Future<String?> exportFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    if (!_isAndroid()) return Future<String?>.value();
    final result = await _client.invoke<String?>(
      FileCacheMethod.exportFile,
      arguments: <String, Object?>{
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
      },
      decode: (value) => value as String?,
    );
    return result.valueOrNull;
  }

  Future<bool> deleteDocumentPath(String path) async {
    final result = await _client.invoke<bool>(
      FileCacheMethod.deleteDocumentPath,
      arguments: <String, Object?>{'path': path},
      decode: (value) => value as bool,
    );
    return result.valueOrNull ?? false;
  }

  Future<void> setApplicationCacheLimit(int maxBytes) async {
    await _client.invoke<Object?>(
      FileCacheMethod.setApplicationCacheLimit,
      arguments: <String, Object?>{'maxBytes': maxBytes},
      decode: (value) => value,
    );
  }

  Future<int> clearApplicationCache() async {
    final result = await _client.invoke<num>(
      FileCacheMethod.clearApplicationCache,
      decode: (value) => value as num,
    );
    return result.valueOrNull?.toInt() ?? 0;
  }

  Future<void> enforceApplicationCacheLimit(int maxBytes) async {
    await _client.invoke<Object?>(
      FileCacheMethod.enforceApplicationCacheLimit,
      arguments: <String, Object?>{'maxBytes': maxBytes},
      decode: (value) => value,
    );
  }

  Future<NativeScanResult> _scanFolderStream(String folderPath) async {
    final taskId =
        '${DateTime.now().microsecondsSinceEpoch}-${_scanSessionSeed++}';
    final generationId = 'scan-generation-${_scanGenerationSeed++}';
    final tracks = <ScannedTrack>[];
    final paths = <String>{};
    var failureCount = 0;
    final completer = Completer<NativeScanResult>();
    StreamSubscription<dynamic>? subscription;
    if (_activeScanTaskId != null) {
      return const NativeScanResult.failed(
        code: 'scan_busy',
        message: 'Another folder scan is already running.',
      );
    }
    _activeScanTaskId = taskId;

    final eventLifecycle = _FolderScanEventLifecycle(
      completer: completer,
      cancelNativeScan: () => _cancelFolderScan(taskId),
    )..markActivity();

    try {
      subscription = _scanEvents
          .receiveBroadcastStream(<String, Object?>{
            'taskId': taskId,
            'generationId': generationId,
          })
          .listen(
            (event) {
              if (event is! Map) return;
              final scanEvent = FolderScanSessionEvent.fromPayload(
                event.cast<Object?, Object?>(),
              );
              if (scanEvent.taskId != taskId ||
                  scanEvent.generationId != generationId) {
                return;
              }
              eventLifecycle.markActivity();
              if (scanEvent.isChunk) {
                tracks.addAll(scanEvent.chunk.tracks);
                paths.addAll(scanEvent.chunk.paths);
                failureCount += scanEvent.chunk.failureCount;
              } else if (scanEvent.isDone) {
                eventLifecycle.complete(
                  NativeScanResult.success(
                    List<ScannedTrack>.unmodifiable(tracks),
                    Set<String>.unmodifiable(paths),
                    failureCount: failureCount + scanEvent.chunk.failureCount,
                    completenessKnown: true,
                  ),
                );
              } else if (scanEvent.isCancelled) {
                eventLifecycle.complete(
                  NativeScanResult.success(
                    List<ScannedTrack>.unmodifiable(tracks),
                    Set<String>.unmodifiable(paths),
                    failureCount: failureCount,
                    completenessKnown: true,
                    wasCancelled: true,
                  ),
                );
              } else if (scanEvent.isError) {
                eventLifecycle.complete(
                  NativeScanResult.failed(
                    code: scanEvent.errorCode,
                    message: scanEvent.errorMessage,
                  ),
                );
              }
            },
            onError: (Object error) => eventLifecycle.fail(
              code: 'scan_event_error',
              message: error.toString(),
            ),
            onDone: () => eventLifecycle.fail(
              code: 'scan_event_closed',
              message: 'Folder scan event stream closed before completion.',
            ),
          );
      final startResult = await _client.invoke<bool>(
        FileCacheMethod.startFolderScan,
        arguments: <String, Object?>{
          'taskId': taskId,
          'generationId': generationId,
          'folder': folderPath,
          'chunkSize': 120,
        },
        decode: (value) => value as bool,
      );
      final started = startResult.valueOrNull;
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
      eventLifecycle.dispose();
      _releaseScanSubscription(subscription);
      if (!eventLifecycle.isCompleted) unawaited(_cancelFolderScan(taskId));
      if (_activeScanTaskId == taskId) _activeScanTaskId = null;
    }
  }

  Future<NativeScanResult> _scanFolderStreamChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) async {
    final taskId =
        '${DateTime.now().microsecondsSinceEpoch}-${_scanSessionSeed++}';
    final generationId = 'scan-generation-${_scanGenerationSeed++}';
    final paths = <String>{};
    var failureCount = 0;
    final completer = Completer<NativeScanResult>();
    StreamSubscription<dynamic>? subscription;
    Future<void> pendingChunk = Future<void>.value();
    if (_activeScanTaskId != null) {
      return const NativeScanResult.failed(
        code: 'scan_busy',
        message: 'Another folder scan is already running.',
      );
    }
    _activeScanTaskId = taskId;

    final eventLifecycle = _FolderScanEventLifecycle(
      completer: completer,
      cancelNativeScan: () => _cancelFolderScan(taskId),
    )..markActivity();

    Future<void> completeAfterPending(NativeScanResult Function() result) {
      pendingChunk = pendingChunk.whenComplete(() {
        eventLifecycle.complete(result());
      });
      return pendingChunk;
    }

    try {
      subscription = _scanEvents
          .receiveBroadcastStream(<String, Object?>{
            'taskId': taskId,
            'generationId': generationId,
          })
          .listen(
            (event) {
              if (event is! Map || completer.isCompleted) return;
              final scanEvent = FolderScanSessionEvent.fromPayload(
                event.cast<Object?, Object?>(),
              );
              if (scanEvent.taskId != taskId ||
                  scanEvent.generationId != generationId) {
                return;
              }
              eventLifecycle.markActivity();
              if (scanEvent.isStarted ||
                  scanEvent.isStageChanged ||
                  scanEvent.isProgress) {
                onProgress?.call(scanEvent);
                return;
              }
              if (scanEvent.isChunk) {
                final chunk = scanEvent.chunk;
                pendingChunk = pendingChunk
                    .then((_) async {
                      if (completer.isCompleted) return;
                      paths.addAll(chunk.paths);
                      failureCount += chunk.failureCount;
                      final keepGoing = await onChunk(chunk);
                      if (!keepGoing) {
                        eventLifecycle.complete(
                          NativeScanResult.success(
                            const <ScannedTrack>[],
                            Set<String>.unmodifiable(paths),
                            failureCount: failureCount,
                            completenessKnown: true,
                            wasCancelled: true,
                          ),
                        );
                        unawaited(_cancelFolderScan(taskId));
                      }
                    })
                    .catchError((Object error, StackTrace stackTrace) {
                      AppLogService.error(
                        'chunked_library_scan_handler_failed',
                        error: error,
                        stackTrace: stackTrace,
                      );
                      eventLifecycle.complete(
                        NativeScanResult.failed(
                          code: 'scan_handler_error',
                          message: error.toString(),
                        ),
                      );
                      unawaited(_cancelFolderScan(taskId));
                    });
              } else if (scanEvent.isDone) {
                unawaited(
                  completeAfterPending(
                    () => NativeScanResult.success(
                      const <ScannedTrack>[],
                      Set<String>.unmodifiable(paths),
                      failureCount: failureCount + scanEvent.chunk.failureCount,
                      completenessKnown: true,
                    ),
                  ),
                );
              } else if (scanEvent.isCancelled) {
                unawaited(
                  completeAfterPending(
                    () => NativeScanResult.success(
                      const <ScannedTrack>[],
                      Set<String>.unmodifiable(paths),
                      failureCount: failureCount,
                      completenessKnown: true,
                      wasCancelled: true,
                    ),
                  ),
                );
              } else if (scanEvent.isError) {
                unawaited(
                  completeAfterPending(
                    () => NativeScanResult.failed(
                      code: scanEvent.errorCode,
                      message: scanEvent.errorMessage,
                    ),
                  ),
                );
              }
            },
            onError: (Object error) => eventLifecycle.fail(
              code: 'scan_event_error',
              message: error.toString(),
            ),
            onDone: () => eventLifecycle.fail(
              code: 'scan_event_closed',
              message: 'Folder scan event stream closed before completion.',
            ),
          );
      final startResult = await _client.invoke<bool>(
        FileCacheMethod.startFolderScan,
        arguments: <String, Object?>{
          'taskId': taskId,
          'generationId': generationId,
          'folder': folderPath,
          'chunkSize': 120,
        },
        decode: (value) => value as bool,
      );
      final started = startResult.valueOrNull;
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
        'chunked_library_scan_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
    } finally {
      eventLifecycle.dispose();
      _releaseScanSubscription(subscription);
      if (!eventLifecycle.isCompleted) unawaited(_cancelFolderScan(taskId));
      if (_activeScanTaskId == taskId) _activeScanTaskId = null;
    }
  }

  Future<void> cancelActiveFolderScan() async {
    final taskId = _activeScanTaskId;
    if (taskId != null) await _cancelFolderScan(taskId);
  }

  Future<void> _cancelFolderScan(String taskId) async {
    await _client.invoke<bool>(
      FileCacheMethod.cancelFolderScan,
      arguments: <String, Object?>{'taskId': taskId},
      decode: (value) => value as bool,
    );
  }

  void _releaseScanSubscription(StreamSubscription<dynamic>? subscription) {
    if (subscription == null) return;
    unawaited(
      subscription.cancel().catchError((Object error, StackTrace stackTrace) {
        AppLogService.warning(
          'folder_scan_event_subscription_cancel_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<NativeScanResult> _scanFolderLegacy(String folderPath) async {
    try {
      final result = await _client.invoke<List<dynamic>?>(
        FileCacheMethod.scanFolder,
        arguments: <String, Object?>{'folder': folderPath},
        decode: (value) => value as List<dynamic>?,
      );
      final data = result.valueOrNull;
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

const Duration _folderScanEventInactivityTimeout = Duration(seconds: 120);

final class _FolderScanEventLifecycle {
  _FolderScanEventLifecycle({
    required Completer<NativeScanResult> completer,
    required Future<void> Function() cancelNativeScan,
  }) : _completer = completer,
       _cancelNativeScan = cancelNativeScan;

  final Completer<NativeScanResult> _completer;
  final Future<void> Function() _cancelNativeScan;
  Timer? _watchdog;
  bool _disposed = false;

  bool get isCompleted => _completer.isCompleted;

  bool complete(NativeScanResult result) {
    if (_completer.isCompleted) return false;
    _completer.complete(result);
    return true;
  }

  void markActivity() {
    if (_disposed) return;
    _watchdog?.cancel();
    _watchdog = Timer(_folderScanEventInactivityTimeout, () {
      fail(
        code: 'scan_timeout',
        message: 'Folder scan produced no events for 120 seconds.',
      );
    });
  }

  void fail({required String code, required String message}) {
    if (_disposed) return;
    _watchdog?.cancel();
    if (!complete(NativeScanResult.failed(code: code, message: message))) {
      return;
    }
    unawaited(
      _cancelNativeScan().catchError((Object error, StackTrace stackTrace) {
        AppLogService.warning(
          'folder_scan_cancel_after_event_failure_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
  }
}
