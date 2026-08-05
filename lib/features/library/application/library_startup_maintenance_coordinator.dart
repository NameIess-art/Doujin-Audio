import 'dart:async';

import '../../../core/logging/app_log_service.dart';

typedef LibraryMaintenanceIdleWaiter =
    Future<bool> Function(Duration quietWindow);
typedef LibraryPersistentImportCleanup =
    Future<void> Function(List<String> retainedPaths);
typedef LibraryEntryMaintenance = Future<void> Function(int epoch);

/// Coordinates deferred startup maintenance so it cannot race with restore or
/// runtime disposal.
final class LibraryStartupMaintenanceCoordinator {
  LibraryStartupMaintenanceCoordinator({
    required LibraryMaintenanceIdleWaiter waitForUiIdle,
    required LibraryPersistentImportCleanup cleanupOrphanedImports,
    required LibraryEntryMaintenance ensureEntries,
    LibraryEntryMaintenance? migrateAudioDetails,
  }) : _waitForUiIdle = waitForUiIdle,
       _cleanupOrphanedImports = cleanupOrphanedImports,
       _ensureEntries = ensureEntries,
       _migrateAudioDetails = migrateAudioDetails;

  static const _quietWindow = Duration(seconds: 3);

  final LibraryMaintenanceIdleWaiter _waitForUiIdle;
  final LibraryPersistentImportCleanup _cleanupOrphanedImports;
  final LibraryEntryMaintenance _ensureEntries;
  final LibraryEntryMaintenance? _migrateAudioDetails;
  Future<void>? _task;
  int _epoch = 0;
  bool _disposed = false;

  void schedule(List<String> retainedPaths) {
    if (_disposed || _task != null) return;
    final epoch = ++_epoch;
    late final Future<void> task;
    task = _run(epoch, retainedPaths).whenComplete(() {
      if (identical(_task, task)) {
        _task = null;
      }
    });
    _task = task;
  }

  Future<void> cancelAndWait() async {
    _epoch++;
    final task = _task;
    if (task != null) await task;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    final task = _task;
    if (task != null) await task;
  }

  bool isCurrent(int epoch) => _isCurrent(epoch);

  Future<void> _run(int epoch, List<String> retainedPaths) async {
    try {
      if (!await _waitForUiIdle(_quietWindow) || !_isCurrent(epoch)) return;
      await AppLogService.measureAsync(
        'library_post_startup_maintenance',
        () async {
          if (!_isCurrent(epoch)) return;
          await _cleanupOrphanedImports(retainedPaths);
          if (!_isCurrent(epoch)) return;
          await _ensureEntries(epoch);
          if (!_isCurrent(epoch)) return;
          await _migrateAudioDetails?.call(epoch);
        },
        details: <String, Object?>{'tracks': retainedPaths.length},
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'library_post_startup_maintenance_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isCurrent(int epoch) => !_disposed && epoch == _epoch;
}
