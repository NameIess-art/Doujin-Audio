import 'dart:async';

import 'package:flutter/services.dart';

import '../logging/app_log_service.dart';
import 'library_scan_wire_models.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

/// Owns one native scan event session and its cancellation resources.
final class NativeFolderScanClient {
  NativeFolderScanClient({
    required PlatformMethodClient client,
    required EventChannel events,
  }) : _client = client,
       _scanEvents = events;

  final PlatformMethodClient _client;
  final EventChannel _scanEvents;
  int _scanSessionSeed = 0;
  int _scanGenerationSeed = 0;
  String? _activeScanTaskId;

  Future<NativeScanResult> scan(String folderPath) async {
    final tracks = <ScannedTrack>[];
    final result = await scanChunked(folderPath, (chunk) {
      tracks.addAll(chunk.tracks);
      return true;
    });
    if (!result.ok) return result;
    return NativeScanResult.success(
      List<ScannedTrack>.unmodifiable(tracks),
      result.paths,
      failureCount: result.failureCount,
      completenessKnown: result.completenessKnown,
      wasCancelled: result.wasCancelled,
    );
  }

  Future<NativeScanResult> scanChunked(
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
      return NativeScanResult.failed(
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
      if (started != true) return NativeScanResult.notSupported();
      return await completer.future;
    } on MissingPluginException {
      return NativeScanResult.notSupported();
    } on PlatformException catch (error) {
      if (error.code == 'notImplemented') {
        return NativeScanResult.notSupported();
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
