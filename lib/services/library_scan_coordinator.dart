import 'package:flutter/foundation.dart';

import '../i18n/app_language_provider.dart';
import 'app_failure.dart';
import 'library_catalog.dart';
import 'library_scanner_service.dart';

enum LibraryScanOperation { refresh, importFolder, importLibrary, importFiles }

enum LibraryScanPhase { idle, running, success, cancelled, failure }

@immutable
class LibraryScanState {
  const LibraryScanState({
    this.phase = LibraryScanPhase.idle,
    this.operation,
    this.message,
    this.failure,
  });

  final LibraryScanPhase phase;
  final LibraryScanOperation? operation;
  final String? message;
  final AppFailure? failure;
}

class LibraryScanCoordinator extends ChangeNotifier {
  LibraryScanCoordinator({LibraryScannerService? scanner})
    : _scanner = scanner ?? LibraryScannerService();

  final LibraryScannerService _scanner;
  LibraryScanState _state = const LibraryScanState();

  LibraryScanState get state => _state;

  Future<void> refresh({
    required LibraryCatalog catalog,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
    bool silent = false,
    bool forceShowResult = false,
  }) => _run(
    operation: LibraryScanOperation.refresh,
    i18n: i18n,
    onMessage: onMessage,
    treatSilenceAsSuccess: true,
    task: (report) => _scanner.refreshWatchedFolders(
      provider: catalog,
      i18n: i18n,
      showSnack: report,
      silent: silent,
      forceShowResult: forceShowResult,
    ),
  );

  Future<void> importFolder({
    required LibraryCatalog catalog,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
  }) => _run(
    operation: LibraryScanOperation.importFolder,
    i18n: i18n,
    onMessage: onMessage,
    task: (report) =>
        _scanner.addFolder(provider: catalog, i18n: i18n, showSnack: report),
  );

  Future<void> importLibrary({
    required LibraryCatalog catalog,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
  }) => _run(
    operation: LibraryScanOperation.importLibrary,
    i18n: i18n,
    onMessage: onMessage,
    task: (report) =>
        _scanner.addLibrary(provider: catalog, i18n: i18n, showSnack: report),
  );

  Future<void> importFiles({
    required LibraryCatalog catalog,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
  }) => _run(
    operation: LibraryScanOperation.importFiles,
    i18n: i18n,
    onMessage: onMessage,
    task: (report) =>
        _scanner.addFiles(provider: catalog, i18n: i18n, showSnack: report),
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

  Future<void> _run({
    required LibraryScanOperation operation,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
    required Future<void> Function(ValueChanged<String> report) task,
    bool treatSilenceAsSuccess = false,
  }) async {
    _setState(
      LibraryScanState(phase: LibraryScanPhase.running, operation: operation),
    );
    var reported = false;
    try {
      await task((message) {
        reported = true;
        onMessage(message);
        final phase = message == i18n.tr('scan_cancelled')
            ? LibraryScanPhase.cancelled
            : _isFailureMessage(message, i18n)
            ? LibraryScanPhase.failure
            : LibraryScanPhase.success;
        _setState(
          LibraryScanState(
            phase: phase,
            operation: operation,
            message: message,
          ),
        );
      });
      if (!reported) {
        _setState(
          LibraryScanState(
            phase: treatSilenceAsSuccess
                ? LibraryScanPhase.success
                : LibraryScanPhase.idle,
            operation: operation,
          ),
        );
      }
    } catch (error) {
      final failure = AppFailure(
        kind: AppFailureKind.scan,
        code: 'scan_failed',
        message: error.toString(),
        cause: error,
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

  bool _isFailureMessage(String message, AppLanguageProvider i18n) =>
      message == i18n.tr('scan_failed_next_step') ||
      message == i18n.tr('import_failed_next_step') ||
      message == i18n.tr('need_storage_permission_scan_folder');

  void _setState(LibraryScanState value) {
    _state = value;
    notifyListeners();
  }
}
