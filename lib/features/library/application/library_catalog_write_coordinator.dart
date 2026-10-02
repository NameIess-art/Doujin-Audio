import 'dart:async';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import 'cover_artwork_cache_service.dart';
import 'library_snapshot_cache_service.dart';
import 'library_persistence_coordinator.dart';
import 'library_service.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_state_models.dart';

/// Applies catalog writes to the single LibraryService state and its batches.
final class LibraryCatalogWriteCoordinator {
  LibraryCatalogWriteCoordinator({
    required LibraryService service,
    required this.databaseRepository,
    required this.snapshotCacheService,
    required LibraryPersistenceCoordinator persistenceCoordinator,
    required CoverArtworkCacheService? Function() coverArtwork,
    required void Function() syncState,
  }) : _service = service,
       _persistenceCoordinator = persistenceCoordinator,
       _coverArtwork = coverArtwork,
       _syncStateSlice = syncState;
  final LibraryService _service;
  final LibraryPersistenceRepository databaseRepository;
  final LibrarySnapshotCacheService snapshotCacheService;
  final LibraryPersistenceCoordinator _persistenceCoordinator;
  final CoverArtworkCacheService? Function() _coverArtwork;
  final void Function() _syncStateSlice;
  void Function(List<String>)? _trackRemovalHandler;
  void attachTrackRemovalHandler(void Function(List<String>) handler) {
    _trackRemovalHandler ??= handler;
  }

