import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../core/media/audio_detail.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'audio_detail_cache_service.dart';
import 'cover_artwork_cache_service.dart';
import 'library_entry_editor_service.dart';
import 'library_persistence_coordinator.dart';
import 'library_service.dart';
import 'library_snapshot_cache_service.dart';

enum LibraryMutationRemovalKind {
  standaloneAudioPermanent,
  standaloneFolderPermanent,
  folderAudioPermanent,
  libraryPermanent,
  libraryFolderRecoverable,
  libraryAudioRecoverable,
}

final class LibraryMutationRenameResult {
  const LibraryMutationRenameResult({
    required this.detail,
    required this.renamed,
    this.backupFailed = false,
  });

  final AudioDetail detail;
  final bool renamed;
  final bool backupFailed;
}

final class LibraryMutationRenameException implements Exception {
  const LibraryMutationRenameException(this.reason);

  final String reason;
}

/// Owns destructive and recoverable library mutations and path retargeting.
final class LibraryMutationCoordinator {
  LibraryMutationCoordinator({
    required this.databaseRepository,
    required this.detailCacheService,
    required LibraryService service,
    required this.snapshotCacheService,
    required this.entryEditorService,
    required LibraryPersistenceCoordinator persistenceCoordinator,
    required CoverArtworkCacheService Function() coverArtwork,
    required bool Function() isScanning,
    required void Function() cancelScan,
    required void Function() beginLibraryBatch,
    required Future<void> Function({bool notify, bool waitForPersistence})
    endLibraryBatch,
    required List<String> Function(
      bool Function(MusicTrack track) predicate, {
      bool persist,
    })
    removeTracksMatching,
    required void Function(List<MusicTrack> tracks, {bool notify, bool persist})
    addOrReplaceTracks,
    required Future<void> Function(AudioDetailTarget target) deleteAudioDetail,
    required void Function() syncState,
  }) : _service = service,
       _persistenceCoordinator = persistenceCoordinator,
       _coverArtwork = coverArtwork,
       _isScanning = isScanning,
       _cancelScan = cancelScan,
       _beginLibraryBatch = beginLibraryBatch,
       _endLibraryBatch = endLibraryBatch,
       _removeTracksMatching = removeTracksMatching,
       _addOrReplaceTracks = addOrReplaceTracks,
       _deleteAudioDetail = deleteAudioDetail,
       _syncStateSlice = syncState;

  final LibraryPersistenceRepository databaseRepository;
  final AudioDetailCacheService detailCacheService;
  final LibraryService _service;
  final LibrarySnapshotCacheService snapshotCacheService;
  final LibraryEntryEditorService entryEditorService;
  final LibraryPersistenceCoordinator _persistenceCoordinator;
  final CoverArtworkCacheService Function() _coverArtwork;
  final bool Function() _isScanning;
  final void Function() _cancelScan;
  final void Function() _beginLibraryBatch;
  final Future<void> Function({bool notify, bool waitForPersistence})
  _endLibraryBatch;
  final List<String> Function(
    bool Function(MusicTrack track) predicate, {
    bool persist,
  })
  _removeTracksMatching;
  final void Function(List<MusicTrack> tracks, {bool notify, bool persist})
  _addOrReplaceTracks;
  final Future<void> Function(AudioDetailTarget target) _deleteAudioDetail;
  final void Function() _syncStateSlice;
  void _markStructureChanged() {
    _service.markStructureChanged();
    _coverArtwork().invalidateAll();
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
  }

