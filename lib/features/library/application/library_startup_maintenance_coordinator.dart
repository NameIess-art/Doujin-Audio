import '../../../core/media/path_matcher.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_service.dart';
import 'library_metadata_coordinator.dart';
import 'cover_artwork_cache_service.dart';
import 'dart:async';

import '../../../core/logging/app_log_service.dart';

typedef LibraryMaintenanceIdleWaiter =
    Future<bool> Function(Duration quietWindow);
typedef LibraryPersistentImportCleanup =
    Future<void> Function(List<String> retainedPaths);
typedef LibraryEntryMaintenance = Future<void> Function(int epoch);
typedef LibraryDurationMaintenance = Future<void> Function();
typedef LibraryCoverCacheMigration = Future<void> Function(int epoch);

/// Coordinates deferred startup maintenance so it cannot race with restore or
/// runtime disposal.
final class LibraryStartupMaintenanceCoordinator {
  LibraryStartupMaintenanceCoordinator({
    required LibraryMaintenanceIdleWaiter waitForUiIdle,
    required LibraryPersistentImportCleanup cleanupOrphanedImports,
    required LibraryEntryMaintenance ensureEntries,
    LibraryCoverCacheMigration? migrateCoverCache,
    LibraryEntryMaintenance? migrateAudioDetails,
    LibraryDurationMaintenance? backfillDurations,
  }) : _waitForUiIdle = waitForUiIdle,
       _cleanupOrphanedImports = cleanupOrphanedImports,
       _ensureEntries = ensureEntries,
       _migrateCoverCache = migrateCoverCache,
       _migrateAudioDetails = migrateAudioDetails,
       _backfillDurations = backfillDurations;

  factory LibraryStartupMaintenanceCoordinator.forLibrary({
    required LibraryMaintenanceIdleWaiter waitForUiIdle,
    required LibraryPersistentImportCleanup cleanupOrphanedImports,
    required LibraryService libraryService,
    required LibraryPersistenceRepository repository,
    required LibraryMetadataCoordinator metadataCoordinator,
    required CoverArtworkCacheService Function() coverArtwork,
  }) {
    late final LibraryStartupMaintenanceCoordinator coordinator;
    coordinator = LibraryStartupMaintenanceCoordinator(
      waitForUiIdle: waitForUiIdle,
      cleanupOrphanedImports: cleanupOrphanedImports,
      ensureEntries: (epoch) => coordinator._ensureEntriesForLoadedTracks(
        epoch,
        libraryService,
        repository,
      ),
      migrateAudioDetails: (epoch) =>
          coordinator._importAudioDetailDocumentsOnce(
            epoch,
            repository,
            metadataCoordinator,
          ),
      migrateCoverCache: (epoch) =>
          coordinator._migrateCoverCacheOnce(epoch, repository, coverArtwork()),
      backfillDurations: metadataCoordinator.backfillMissingDurations,
    );
    return coordinator;
  }

  static const _audioDetailDocumentImportKey =
      'audio_detail_document_read_only_import_v2';
  static const _coverCacheMigrationKey = 'cover_artwork_cache_migration_v1';

  static const _quietWindow = Duration(seconds: 3);

  final LibraryMaintenanceIdleWaiter _waitForUiIdle;
  final LibraryPersistentImportCleanup _cleanupOrphanedImports;
  final LibraryEntryMaintenance _ensureEntries;
  final LibraryCoverCacheMigration? _migrateCoverCache;
  final LibraryEntryMaintenance? _migrateAudioDetails;
  final LibraryDurationMaintenance? _backfillDurations;
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
          await _migrateCoverCache?.call(epoch);
          if (!_isCurrent(epoch)) return;
          await _ensureEntries(epoch);
          if (!_isCurrent(epoch)) return;
          await _migrateAudioDetails?.call(epoch);
          if (!_isCurrent(epoch)) return;
          await _backfillDurations?.call();
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
  Future<void> _ensureEntriesForLoadedTracks(
    int epoch,
    LibraryService libraryService,
    LibraryPersistenceRepository repository,
  ) async {
    if (!_isCurrent(epoch)) return;
    final knownLibraries = <String>{
      ...libraryService.watchedLibraries,
      ...libraryService.watchedFolders,
    };
    if (knownLibraries.isEmpty || libraryService.library.isEmpty) return;
    final entriesToPersist = <LibraryEntry>[];
    for (final libraryPath in knownLibraries) {
      if (libraryService.hasLibraryEntriesForLibrary(libraryPath)) continue;
      final tracks = libraryService.library
          .where(
            (track) =>
                PathMatcher.isWithinOrEqual(track.path, libraryPath) ||
                PathMatcher.isWithinOrEqual(track.groupKey, libraryPath),
          )
          .toList(growable: false);
      if (tracks.isEmpty) continue;
      entriesToPersist.addAll(
        libraryService.buildLibraryEntries(libraryPath, tracks),
      );
    }
    if (entriesToPersist.isEmpty) return;
    if (!_isCurrent(epoch)) return;
    libraryService.replaceLibraryEntries(entriesToPersist);
    await repository.upsertLibraryEntries(entriesToPersist);
  }

  Future<void> _importAudioDetailDocumentsOnce(
    int epoch,
    LibraryPersistenceRepository repository,
    LibraryMetadataCoordinator metadataCoordinator,
  ) async {
    if (!_isCurrent(epoch)) return;
    final completed = await repository.loadAppSetting(
      _audioDetailDocumentImportKey,
    );
    if (completed == '1') return;
    await metadataCoordinator.importBackups();
    if (!_isCurrent(epoch)) return;
    await repository.saveAppSetting(_audioDetailDocumentImportKey, '1');
  }

  Future<void> _migrateCoverCacheOnce(
    int epoch,
    LibraryPersistenceRepository repository,
    CoverArtworkCacheService coverArtwork,
  ) async {
    if (!_isCurrent(epoch)) return;
    final completed = await repository.loadAppSetting(_coverCacheMigrationKey);
    if (completed == '1') return;
    await coverArtwork.migrateLegacyCaches(
      shouldCancel: () => !_isCurrent(epoch),
    );
    if (!_isCurrent(epoch)) return;
    await repository.saveAppSetting(_coverCacheMigrationKey, '1');
  }
}
