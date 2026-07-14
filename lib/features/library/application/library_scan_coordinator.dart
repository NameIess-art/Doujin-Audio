import 'package:flutter/foundation.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/logging/app_log_service.dart';
import 'library_catalog.dart';
import 'library_scanner_service.dart';

enum LibraryScanOperation { refresh, importFolder, importLibrary, importFiles }

enum LibraryScanPhase { idle, running, success, cancelled, failure }

@immutable
class LibraryScanState {
  const LibraryScanState({
    this.phase = LibraryScanPhase.idle,
    this.operation,
    this.outcome,
    this.failure,
  });

  final LibraryScanPhase phase;
  final LibraryScanOperation? operation;
  final LibraryScanOutcome? outcome;
  final AppFailure? failure;
}

class LibraryScanCoordinator extends ChangeNotifier {
  LibraryScanCoordinator({LibraryScannerService? scanner})
    : _scanner = scanner ?? LibraryScannerService();

  final LibraryScannerService _scanner;
  LibraryScanState _state = const LibraryScanState();

  LibraryScanState get state => _state;

  Future<LibraryScanOutcome?> refresh({
    required LibraryCatalog catalog,
    required LibraryScanLabels labels,
  }) => _run(
    operation: LibraryScanOperation.refresh,
    task: () =>
        _scanner.refreshWatchedFolders(provider: catalog, labels: labels),
  );

  Future<LibraryScanOutcome?> importFolder({
    required LibraryCatalog catalog,
    required LibraryScanLabels labels,
  }) => _run(
    operation: LibraryScanOperation.importFolder,
    task: () => _scanner.addFolder(provider: catalog, labels: labels),
  );

  Future<LibraryScanOutcome?> importLibrary({
    required LibraryCatalog catalog,
    required LibraryScanLabels labels,
  }) => _run(
    operation: LibraryScanOperation.importLibrary,
    task: () => _scanner.addLibrary(provider: catalog, labels: labels),
  );

  Future<LibraryScanOutcome?> importFiles({
    required LibraryCatalog catalog,
    required LibraryScanLabels labels,
  }) => _run(
    operation: LibraryScanOperation.importFiles,
    task: () => _scanner.addFiles(provider: catalog, labels: labels),
  );

  void cancel(LibraryCatalogWriter catalog) {
    catalog.cancelScan();
    _setState(
      LibraryScanState(
        phase: LibraryScanPhase.cancelled,
        operation: _state.operation,
      ),
    );
  }

  Future<LibraryScanOutcome?> _run({
    required LibraryScanOperation operation,
    required Future<LibraryScanOutcome?> Function() task,
  }) async {
    _setState(
      LibraryScanState(phase: LibraryScanPhase.running, operation: operation),
    );
    try {
      final outcome = await task();
      if (outcome == null) {
        _setState(const LibraryScanState());
        return null;
      }
      final phase = _phaseFor(outcome.code);
      final failure = phase == LibraryScanPhase.failure
          ? AppFailure(
              kind: AppFailureKind.scan,
              code: outcome.code.name,
              message: 'Library scan did not complete.',
              details: <String, Object?>{
                'source': outcome.source,
                ...outcome.details,
              },
            )
          : null;
      _setState(
        LibraryScanState(
          phase: phase,
          operation: operation,
          outcome: outcome,
          failure: failure,
        ),
      );
      return outcome;
    } catch (error, stackTrace) {
      AppLogService.error(
        'library_scan_operation_failed operation=${operation.name}',
        error: error,
        stackTrace: stackTrace,
      );
      final failure = AppFailure(
        kind: AppFailureKind.scan,
        code: 'scan_failed',
        message: 'Library scan failed.',
        cause: error,
        details: <String, Object?>{'operation': operation.name},
      );
      _setState(
        LibraryScanState(
          phase: LibraryScanPhase.failure,
          operation: operation,
          failure: failure,
        ),
      );
      throw failure;
    }
  }

  LibraryScanPhase _phaseFor(LibraryScanOutcomeCode code) {
    if (code == LibraryScanOutcomeCode.cancelled) {
      return LibraryScanPhase.cancelled;
    }
    if (code == LibraryScanOutcomeCode.permissionDenied ||
        code == LibraryScanOutcomeCode.failed ||
        code == LibraryScanOutcomeCode.alreadyRunning) {
      return LibraryScanPhase.failure;
    }
    return LibraryScanPhase.success;
  }

  void _setState(LibraryScanState value) {
    _state = value;
    notifyListeners();
  }
}