  void clearLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final result = _service.clearLibraryExclusions(normalizedLibraryPath);
    if (!result.changed) return;
    if (result.restoredTracks.isNotEmpty) {
      _addOrReplaceTracks(result.restoredTracks, notify: false);
    } else {
      _syncStateSlice();
    }
    if (!_persistenceCoordinator.enabled) return;
    if (result.restoredEntryPaths.isNotEmpty) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          result.restoredEntryPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(_persistenceCoordinator.saveExclusions());
  }

  String? _watchedRootForEntity(
    Iterable<String> roots,
    String entityPath, {
    String? alternatePath,
  }) {
    for (final rootPath in roots) {
      if (PathMatcher.isWithinOrEqual(entityPath, rootPath) ||
          (alternatePath != null &&
              PathMatcher.isWithinOrEqual(alternatePath, rootPath)) ||
          _service.libraryEntryForPath(rootPath, entityPath) != null) {
        return rootPath;
      }
    }
    return null;
  }

  Future<LibraryMutationRemovalKind?> removeTrack(String trackPath) async {
    final removedTrack = _service.trackByPath(trackPath);
    if (removedTrack == null) return null;
    final libraryPath = _watchedRootForEntity(
      _service.watchedLibraries,
      removedTrack.path,
      alternatePath: removedTrack.groupKey,
    );
    if (libraryPath != null) {
      if (_service.isLibraryPathExcluded(libraryPath, removedTrack.path)) {
        return null;
      }
      excludeLibraryTrack(libraryPath, removedTrack.path);
      return LibraryMutationRemovalKind.libraryAudioRecoverable;
    }

    final folderPath = _watchedRootForEntity(
      _service.watchedFolders,
      removedTrack.path,
      alternatePath: removedTrack.groupKey,
    );
    if (folderPath != null) {
      if (_service.isLibraryPathExcluded(folderPath, removedTrack.path)) {
        return null;
      }
      excludeLibraryTrack(folderPath, removedTrack.path);
      return LibraryMutationRemovalKind.folderAudioPermanent;
    }

    final removed = await _removeTrackPermanently(removedTrack.path);
    if (!removed) return null;
    return removedTrack.isSingle
        ? LibraryMutationRemovalKind.standaloneAudioPermanent
        : LibraryMutationRemovalKind.folderAudioPermanent;
  }

  Future<bool> _removeTrackPermanently(String trackPath) async {
    final removedPaths = _removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
      persist: false,
    );
    if (removedPaths.isEmpty) return false;
    _service.syncGroupOrderFromLibrary();
    if (_persistenceCoordinator.enabled) {
      await Future.wait(<Future<void>>[
        databaseRepository.deleteTracks(removedPaths),
        _persistenceCoordinator.saveGroupOrder(),
      ]);
    }
    return true;
  }

  Future<LibraryMutationRemovalKind?> removeFolder(String folderPath) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final libraryPath = _watchedRootForEntity(
      _service.watchedLibraries,
      normalizedFolderPath,
    );
    if (libraryPath != null) {
      if (PathMatcher.equalsNormalized(libraryPath, normalizedFolderPath)) {
        final removed = await _removeLibraryPermanently(libraryPath);
        return removed ? LibraryMutationRemovalKind.libraryPermanent : null;
      }
      if (_service.isLibraryPathExcluded(libraryPath, normalizedFolderPath)) {
        return null;
      }
      excludeLibraryFolder(libraryPath, normalizedFolderPath);
      return LibraryMutationRemovalKind.libraryFolderRecoverable;
    }

    final watchedFolderPath = _watchedRootForEntity(
      _service.watchedFolders,
      normalizedFolderPath,
    );
    if (watchedFolderPath != null &&
        !PathMatcher.equalsNormalized(
          watchedFolderPath,
          normalizedFolderPath,
        )) {
      if (_service.isLibraryPathExcluded(
        watchedFolderPath,
        normalizedFolderPath,
      )) {
        return null;
      }
      excludeLibraryFolder(watchedFolderPath, normalizedFolderPath);
      return LibraryMutationRemovalKind.standaloneFolderPermanent;
    }

    final removed = await _removeFolderPermanently(normalizedFolderPath);
    return removed
        ? LibraryMutationRemovalKind.standaloneFolderPermanent
        : null;
  }

  Future<bool> _removeFolderPermanently(String folderPath) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final wasWatched = _service.watchedFolders.any(
      (folder) => PathMatcher.equalsNormalized(folder, normalizedFolderPath),
    );
    final removedPaths = _removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
      persist: false,
    );
    if (removedPaths.isEmpty && !wasWatched) return false;

    final removedWatchedFolder = _service.removeWatchedFolder(
      normalizedFolderPath,
    );
    _service.libraryEntriesByLibrary.remove(normalizedFolderPath);
    _service.syncGroupOrderFromLibrary();
    _markStructureChanged();
    final persistenceTasks = <Future<void>>[
      _deleteAudioDetail(
        AudioDetailTarget.libraryRootFolder(normalizedFolderPath),
      ),
    ];
    if (_persistenceCoordinator.enabled) {
      if (removedPaths.isNotEmpty) {
        persistenceTasks.add(databaseRepository.deleteTracks(removedPaths));
      }
      persistenceTasks.add(
        databaseRepository.deleteLibraryEntriesForLibrary(normalizedFolderPath),
      );
      if (removedWatchedFolder) {
        persistenceTasks.add(_persistenceCoordinator.saveWatchedFolders());
      }
      persistenceTasks.add(_persistenceCoordinator.saveGroupOrder());
    }
    await Future.wait(persistenceTasks);
    return true;
  }

  Future<bool> _removeLibraryPermanently(String libraryPath) async {
    if (_isScanning()) _cancelScan();
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    _beginLibraryBatch();
    final removal = _service.removeLibrary(normalizedLibraryPath);
    final removedTrackPaths = _removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedLibraryPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedLibraryPath),
      persist: false,
    );
    final changed = removal.changed || removedTrackPaths.isNotEmpty;
    if (changed) _syncStateSlice();

    final detailTargets = <AudioDetailTarget>{
      AudioDetailTarget.libraryRootFolder(normalizedLibraryPath),
      for (final folderPath in removal.removedFolderPaths)
        AudioDetailTarget.libraryRootFolder(folderPath),
    };
    final persistenceTasks = <Future<void>>[
      _endLibraryBatch(),
      _deleteRemovedLibraryPersistence(normalizedLibraryPath, detailTargets),
    ];
    if (_persistenceCoordinator.enabled) {
      if (removedTrackPaths.isNotEmpty) {
        persistenceTasks.add(
          databaseRepository.deleteTracks(removedTrackPaths),
        );
      }
      if (removal.changed) {
        persistenceTasks
          ..add(_persistenceCoordinator.saveWatchedFolders())
          ..add(_persistenceCoordinator.saveWatchedLibraries())
          ..add(_persistenceCoordinator.saveExclusions());
      }
    }
    await Future.wait(persistenceTasks);
    return changed;
  }

  Future<void> _deleteRemovedLibraryPersistence(
    String libraryPath,
    Set<AudioDetailTarget> detailTargets,
  ) async {
    await detailCacheService.deleteMany(detailTargets);
    snapshotCacheService.markDetailChanged();
    if (_persistenceCoordinator.enabled) {
      await databaseRepository.deleteLibraryEntriesForLibrary(libraryPath);
    }
    _syncStateSlice();
  }

  void excludeLibraryFolder(String libraryPath, String folderPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = _service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final mutation = _service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      true,
      onPersist: () {
        if (_persistenceCoordinator.enabled) {
          unawaited(_persistenceCoordinator.saveExclusions());
        }
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty &&
        _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
      );
    }
    _syncStateSlice();
    unawaited(
      _removeExcludedFolderFromActiveLibrary(
        normalizedLibraryPath,
        normalizedFolderPath,
      ),
    );
  }

  void excludeLibraryTrack(String libraryPath, String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final mutation = _service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      true,
      onPersist: () {
        if (_persistenceCoordinator.enabled) {
          unawaited(_persistenceCoordinator.saveExclusions());
        }
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty &&
        _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
      );
    }
    _syncStateSlice();
    unawaited(
      _removeExcludedTrackFromActiveLibrary(libraryPath, normalizedTrackPath),
    );
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    if (excluded) {
      excludeLibraryFolder(libraryPath, folderPath);
      return;
    }
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = _service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final mutation = _service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      false,
      onPersist: () {
        if (_persistenceCoordinator.enabled) {
          unawaited(_persistenceCoordinator.saveExclusions());
        }
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty &&
        _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(
      _restoreExcludedFolder(normalizedLibraryPath, normalizedFolderPath),
    );
    _syncStateSlice();
  }

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) {
    if (excluded) {
      excludeLibraryTrack(libraryPath, trackPath);
      return;
    }
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final mutation = _service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      false,
      onPersist: () {
        if (_persistenceCoordinator.enabled) {
          unawaited(_persistenceCoordinator.saveExclusions());
        }
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty &&
        _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(_restoreExcludedTrack(libraryPath, normalizedTrackPath));
    _syncStateSlice();
  }

  Future<void> _removeExcludedFolderFromActiveLibrary(
    String libraryPath,
    String folderPath,
  ) async {
    await Future<void>.value();
    if (!_service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath)) {
      return;
    }
    _beginLibraryBatch();
    _removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath),
    );
    await _endLibraryBatch(waitForPersistence: false);
  }

  Future<void> _removeExcludedTrackFromActiveLibrary(
    String libraryPath,
    String trackPath,
  ) async {
    await Future<void>.value();
    if (!_service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath)) {
      return;
    }
    _beginLibraryBatch();
    _removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
    );
    await _endLibraryBatch(waitForPersistence: false);
  }

  Future<void> _restoreExcludedTrack(
    String libraryPath,
    String trackPath,
  ) async {
    await Future<void>.value();
    if (_service.isLibraryPathExcluded(libraryPath, trackPath)) return;
    if (_service.libraryByPath.containsKey(trackPath)) return;
    final entry = _service.libraryEntryForPath(libraryPath, trackPath);
    if (entry != null && entry.isTrack && entry.isActive) {
      await _addRestoredTracks(<MusicTrack>[entry.toTrack()]);
      return;
    }
    final isContentUri = PathMatcher.isContentUri(trackPath);
    FileStat? stat;
    if (!isContentUri) {
      try {
        final file = File(trackPath);
        if (!await file.exists()) return;
        stat = await file.stat();
      } catch (_) {
        return;
      }
    }
    final parentFolder = path.dirname(trackPath);
    final folderName = path.basename(parentFolder);
    if (_service.isLibraryPathExcluded(libraryPath, trackPath)) return;
    await _addRestoredTracks(<MusicTrack>[
      MusicTrack(
        path: trackPath,
        displayName: PathDisplay.fileName(trackPath, withoutExtension: true),
        groupKey: parentFolder,
        groupTitle: folderName.isEmpty
            ? PathDisplay.folderName(parentFolder)
            : PathDisplay.normalizeDisplaySegment(folderName),
        groupSubtitle: parentFolder,
        isSingle: false,
        isVideo: isVideoMediaFile(trackPath),
        scannedAt: DateTime.now(),
        fileSizeBytes: stat?.size,
        modifiedAt: stat?.modified,
      ),
    ]);
  }

  Future<void> _restoreExcludedFolder(
    String libraryPath,
    String folderPath,
  ) async {
    await Future<void>.value();
    if (_service.isLibraryPathExcluded(libraryPath, folderPath)) return;
    final persistedTracks = _service
        .libraryEntriesForLibrary(libraryPath)
        .where(
          (entry) =>
              entry.isTrack &&
              entry.isActive &&
              PathMatcher.isWithinOrEqual(entry.path, folderPath) &&
              !_service.isLibraryPathExcluded(libraryPath, entry.path),
        )
        .map((entry) => entry.toTrack())
        .where((track) => !_service.libraryByPath.containsKey(track.path))
        .toList(growable: false);
    if (persistedTracks.isNotEmpty) {
      await _addRestoredTracks(persistedTracks);
      return;
    }

    final restoredTracks = await entryEditorService.loadRestorableTracks(
      folderPath,
    );
    final candidates = restoredTracks
        .where(
          (track) => !_service.isLibraryPathExcluded(libraryPath, track.path),
        )
        .toList(growable: false);
    if (candidates.isNotEmpty) {
      await _addRestoredTracks(candidates);
    }
  }

  Future<void> _addRestoredTracks(List<MusicTrack> tracks) async {
    if (tracks.isEmpty) return;
    _beginLibraryBatch();
    _addOrReplaceTracks(tracks, notify: false);
    await _endLibraryBatch(waitForPersistence: false);
  }

  Future<LibraryMutationRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final name = targetName.trim();
    if (name.isEmpty) {
      throw const LibraryMutationRenameException('missingTitle');
    }
    final oldTarget = detail.target;

    final safeName = PathDisplay.safeFileName(name);
    if (safeName.isEmpty) {
      throw const LibraryMutationRenameException('invalidTitle');
    }

    final oldPath = PathMatcher.normalize(oldTarget.targetPath);
    final renamedPath = await entryEditorService.renameAudioDetailTarget(
      oldTarget,
      safeName,
    );
    if (renamedPath == null) {
      throw const LibraryMutationRenameException('renameFailed');
    }
    final newPath = PathMatcher.normalize(renamedPath);
    if (PathMatcher.equalsNormalized(oldPath, newPath)) {
      return LibraryMutationRenameResult(detail: detail, renamed: false);
    }

    final newTarget = AudioDetailTarget(
      targetType: oldTarget.targetType,
      targetPath: newPath,
    );
    if (oldTarget.isLibraryRootFolder) {
      await _retargetLibraryFolder(oldPath, newPath, safeName);
    } else {
      await _retargetSingleTrack(oldPath, newPath, safeName);
    }

    final renamedDetail = detail.copyWith(
      target: newTarget,
      cardCoverPath: _retargetNullablePath(
        detail.cardCoverPath,
        oldPath,
        newPath,
      ),
    );
    final saveResult = await detailCacheService.retarget(
      oldTarget,
      renamedDetail,
    );
    snapshotCacheService.markDetailChanged(saveResult.detail);
    _syncStateSlice();
    final backupFailed = saveResult.documentFailed;
    await _deleteAudioDetail(oldTarget);
    return LibraryMutationRenameResult(
      detail: saveResult.detail,
      renamed: true,
      backupFailed: backupFailed,
    );
  }

  Future<void> _retargetLibraryFolder(
    String oldFolderPath,
    String newFolderPath,
    String folderName,
  ) async {
    await _coverArtwork().retargetFolderCoverSelection(
      oldFolderPath,
      newFolderPath,
    );
    await databaseRepository.retargetTimeSegmentLabelsWithinPath(
      oldRoot: oldFolderPath,
      newRoot: newFolderPath,
    );
    final retargetResult = _service.retargetLibraryFolder(
      oldFolderPath,
      newFolderPath,
      folderName,
    );
    _coverArtwork().invalidateFolders([oldFolderPath, newFolderPath]);
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    await databaseRepository.replaceTrackPaths(retargetResult.retargetedTracks);
    await databaseRepository.deleteLibraryEntriesForLibrary(oldFolderPath);
    if (retargetResult.retargetedEntries.isNotEmpty) {
      await databaseRepository.upsertLibraryEntries(
        retargetResult.retargetedEntries,
      );
    }
    await _persistenceCoordinator.saveWatchedFolders();
    await _persistenceCoordinator.saveWatchedLibraries();
    await _persistenceCoordinator.saveExclusions();
    await _persistenceCoordinator.saveGroupOrder();
  }

  Future<void> _retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) async {
    await databaseRepository.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize(oldTrackPath),
      newTrackKey: PathMatcher.normalize(newTrackPath),
    );
    final updatedTrack = _service.retargetSingleTrack(
      oldTrackPath,
      newTrackPath,
      displayName,
    );
    if (updatedTrack != null) {
      _coverArtwork().invalidateAll();
      snapshotCacheService.markStructureChanged();
      _syncStateSlice();
      await databaseRepository.deleteTracks([oldTrackPath]);
      await databaseRepository.upsertTracks([updatedTrack]);
    }
  }

  String? _retargetNullablePath(String? value, String oldRoot, String newRoot) {
    if (value == null || !PathMatcher.isWithinOrEqual(value, oldRoot)) {
      return value;
    }
    return PathMatcher.replaceWithinOrEqual(value, oldRoot, newRoot);
  }
}
