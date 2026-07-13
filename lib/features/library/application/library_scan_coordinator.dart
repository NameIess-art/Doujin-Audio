import 'package:flutter/foundation.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../core/errors/app_failure.dart';
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
    shouldReport: (outcome) =>
        !silent ||
        forceShowResult ||
        outcome.code == LibraryScanOutcomeCode.refreshAdded,
    task: () => _scanner.refreshWatchedFolders(
      provider: catalog,
      labels: _labels(i18n),
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
    task: () => _scanner.addFolder(provider: catalog, labels: _labels(i18n)),
  );

  Future<void> importLibrary({
    required LibraryCatalog catalog,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
  }) => _run(
    operation: LibraryScanOperation.importLibrary,
    i18n: i18n,
    onMessage: onMessage,
    task: () => _scanner.addLibrary(provider: catalog, labels: _labels(i18n)),
  );

  Future<void> importFiles({
    required LibraryCatalog catalog,
    required AppLanguageProvider i18n,
    required ValueChanged<String> onMessage,
  }) => _run(
    operation: LibraryScanOperation.importFiles,
    i18n: i18n,
    onMessage: onMessage,
    task: () => _scanner.addFiles(provider: catalog, labels: _labels(i18n)),
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
    required Future<LibraryScanOutcome?> Function() task,
    bool Function(LibraryScanOutcome outcome)? shouldReport,
  }) async {
    _setState(
      LibraryScanState(phase: LibraryScanPhase.running, operation: operation),
    );
    try {
      final outcome = await task();
      if (outcome == null) {
        _setState(const LibraryScanState());
        return;
      }
      final message = _messageFor(outcome, i18n);
      final phase = _phaseFor(outcome.code);
      final failure = phase == LibraryScanPhase.failure
          ? AppFailure(
              kind: AppFailureKind.scan,
              code: outcome.code.name,
              message: message,
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
          message: message,
          failure: failure,
        ),
      );
      if (message.isNotEmpty && (shouldReport?.call(outcome) ?? true)) {
        onMessage(message);
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

  LibraryScanLabels _labels(AppLanguageProvider i18n) => LibraryScanLabels(
    chooseMusicFolder: i18n.tr('choose_music_folder'),
    chooseLibraryFolder: i18n.tr('choose_library_folder'),
    chooseAudioFiles: i18n.tr('choose_audio_files'),
    importedFiles: i18n.tr('imported_files'),
    manuallySelectedFiles: i18n.tr('manually_selected_files'),
  );

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

  String _messageFor(LibraryScanOutcome outcome, AppLanguageProvider i18n) =>
      switch (outcome.code) {
        LibraryScanOutcomeCode.noSources => '',
        LibraryScanOutcomeCode.permissionDenied => i18n.tr(
          'need_storage_permission_scan_folder',
        ),
        LibraryScanOutcomeCode.alreadyRunning => i18n.tr('scanning_title'),
        LibraryScanOutcomeCode.folderExists => i18n.tr('library_folder_exists'),
        LibraryScanOutcomeCode.libraryExists => i18n.tr('library_exists'),
        LibraryScanOutcomeCode.fileExists => i18n.tr('library_file_exists'),
        LibraryScanOutcomeCode.cancelled => i18n.tr('scan_cancelled'),
        LibraryScanOutcomeCode.failed => i18n.tr('scan_failed_next_step'),
        LibraryScanOutcomeCode.noAudio => i18n.tr('no_audio_found'),
        LibraryScanOutcomeCode.refreshAdded => i18n.tr('refresh_done_added', {
          'count': outcome.addedCount,
        }),
        LibraryScanOutcomeCode.refreshNoChanges => i18n.tr(
          'refresh_done_no_new',
        ),
        LibraryScanOutcomeCode.importAdded => i18n.tr('import_done_added', {
          'count': outcome.addedCount,
        }),
        LibraryScanOutcomeCode.libraryImported => i18n.tr(
          'import_library_done',
          <String, Object?>{
            'count': outcome.addedCount,
            'folderCount': outcome.folderCount,
          },
        ),
      };

  void _setState(LibraryScanState value) {
    _state = value;
    notifyListeners();
  }
}