  void detachRuntimeHandlers() {
    _trackRemovalHandler = null;
  }

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _service.addWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_persistenceCoordinator.saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _service.addWatchedLibrary(
      folderPath,
      onPersist: () =>
          unawaited(_persistenceCoordinator.saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _service.removeWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_persistenceCoordinator.saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _service.removeWatchedLibrary(
      folderPath,
      onPersist: () =>
          unawaited(_persistenceCoordinator.saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {
    var entries = _service.buildLibraryEntries(
      libraryPath,
      tracks,
      folderPaths: folderPaths,
      exclusionMatcher: exclusionMatcher,
    );
    if (entrySnapshot != null) {
      entries = entries
          .where(entrySnapshot.entryNeedsRefresh)
          .toList(growable: false);
    }
    if (entries.isEmpty) return;
    _service.replaceLibraryEntries(entries);
    entrySnapshot?.remember(entries);
    _persistenceCoordinator.queueOrPersistEntries(entries, persist: persist);
  }

  void recordEntriesForTracks(List<MusicTrack> tracks, {bool persist = true}) {
    final entries = <LibraryEntry>[];
    final tracksByLibrary = <String, List<MusicTrack>>{};
    for (final track in tracks) {
      final libraryPath = _service.libraryPathForTrack(track);
      if (libraryPath == null || libraryPath.isEmpty) continue;
      tracksByLibrary.putIfAbsent(libraryPath, () => <MusicTrack>[]).add(track);
    }
    for (final entry in tracksByLibrary.entries) {
      entries.addAll(_service.buildLibraryEntries(entry.key, entry.value));
    }
    if (entries.isEmpty) return;
    _service.replaceLibraryEntries(entries);
    _persistenceCoordinator.queueOrPersistEntries(entries, persist: persist);
  }

  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = _service.addTracks(tracks, persist: persist);
    if (mutation.tracks.isEmpty) return;
    recordEntriesForTracks(mutation.tracks, persist: persist);
    _coverArtwork()?.invalidateCatalogTracks(mutation.tracks);
    if (mutation.batched) return;
    _markLibraryStructureChanged();
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder) {
        unawaited(_persistenceCoordinator.saveGroupOrder());
      }
    }
  }

  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
    bool mergeExistingState = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = _service.addOrReplaceTracks(
      tracks,
      persist: persist,
      mergeExistingState: mergeExistingState,
    );
    if (mutation.tracks.isEmpty) return;
    recordEntriesForTracks(mutation.tracks, persist: persist);
    _coverArtwork()?.invalidateCatalogTracks(mutation.tracks);
    if (mutation.batched) return;
    _markLibraryStructureChanged();
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder || mutation.didReplaceGroup) {
        unawaited(_persistenceCoordinator.saveGroupOrder());
      }
    }
  }

  void _markLibraryStructureChanged() {
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
  }

  List<String> removeTracksMatching(
    bool Function(MusicTrack track) test, {
    bool persist = true,
  }) {
    final mutation = _service.removeTracksWhere(test);
    final removedPaths = mutation.tracks
        .map((track) => track.path)
        .toList(growable: false);
    if (removedPaths.isEmpty) return const <String>[];
    _coverArtwork()?.invalidateCatalogTracks(mutation.tracks);
    _trackRemovalHandler?.call(removedPaths);
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.deleteTracks(removedPaths));
    }
    if (!mutation.batched) {
      _markLibraryStructureChanged();
    }
    return removedPaths;
  }

  void removeTracksByPath(Iterable<String> trackPaths) {
    final paths = trackPaths.toSet();
    if (paths.isEmpty) return;
    removeTracksMatching((track) => paths.contains(track.path));
  }

  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final scannedPathIndex = PathMembershipIndex(scannedPaths);
    removeTracksMatching((track) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        track.path,
        normalizedFolder,
      )) {
        return false;
      }
      return !scannedPathIndex.containsEquivalent(track.path);
    });
  }

  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {
    final removedPaths = _service.removeLibraryEntriesMissingFromFolderScan(
      libraryPath,
      folderPath,
      retainedPaths,
    );
    if (removedPaths.isNotEmpty && _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {
    final removedPaths = _service.removeLibraryEntriesByPaths(
      libraryPath,
      entryPaths,
    );
    if (removedPaths.isNotEmpty && _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  void beginLibraryBatch() {
    if (_service.libraryBatchDepth == 0) {
      _service.libraryDerivedGeneration++;
    }
    _service.libraryBatchDepth++;
  }

  void beginStagedLibraryRefresh() {
    beginLibraryBatch();
  }

  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) {
    for (final folderPath in removeWatchedFolders) {
      removeWatchedFolder(folderPath, notify: false);
    }
    if (tracks.isNotEmpty || folderPaths.isNotEmpty) {
      recordLibraryEntriesForTracks(
        libraryRoot,
        tracks,
        folderPaths: folderPaths,
        persist: persist,
      );
    }
    for (final folderPath in addWatchedFolders) {
      addWatchedFolder(folderPath, notify: false);
    }
    final beforeCount = _service.library.length;
    if (tracks.isNotEmpty) {
      addOrReplaceTracks(tracks, notify: false, persist: persist);
    }
    final tracksToRemove = removeTrackPaths.toList(growable: false);
    if (tracksToRemove.isNotEmpty) removeTracksByPath(tracksToRemove);
    final entriesToRemove = removeEntryPaths.toList(growable: false);
    if (entriesToRemove.isNotEmpty) {
      removeLibraryEntriesByPaths(libraryRoot, entriesToRemove);
    }
    return _service.library.length - beforeCount;
  }

  Future<void> finishStagedLibraryRefresh({bool waitForPersistence = false}) {
    return endLibraryBatch(waitForPersistence: waitForPersistence);
  }

  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) async {
    if (_service.libraryBatchDepth <= 0) return;
    _service.libraryBatchDepth--;
    if (_service.libraryBatchDepth > 0) return;

    final didChangeLibrary = _service.libraryBatchChanged;
    final entriesToPersist = List<LibraryEntry>.from(
      _service.libraryBatchPersistEntriesByKey.values,
    );
    if (!didChangeLibrary && entriesToPersist.isEmpty) return;
    final tracksToPersist = List<MusicTrack>.from(
      _service.libraryBatchPersistTracks,
    );
    final didChangeGroupOrder = _service.libraryBatchChangedGroupOrder;
    _service
      ..libraryBatchChanged = false
      ..libraryBatchChangedGroupOrder = false
      ..libraryBatchPersistTracks.clear()
      ..libraryBatchPersistEntriesByKey.clear();

    if (didChangeLibrary) {
      _service.syncGroupOrderFromLibrary();
      final derivedGeneration = ++_service.libraryDerivedGeneration;
      final derivedSnapshot = await snapshotCacheService.buildDerivedSnapshot();
      if (derivedGeneration == _service.libraryDerivedGeneration) {
        _service
          ..library = List<MusicTrack>.of(derivedSnapshot.library)
          ..libraryByPath = Map<String, MusicTrack>.of(
            derivedSnapshot.libraryByPath,
          )
          ..libraryIndexByPath = Map<String, int>.of(
            derivedSnapshot.libraryIndexByPath,
          )
          ..tracksByGroup = Map<String, List<MusicTrack>>.of(
            derivedSnapshot.tracksByGroup,
          )
          ..sortedLibraryTracks = derivedSnapshot.sortedLibraryTracks
          ..sortedLibraryTrackPaths = derivedSnapshot.sortedLibraryTrackPaths
          ..markStructureChanged();
        snapshotCacheService
          ..markStructureChanged()
          ..adoptCardSnapshot(derivedSnapshot.cardSnapshot);
        _syncStateSlice();
      }
    }

    final persistenceTasks = <Future<void>>[];
    if (_persistenceCoordinator.enabled) {
      if (tracksToPersist.isNotEmpty) {
        persistenceTasks.add(databaseRepository.upsertTracks(tracksToPersist));
      }
      if (entriesToPersist.isNotEmpty) {
        persistenceTasks.add(
          databaseRepository.upsertLibraryEntries(entriesToPersist),
        );
      }
      if (didChangeLibrary && didChangeGroupOrder) {
        persistenceTasks.add(_persistenceCoordinator.saveGroupOrder());
      }
    }
    if (waitForPersistence) {
      await Future.wait(persistenceTasks);
    } else {
      for (final task in persistenceTasks) {
        unawaited(task);
      }
    }
  }
}
