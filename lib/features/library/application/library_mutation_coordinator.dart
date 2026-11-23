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
import 'library_catalog_write_coordinator.dart';
import 'library_service.dart';
import 'library_snapshot_cache_service.dart';
import 'library_state_models.dart';
import 'library_track_merge.dart';

export 'library_entry_editor_service.dart' show AudioDetailRenameException;

enum LibraryRemovalKind {
  standaloneAudioPermanent,
  standaloneFolderPermanent,
  folderAudioPermanent,
  libraryPermanent,
  libraryFolderRecoverable,
  libraryAudioRecoverable,
}

class AudioDetailRenameResult {
  const AudioDetailRenameResult({
    required this.detail,
    required this.renamed,
    this.backupFailed = false,
  });

  final AudioDetail detail;
  final bool renamed;
  final bool backupFailed;
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
    required LibraryCatalogWriteCoordinator catalogWrites,
    required Future<void> Function(AudioDetailTarget target) deleteAudioDetail,
    required void Function() syncState,
  }) : _service = service,
       _persistenceCoordinator = persistenceCoordinator,
       _coverArtwork = coverArtwork,
       _catalogWrites = catalogWrites,
       _deleteAudioDetail = deleteAudioDetail,
       _syncStateSlice = syncState;

  final LibraryPersistenceRepository databaseRepository;
  final AudioDetailCacheService detailCacheService;
  final LibraryService _service;
  final LibrarySnapshotCacheService snapshotCacheService;
  final LibraryEntryEditorService entryEditorService;
  final LibraryPersistenceCoordinator _persistenceCoordinator;
  final CoverArtworkCacheService Function() _coverArtwork;
  final LibraryCatalogWriteCoordinator _catalogWrites;
  final Future<void> Function(AudioDetailTarget target) _deleteAudioDetail;
  final void Function() _syncStateSlice;
  Future<void> clearLibraryExclusions(String libraryPath) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final result = _service.clearLibraryExclusions(normalizedLibraryPath);
    if (!result.changed) return;
    _syncStateSlice();
    await Future.wait<void>([
      _addRestoredTracks(normalizedLibraryPath, result.restoredTracks),
      _persistExclusionChanges(
        normalizedLibraryPath,
        active: result.restoredEntryPaths,
      ),
    ]);
  }

  Future<void> restoreLibraryExclusions(
    LibraryExclusionSnapshot snapshot,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(snapshot.libraryPath);
    final restored = _service.restoreLibraryExclusions(snapshot);
    final matcher = _service.libraryExclusionMatcherForLibrary(
      normalizedLibraryPath,
    );
    _catalogWrites.removeTracksMatching((track) {
      if (!LibraryService.organizer.trackBelongsToLibrary(
        normalizedLibraryPath,
        track,
      )) {
        return false;
      }
      return matcher.isEntryExcluded(
        _service.libraryEntryForPath(normalizedLibraryPath, track.path),
        track.path,
      );
    }, persist: false);
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    await _persistExclusionChanges(
      normalizedLibraryPath,
      active: restored.activeEntryPaths,
      excluded: restored.excludedEntryPaths,
    );
  }

  Future<void> _persistExclusionChanges(
    String libraryPath, {
    required List<String> active,
    List<String> excluded = const [],
  }) async {
    if (!_persistenceCoordinator.enabled) return;
    if (_service.libraryBatchDepth > 0) {
      _catalogWrites.queueBatchExclusions([
        for (final path in [...active, ...excluded])
          ?_service.libraryEntryForPath(libraryPath, path),
      ]);
      return;
    }
    await Future.wait<void>([
      if (excluded.isNotEmpty)
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          excluded,
          LibraryEntryState.excluded,
        ),
      if (active.isNotEmpty)
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          active,
          LibraryEntryState.active,
        ),
      _persistenceCoordinator.saveExclusions(),
    ]);
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

  String? libraryRootForTrack(String trackPath) {
    final track = _service.trackByPath(trackPath);
    if (track == null) return null;
    return _watchedRootForEntity(
      _service.watchedLibraries,
      track.path,
      alternatePath: track.groupKey,
    );
  }

  Future<LibraryRemovalKind?> removeTrack(String trackPath) async {
    final removedTrack = _service.trackByPath(trackPath);
    if (removedTrack == null) return null;
    final libraryPath = libraryRootForTrack(trackPath);
    if (libraryPath != null) {
      if (_service.isLibraryPathExcluded(libraryPath, removedTrack.path)) {
        return null;
      }
      await excludeLibraryTrack(libraryPath, removedTrack.path);
      return LibraryRemovalKind.libraryAudioRecoverable;
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
      await excludeLibraryTrack(folderPath, removedTrack.path);
      return LibraryRemovalKind.folderAudioPermanent;
    }

    final removed = await _removeTrackPermanently(removedTrack.path);
    if (!removed) return null;
    return removedTrack.isSingle
        ? LibraryRemovalKind.standaloneAudioPermanent
        : LibraryRemovalKind.folderAudioPermanent;
  }

  Future<bool> _removeTrackPermanently(String trackPath) async {
    final removedPaths = _catalogWrites.removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
      persist: false,
    );
    if (removedPaths.isEmpty) return false;
    _service.syncGroupOrderFromLibrary();
    if (_persistenceCoordinator.enabled) {
      await Future.wait(<Future<void>>[
        databaseRepository.deleteTracks(removedPaths),
        _persistenceCoordinator.saveCatalogLists(),
      ]);
    }
    return true;
  }

  Future<LibraryRemovalKind?> removeFolder(String folderPath) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final libraryPath = _watchedRootForEntity(
      _service.watchedLibraries,
      normalizedFolderPath,
    );
    if (libraryPath != null) {
      if (PathMatcher.equalsNormalized(libraryPath, normalizedFolderPath)) {
        final removed = await _removeLibraryPermanently(libraryPath);
        return removed ? LibraryRemovalKind.libraryPermanent : null;
      }
      if (_service.isLibraryPathExcluded(libraryPath, normalizedFolderPath)) {
        return null;
      }
      await excludeLibraryFolder(libraryPath, normalizedFolderPath);
      return LibraryRemovalKind.libraryFolderRecoverable;
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
      await excludeLibraryFolder(watchedFolderPath, normalizedFolderPath);
      return LibraryRemovalKind.standaloneFolderPermanent;
    }

    final removed = await _removeFolderPermanently(normalizedFolderPath);
    return removed ? LibraryRemovalKind.standaloneFolderPermanent : null;
  }

  Future<bool> _removeFolderPermanently(String folderPath) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final wasWatched = _service.watchedFolders.contains(normalizedFolderPath);
    final retainedPaths = _service
        .libraryEntriesForLibrary(normalizedFolderPath)
        .where((entry) => entry.isTrack)
        .map((entry) => entry.path);
    final removedPaths = <String>{
      ...retainedPaths,
      ..._catalogWrites.removeTracksMatching(
        (track) =>
            PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
            PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
        persist: false,
      ),
    }.toList();
    if (removedPaths.isEmpty && !wasWatched) return false;

    final removedFolderExclusions = _service.excludedLibraryFolders.remove(
      normalizedFolderPath,
    );
    final removedTrackExclusions = _service.excludedLibraryTracks.remove(
      normalizedFolderPath,
    );
    if (removedFolderExclusions != null || removedTrackExclusions != null) {
      _service.invalidateExclusionMatcher(normalizedFolderPath);
    }
    _service.removeWatchedFolder(normalizedFolderPath);
    _service.libraryEntriesByLibrary.remove(normalizedFolderPath);
    _service.syncGroupOrderFromLibrary();
    _service.markStructureChanged();
    _coverArtwork().invalidateFolder(normalizedFolderPath);
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
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
      persistenceTasks.add(_persistenceCoordinator.saveCatalogLists());
      persistenceTasks.add(_persistenceCoordinator.saveExclusions());
    }
    await Future.wait(persistenceTasks);
    return true;
  }

  Future<bool> _removeLibraryPermanently(String libraryPath) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final retainedPaths = _service
        .libraryEntriesForLibrary(normalizedLibraryPath)
        .where((entry) => entry.isTrack)
        .map((entry) => entry.path)
        .toList();
    await _catalogWrites.beginLibraryBatch(snapshotAllEntries: false);
    _catalogWrites.rememberBatchEntriesForLibrary(normalizedLibraryPath);
    final removal = _service.removeLibrary(normalizedLibraryPath);
    final removedTrackPaths = <String>{
      ...retainedPaths,
      ..._catalogWrites.removeTracksMatching(
        (track) =>
            PathMatcher.isWithinOrEqual(track.path, normalizedLibraryPath) ||
            PathMatcher.isWithinOrEqual(track.groupKey, normalizedLibraryPath),
        persist: false,
      ),
    }.toList();
    final changed = removal.changed || removedTrackPaths.isNotEmpty;
    if (changed) _syncStateSlice();

    final detailTargets = <AudioDetailTarget>{
      AudioDetailTarget.libraryRootFolder(normalizedLibraryPath),
      for (final folderPath in removal.removedFolderPaths)
        AudioDetailTarget.libraryRootFolder(folderPath),
    };
    final persistenceTasks = <Future<void>>[
      _catalogWrites.endLibraryBatch(),
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
          ..add(_persistenceCoordinator.saveCatalogLists())
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

  Future<void> excludeLibraryFolder(
    String libraryPath,
    String folderPath,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = _service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final mutation = _service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      true,
    );
    if (!mutation.changed) return;
    final persistenceEnabled = _persistenceCoordinator.enabled;
    final writes = <Future<void>>[
      if (persistenceEnabled) _persistenceCoordinator.saveExclusions(),
      if (persistenceEnabled && mutation.affectedEntryPaths.isNotEmpty)
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
    ];
    _syncStateSlice();
    await Future.wait([
      ...writes,
      _removeExcludedFolderFromActiveLibrary(
        normalizedLibraryPath,
        normalizedFolderPath,
      ),
    ]);
  }

  Future<void> excludeLibraryTrack(String libraryPath, String trackPath) async {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final mutation = _service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      true,
    );
    if (!mutation.changed) return;
    final persistenceEnabled = _persistenceCoordinator.enabled;
    final writes = <Future<void>>[
      if (persistenceEnabled) _persistenceCoordinator.saveExclusions(),
      if (persistenceEnabled && mutation.affectedEntryPaths.isNotEmpty)
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
    ];
    _syncStateSlice();
    await Future.wait([
      ...writes,
      _removeExcludedTrackFromActiveLibrary(libraryPath, normalizedTrackPath),
    ]);
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    if (excluded) {
      unawaited(excludeLibraryFolder(libraryPath, folderPath));
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
      unawaited(excludeLibraryTrack(libraryPath, trackPath));
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
    await _catalogWrites.beginLibraryBatch(snapshotAllEntries: false);
    if (!_service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath)) {
      await _catalogWrites.endLibraryBatch();
      return;
    }
    _catalogWrites.removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath),
      persist: !_service.watchedLibraries.any(
        (root) => PathMatcher.equalsNormalized(root, libraryPath),
      ),
    );
    await _catalogWrites.endLibraryBatch();
  }

  Future<void> _removeExcludedTrackFromActiveLibrary(
    String libraryPath,
    String trackPath,
  ) async {
    await Future<void>.value();
    if (!_service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath)) {
      return;
    }
    await _catalogWrites.beginLibraryBatch(snapshotAllEntries: false);
    if (!_service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath)) {
      await _catalogWrites.endLibraryBatch();
      return;
    }
    _catalogWrites.removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
      persist: !_service.watchedLibraries.any(
        (root) => PathMatcher.equalsNormalized(root, libraryPath),
      ),
    );
    await _catalogWrites.endLibraryBatch();
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
      await _addRestoredTracks(libraryPath, <MusicTrack>[entry.toTrack()]);
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
    await _addRestoredTracks(libraryPath, <MusicTrack>[
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
              _service.isLibraryEntryWithin(entry, entry.path, folderPath) &&
              !_service.isLibraryPathExcluded(libraryPath, entry.path),
        )
        .map((entry) => entry.toTrack())
        .where((track) => !_service.libraryByPath.containsKey(track.path))
        .toList(growable: false);
    if (persistedTracks.isNotEmpty) {
      await _addRestoredTracks(libraryPath, persistedTracks);
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
      await _addRestoredTracks(libraryPath, candidates);
    }
  }

  Future<void> _addRestoredTracks(
    String libraryPath,
    List<MusicTrack> tracks,
  ) async {
    if (tracks.isEmpty) return;
    final recordedPaths = tracks
        .where(
          (track) =>
              _service.libraryEntryForPath(libraryPath, track.path) != null,
        )
        .map((track) => PathMatcher.normalize(track.path))
        .toSet();
    // Exclusion removes only the active catalog projection. SQLite keeps the
    // authored fields and playback state, including across application restarts.
    final retained = _persistenceCoordinator.enabled
        ? await databaseRepository.loadTrackDetails(
            tracks.map((track) => track.path),
          )
        : const <String, MusicTrack>{};
    final restored = [
      for (final track in tracks)
        if (retained[track.path] case final authored?)
          mergeLibraryTrackState(authored, track)
        else
          track,
    ];
    await _catalogWrites.beginLibraryBatch(snapshotAllEntries: false);
    // All reads must finish before checking the current exclusion state.
    // Another track's read can overlap a new exclusion or removal of the root.
    if (!_service.watchedLibraries.any(
          (root) => PathMatcher.equalsNormalized(root, libraryPath),
        ) &&
        !_service.watchedFolders.contains(libraryPath)) {
      await _catalogWrites.endLibraryBatch();
      return;
    }
    final active = restored.where((track) {
      final entry = _service.libraryEntryForPath(libraryPath, track.path);
      return (!recordedPaths.contains(PathMatcher.normalize(track.path)) ||
              entry != null) &&
          !_service.isLibraryPathExcluded(libraryPath, track.path);
    }).toList();
    if (active.isNotEmpty) _catalogWrites.addOrReplaceTracks(active);
    await _catalogWrites.endLibraryBatch();
  }

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final name = targetName.trim();
    if (name.isEmpty) {
      throw const AudioDetailRenameException('missingTitle');
    }
    final oldTarget = detail.target;

    final safeName = PathDisplay.safeFileName(name);
    if (safeName.isEmpty) {
      throw const AudioDetailRenameException('invalidTitle');
    }

    final oldPath = PathMatcher.normalize(oldTarget.targetPath);
    final renamedPath = await entryEditorService.renameAudioDetailTarget(
      oldTarget,
      safeName,
      beforeLocalRename: (source, destination) => _checkRenameDestination(
        source,
        destination,
        isDirectory: oldTarget.isLibraryRootFolder,
      ),
    );
    if (renamedPath == null) {
      throw const AudioDetailRenameException('renameFailed');
    }
    final newPath = PathMatcher.normalize(renamedPath);
    if (oldPath == newPath) {
      return AudioDetailRenameResult(detail: detail, renamed: false);
    }

    final newTarget = AudioDetailTarget(
      targetType: oldTarget.targetType,
      targetPath: newPath,
    );
    if (oldTarget.isLibraryRootFolder) {
      await _retargetLibraryFolder(
        libraryRootPath: oldPath,
        oldFolderPath: oldPath,
        newFolderPath: newPath,
        folderName: safeName,
      );
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
    return AudioDetailRenameResult(
      detail: saveResult.detail,
      renamed: true,
      backupFailed: backupFailed,
    );
  }

  Future<String> renameWorkEntryToName({
    required String libraryRootPath,
    required String entryPath,
    required String targetName,
    required bool isMedia,
    required bool isDirectory,
  }) async {
    final rootPath = PathMatcher.normalize(libraryRootPath);
    final rawOldPath = PathMatcher.normalize(entryPath);
    final oldPath = !isDirectory && isMedia
        ? PathMatcher.normalize(
            _service.trackByPath(rawOldPath)?.path ?? rawOldPath,
          )
        : rawOldPath;
    if (PathMatcher.equalsNormalized(rootPath, oldPath) ||
        !PathMatcher.isWithinOrEqual(oldPath, rootPath)) {
      throw const AudioDetailRenameException('invalidTarget');
    }
    final safeName = PathDisplay.safeFileName(targetName.trim());
    if (safeName.isEmpty) {
      throw const AudioDetailRenameException('invalidTitle');
    }
    final renamedPath = await entryEditorService.renameEntry(
      oldPath,
      safeName,
      isDirectory: isDirectory,
      beforeLocalRename: isMedia || isDirectory
          ? (source, destination) => _checkRenameDestination(
              source,
              destination,
              isDirectory: isDirectory,
            )
          : null,
    );
    if (renamedPath == null) {
      throw const AudioDetailRenameException('renameFailed');
    }
    final newPath = PathMatcher.normalize(renamedPath);
    if (oldPath == newPath) return newPath;

    if (isDirectory) {
      await _retargetLibraryFolder(
        libraryRootPath: rootPath,
        oldFolderPath: oldPath,
        newFolderPath: newPath,
        folderName: safeName,
      );
    } else if (isMedia) {
      await _retargetSingleTrack(oldPath, newPath, safeName);
    } else {
      await _retargetManualCoverFile(
        libraryRootPath: rootPath,
        oldFilePath: oldPath,
        newFilePath: newPath,
      );
      _coverArtwork().invalidateFolder(rootPath);
      snapshotCacheService.markStructureChanged();
      _syncStateSlice();
    }
    return newPath;
  }

  Future<void> _retargetManualCoverFile({
    required String libraryRootPath,
    required String oldFilePath,
    required String newFilePath,
  }) async {
    final covers = _coverArtwork();
    await covers.retargetFolderCoverSelection(oldFilePath, newFilePath);
    final target = AudioDetailTarget.libraryRootFolder(libraryRootPath);
    final detail = (await detailCacheService.load(target)).detail;
    final currentCoverPath = detail.cardCoverPath;
    if (currentCoverPath == null || currentCoverPath.isEmpty) return;
    final resolvedCoverSource = covers.sourcePathForFolderImage(
      currentCoverPath,
    );
    if (!PathMatcher.equalsNormalized(currentCoverPath, oldFilePath) &&
        !PathMatcher.equalsNormalized(resolvedCoverSource, oldFilePath)) {
      return;
    }
    final saveResult = await detailCacheService.save(
      detail.copyWith(cardCoverPath: newFilePath),
    );
    snapshotCacheService.markDetailChanged(saveResult.detail);
  }

  Future<void> _checkRenameDestination(
    String source,
    String destination, {
    required bool isDirectory,
  }) async {
    if (!isDirectory) {
      final existingTrack = _service.libraryByPath[destination];
      if (existingTrack != null &&
          !PathMatcher.equalsNormalized(existingTrack.path, source)) {
        throw const AudioDetailRenameException('nameConflict');
      }
      for (final entries in _service.libraryEntriesByLibrary.values) {
        final existingEntry = entries[destination];
        if (existingEntry != null &&
            !PathMatcher.equalsNormalized(existingEntry.path, source)) {
          throw const AudioDetailRenameException('nameConflict');
        }
      }
      if (_persistenceCoordinator.enabled) {
        final persistedTrack = await databaseRepository.loadTrackDetail(
          destination,
        );
        if (persistedTrack != null &&
            !PathMatcher.equalsNormalized(persistedTrack.path, source)) {
          throw const AudioDetailRenameException('nameConflict');
        }
      }
      return;
    }

    bool conflicts(String candidate) =>
        PathMatcher.isWithinOrEqual(candidate, destination) &&
        !PathMatcher.isWithinOrEqual(candidate, source);

    if (_service.libraryByPath[destination] != null &&
        !PathMatcher.isWithinOrEqual(destination, source)) {
      throw const AudioDetailRenameException('nameConflict');
    }
    if (_service.watchedFolders.any(conflicts) ||
        _service.watchedLibraries.any(conflicts) ||
        _service.library.any((track) => conflicts(track.path))) {
      throw const AudioDetailRenameException('nameConflict');
    }
    for (final entry in _service.libraryEntriesByLibrary.entries) {
      final root = entry.key;
      if (!PathMatcher.isWithinOrEqual(destination, root) &&
          !PathMatcher.isWithinOrEqual(root, destination)) {
        continue;
      }
      if (entry.value.containsKey(destination) &&
          !PathMatcher.isWithinOrEqual(destination, source)) {
        throw const AudioDetailRenameException('nameConflict');
      }
      if (entry.value.keys.any(conflicts)) {
        throw const AudioDetailRenameException('nameConflict');
      }
    }
  }

  Future<void> _retargetLibraryFolder({
    required String libraryRootPath,
    required String oldFolderPath,
    required String newFolderPath,
    required String folderName,
  }) async {
    await _coverArtwork().retargetFolderCoverSelection(
      oldFolderPath,
      newFolderPath,
    );
    await databaseRepository.retargetTimeSegmentLabelsWithinPath(
      oldRoot: oldFolderPath,
      newRoot: newFolderPath,
    );
    if (!PathMatcher.equalsNormalized(libraryRootPath, oldFolderPath)) {
      final target = AudioDetailTarget.libraryRootFolder(libraryRootPath);
      final detail = (await detailCacheService.load(target)).detail;
      final nextCoverPath = _retargetNullablePath(
        detail.cardCoverPath,
        oldFolderPath,
        newFolderPath,
      );
      if (nextCoverPath != detail.cardCoverPath) {
        final saveResult = await detailCacheService.save(
          detail.copyWith(cardCoverPath: nextCoverPath),
        );
        snapshotCacheService.markDetailChanged(saveResult.detail);
        _syncStateSlice();
      }
    }
    final entriesRoot =
        _service.libraryRootForPath(oldFolderPath) ?? libraryRootPath;
    final retainedTracks = <MusicTrack>[];
    if (_persistenceCoordinator.enabled) {
      final excludedTrackPaths = <String>[
        for (final entry in _service.libraryEntriesForLibrary(entriesRoot))
          if (entry.isTrack &&
              _service.trackByPath(entry.path) == null &&
              PathMatcher.isWithinOrEqual(entry.path, oldFolderPath))
            entry.path,
      ];
      if (excludedTrackPaths.isNotEmpty) {
        final loaded = await databaseRepository.loadTrackDetails(
          excludedTrackPaths,
        );
        retainedTracks.addAll(loaded.values);
      }
    }
    final retargetResult = _service.retargetLibraryFolder(
      oldFolderPath,
      newFolderPath,
      folderName,
      libraryRootPath: entriesRoot,
      retainedTracks: retainedTracks,
    );
    _coverArtwork().invalidateFolders([oldFolderPath, newFolderPath]);
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    if (_persistenceCoordinator.enabled) {
      await databaseRepository.replaceTrackPaths(
        retargetResult.retargetedTracks,
      );
      final rootRenamed = PathMatcher.equalsNormalized(
        entriesRoot,
        oldFolderPath,
      );
      final removedEntryPaths = <String>[
        ...retargetResult.removedEntryPaths,
        if (rootRenamed)
          for (final track in retargetResult.retargetedTracks.values)
            track.path,
      ];
      if (removedEntryPaths.isNotEmpty ||
          retargetResult.retargetedEntries.isNotEmpty) {
        await databaseRepository.commitLibraryBatch(
          tracks: const <MusicTrack>[],
          entries: retargetResult.retargetedEntries,
          catalogSettings: const <String, String>{},
          removedEntryPaths: removedEntryPaths.isEmpty
              ? const <String, List<String>>{}
              : <String, List<String>>{entriesRoot: removedEntryPaths},
        );
      }
    }
    await _persistenceCoordinator.saveCatalogLists();
    await _persistenceCoordinator.saveExclusions();
  }

  Future<void> _retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) async {
    String? storedEntryPath;
    for (final entries in _service.libraryEntriesByLibrary.values) {
      final entry = entries[oldTrackPath];
      if (entry != null) {
        storedEntryPath = entry.path;
        break;
      }
    }
    await databaseRepository.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize(
        _service.trackByPath(oldTrackPath)?.path ??
            storedEntryPath ??
            oldTrackPath,
      ),
      newTrackKey: PathMatcher.normalize(newTrackPath),
    );
    final retainedTrack =
        _persistenceCoordinator.enabled &&
            _service.trackByPath(oldTrackPath) == null
        ? await databaseRepository.loadTrackDetail(
            storedEntryPath ?? oldTrackPath,
          )
        : null;
    final retargetResult = _service.retargetSingleTrack(
      oldTrackPath,
      newTrackPath,
      displayName,
      retainedTrack: retainedTrack,
    );
    _coverArtwork().invalidateAll();
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    if (_persistenceCoordinator.enabled) {
      if (retargetResult.updatedTrack != null) {
        await databaseRepository.replaceTrackPaths({
          retargetResult.originalTrackPath ?? oldTrackPath:
              retargetResult.updatedTrack!,
        });
      } else if (retargetResult.retargetedEntries.isNotEmpty) {
        await databaseRepository.commitLibraryBatch(
          tracks: const [],
          entries: retargetResult.retargetedEntries,
          catalogSettings: const {},
          removedEntryPaths: retargetResult.removedEntryPathsByLibrary,
        );
      }
      await _persistenceCoordinator.saveExclusions();
    }
  }

  String? _retargetNullablePath(String? value, String oldRoot, String newRoot) {
    if (value == null || !PathMatcher.isWithinOrEqual(value, oldRoot)) {
      return value;
    }
    return PathMatcher.replaceWithinOrEqual(value, oldRoot, newRoot);
  }
}
