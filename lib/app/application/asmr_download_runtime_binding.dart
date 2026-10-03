import 'dart:async';

import '../../core/logging/app_log_service.dart';
import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/application/library_scan_coordinator.dart';
import '../../features/library/application/library_scan_models.dart';
import '../../features/library/application/library_state_models.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/settings/application/settings_state.dart';
import 'runtime_binding.dart';

final class AsmrDownloadRuntimeBinding implements RuntimeBinding {
  AsmrDownloadRuntimeBinding._(this._library, this._scanLabels, this._scans);

  factory AsmrDownloadRuntimeBinding.attach({
    required AsmrDownloadManager downloads,
    required SettingsRepository settings,
    required LibraryFacade library,
    required LibraryScanLabels Function() scanLabels,
    LibraryScanCoordinator? scanCoordinator,
  }) {
    final binding = AsmrDownloadRuntimeBinding._(
      library,
      scanLabels,
      scanCoordinator ?? LibraryScanCoordinator(),
    );
    void syncConcurrency() =>
        downloads.setMaxConcurrentDownloads(settings.asmrDownloadThreadCount);
    syncConcurrency();
    binding._settingsSubscription = settings.slice.stream.listen(
      (_) => syncConcurrency(),
    );
    binding._completionSubscription = downloads.completedTasks.listen((_) {
      binding._refreshPending = true;
      binding._startRefresh();
    });
    binding._librarySubscription = library.states.listen(
      (_) => binding._startRefresh(),
    );
    return binding;
  }

  final LibraryFacade _library;
  final LibraryScanLabels Function() _scanLabels;
  final LibraryScanCoordinator _scans;
  final _stopping = Completer<void>();
  late final StreamSubscription<SettingsState> _settingsSubscription;
  late final StreamSubscription<AsmrDownloadTaskSnapshot>
  _completionSubscription;
  late final StreamSubscription<LibraryState> _librarySubscription;
  bool _refreshPending = false;
  bool _disposed = false;
  int? _scanGeneration;
  Future<void>? _refreshFuture;
  Future<void>? _disposeFuture;

  void _startRefresh() {
    if (_disposed ||
        !_refreshPending ||
        _refreshFuture != null ||
        !_library.state.isInitialized) {
      return;
    }
    _refreshFuture = _refresh().whenComplete(() {
      _refreshFuture = null;
      _startRefresh();
    });
  }

  Future<void> _refresh() async {
    while (!_disposed && _refreshPending && _library.state.isInitialized) {
      if (_library.watchedFolders.isEmpty && _library.watchedLibraries.isEmpty) {
        _refreshPending = false;
        return;
      }
      // Cancellation clears the UI flag before the scanner releases its lease.
      await Future.any<void>([_library.scanIdle, _stopping.future]);
      if (_disposed || !_library.state.isInitialized) return;
      _refreshPending = false;
      if (_library.watchedFolders.isEmpty &&
          _library.watchedLibraries.isEmpty) {
        continue;
      }
      try {
        final outcome = await _scans.refresh(
          catalog: _library,
          labels: _scanLabels(),
          onScanStarted: (generation) {
            _scanGeneration = generation;
            if (_disposed) _scans.cancel(_library);
          },
        );
        if (outcome?.code == LibraryScanOutcomeCode.alreadyRunning) {
          _refreshPending = true;
        } else if (_scans.state.failure != null) {
          AppLogService.warning(
            'asmr_download_library_refresh_failed code=${outcome?.code.name}',
          );
        }
      } catch (error, stackTrace) {
        AppLogService.error(
          'asmr_download_library_refresh_failed',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        _scanGeneration = null;
      }
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _refreshPending = false;
    _stopping.complete();
    await _completionSubscription.cancel();
    await _settingsSubscription.cancel();
    await _librarySubscription.cancel();
    final generation = _scanGeneration;
    if (generation != null && _library.isScanGenerationActive(generation)) {
      _scans.cancel(_library);
    }
    await _refreshFuture;
    _scans.dispose();
  }
}
