import 'dart:async';

import '../../core/logging/app_log_service.dart';
import '../../core/platform/file_cache_platform_gateway.dart';
import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';
import 'runtime_binding.dart';

/// Reconciles Android persisted SAF grants against references owned by the
/// three runtime modules that can retain content URIs.
final class PersistedUriPermissionCoordinator implements RuntimeBinding {
  PersistedUriPermissionCoordinator.attach({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required AsmrDownloadManager downloads,
    FileCachePlatformGateway? gateway,
  }) : _library = library,
       _playback = playback,
       _downloads = downloads,
       _gateway = gateway ?? FileCachePlatformGateway.instance {
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      _library.states.listen((_) => _requestReconcile()),
      _playback.states.listen((_) => _requestReconcile()),
      _playback.persistedUriReferenceRevisions.listen(
        (_) => _requestReconcile(),
      ),
      _downloads.persistedUriReferenceRevisions.listen(
        (_) => _requestReconcile(),
      ),
    ]);
    _requestReconcile();
  }

  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final AsmrDownloadManager _downloads;
  final FileCachePlatformGateway _gateway;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  (int, int, int)? _lastSubmittedRevision;
  bool _requested = false;
  bool _running = false;
  bool _disposed = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;

  void _requestReconcile({bool resetBackoff = true}) {
    if (_disposed) return;
    if (resetBackoff) {
      _retryAttempt = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    _requested = true;
    if (!_running) unawaited(_drain());
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer != null) return;
    final exponent = _retryAttempt.clamp(0, 5);
    final delay = Duration(seconds: 1 << exponent);
    _retryAttempt += 1;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _requestReconcile(resetBackoff: false);
    });
  }

  Future<void> _drain() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (_requested && !_disposed) {
        _requested = false;
        if (!_library.persistedUriReferencesReady ||
            !_playback.persistedSessionStateReady ||
            !_downloads.persistedUriReferencesReady) {
          continue;
        }
        if (!_playback.nativeRetainedContentUriInventoryReady) {
          final refreshed = await _playback
              .refreshNativeRetainedContentUriInventory();
          if (!refreshed) {
            _scheduleRetry();
            continue;
          }
        }
        final revision = (
          _library.persistedUriReferenceRevision,
          _playback.persistedUriReferenceRevision,
          _downloads.persistedUriReferenceRevision,
        );
        if (revision == _lastSubmittedRevision) continue;
        final retainedUris = <String>{
          ..._library.persistedContentUris,
          ..._playback.persistedContentUris,
          ..._downloads.persistedContentUris,
        };
        final result = await _gateway.reconcilePersistedUriPermissions(
          retainedUris,
        );
        if (_disposed) return;
        if (result == null) {
          _scheduleRetry();
          continue;
        }
        if (result.failedUris.isNotEmpty) {
          AppLogService.warning(
            'persisted_uri_permission_reconcile_partial_failure',
            error: <String, Object?>{
              'failedUris': result.failedUris,
              'retainedCount': result.retainedCount,
              'releasedCount': result.releasedCount,
            },
          );
          _scheduleRetry();
          continue;
        }
        _lastSubmittedRevision = revision;
        _retryAttempt = 0;
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'persisted_uri_permission_reconcile_failed',
        error: error,
        stackTrace: stackTrace,
      );
      _scheduleRetry();
    } finally {
      _running = false;
      if (_requested && !_disposed) unawaited(_drain());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
