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
  _LibraryBatchSnapshot? _batchBefore;
  final _refreshTrackWrites = <String, MusicTrack>{};
  final _refreshEntryWrites = <String, Map<String, LibraryEntry>>{};
  final _refreshRemovedTracks = <String, MusicTrack>{};
  final _refreshRemovedEntries = <String, Map<String, LibraryEntry>>{};
  final _refreshFolderWrites = <String, bool>{};
  bool _stagedRefresh = false;
  final _removedTrackPaths = <String>{};
  final _removedEntryPaths = <String, Set<String>>{};
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
    bool refreshWrite = false,
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
    if (refreshWrite) {
      for (final entry in entries) {
        _refreshEntryWrites.putIfAbsent(
          PathMatcher.normalize(entry.libraryPath),
          () => <String, LibraryEntry>{},
        )[PathMatcher.normalize(entry.path)] = _service.libraryEntryForPath(
          entry.libraryPath,
          entry.path,
        )!;
      }
    }
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
    if (mutation.batched) return;
    _coverArtwork()?.invalidateCatalogTracks(mutation.tracks);
    _markLibraryStructureChanged();
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.upsertCatalogTracks(mutation.tracks));
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
    bool recordEntries = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = _service.addOrReplaceTracks(
      tracks,
      persist: persist,
      mergeExistingState: mergeExistingState,
    );
    if (mutation.tracks.isEmpty) return;
    if (recordEntries) {
      recordEntriesForTracks(mutation.tracks, persist: persist);
    }
    if (mutation.batched) return;
    _coverArtwork()?.invalidateCatalogTracks(mutation.tracks);
    _markLibraryStructureChanged();
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.upsertCatalogTracks(mutation.tracks));
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
    if (!mutation.batched) {
      _coverArtwork()?.invalidateCatalogTracks(mutation.tracks);
    }
    if (!mutation.batched) _trackRemovalHandler?.call(removedPaths);
    if (persist && _persistenceCoordinator.enabled) {
      if (mutation.batched) {
        _removedTrackPaths.addAll(removedPaths);
      } else {
        unawaited(databaseRepository.deleteTracks(removedPaths));
      }
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
      _persistRemovedEntries(libraryPath, removedPaths);
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
      _persistRemovedEntries(libraryPath, removedPaths);
    }
  }

  void _persistRemovedEntries(String libraryPath, List<String> removedPaths) {
    if (_service.libraryBatchDepth > 0) {
      _removedEntryPaths
          .putIfAbsent(libraryPath, () => <String>{})
          .addAll(removedPaths);
    } else {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  void beginLibraryBatch() {
    if (_service.libraryBatchDepth == 0) {
      _batchBefore = _LibraryBatchSnapshot(_service);
      _service.libraryDerivedGeneration++;
    }
    _service.libraryBatchDepth++;
  }

  void beginStagedLibraryRefresh() {
    beginLibraryBatch();
    _stagedRefresh = true;
  }

  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    List<MusicTrack> entryTracks = const <MusicTrack>[],
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) {
    for (final folderPath in removeWatchedFolders) {
      removeWatchedFolder(folderPath, notify: false);
      _refreshFolderWrites[PathMatcher.normalize(folderPath)] = false;
    }
    if (tracks.isNotEmpty || entryTracks.isNotEmpty || folderPaths.isNotEmpty) {
      recordLibraryEntriesForTracks(
        libraryRoot,
        entryTracks.isEmpty ? tracks : entryTracks,
        folderPaths: folderPaths,
        persist: persist,
        exclusionMatcher: exclusionMatcher,
        entrySnapshot: entrySnapshot,
        refreshWrite: true,
      );
    }
    for (final folderPath in addWatchedFolders) {
      addWatchedFolder(folderPath, notify: false);
      _refreshFolderWrites[PathMatcher.normalize(folderPath)] = true;
    }
    final beforeCount = _service.library.length;
    if (tracks.isNotEmpty) {
      addOrReplaceTracks(
        tracks,
        notify: false,
        persist: persist,
        recordEntries: false,
      );
      for (final track in tracks) {
        final current = _service.libraryByPath[track.path];
        if (current != null) _refreshTrackWrites[current.path] = current;
      }
    }
    final tracksToRemove = removeTrackPaths.toList(growable: false);
    for (final trackPath in tracksToRemove) {
      final current = _service.libraryByPath[trackPath];
      if (current != null) _refreshRemovedTracks[trackPath] = current;
    }
    if (tracksToRemove.isNotEmpty) removeTracksByPath(tracksToRemove);
    final entriesToRemove = removeEntryPaths.toList(growable: false);
    if (entriesToRemove.isNotEmpty) {
      for (final entryPath in entriesToRemove) {
        final current = _service.libraryEntryForPath(libraryRoot, entryPath);
        if (current == null) continue;
        _refreshRemovedEntries.putIfAbsent(
          PathMatcher.normalize(libraryRoot),
          () => <String, LibraryEntry>{},
        )[PathMatcher.normalize(entryPath)] = current;
      }
      removeLibraryEntriesByPaths(libraryRoot, entriesToRemove);
    }
    return _service.library.length - beforeCount;
  }

  Future<void> finishStagedLibraryRefresh({bool commit = true}) async {
    if (commit) return endLibraryBatch();
    final before = _batchBefore;
    if (before == null) return;
    _batchBefore = null;
    final changed = _service.libraryBatchChanged;
    final affected = changed ? _affectedTracks(before) : const <MusicTrack>[];
    _rollbackRefreshWrites(before);
    _service.libraryBatchDepth = 0;
    _clearBatch();
    if (changed) {
      await _rebuildDerivedSnapshot();
      _coverArtwork()?.invalidateCatalogTracks(affected);
    }
  }

  void _rollbackRefreshWrites(_LibraryBatchSnapshot before) {
    final originalTracks = {
      for (final track in before.tracks) track.path: track,
    };
    final tracks = <MusicTrack>[];
    for (final current in _service.library) {
      final scanned = _refreshTrackWrites[current.path];
      if (scanned == null) {
        tracks.add(current);
        continue;
      }
      final original = originalTracks[current.path];
      if (original == null) {
        if (!identical(current, scanned)) tracks.add(current);
        continue;
      }
      tracks.add(_restoreRefreshTrack(current, scanned, original));
    }
    for (final entry in _refreshRemovedTracks.entries) {
      final original = originalTracks[entry.key];
      if (original == null || _service.libraryByPath.containsKey(entry.key)) {
        continue;
      }
      tracks.add(
        _restoreRefreshTrack(
          entry.value,
          _refreshTrackWrites[entry.key] ?? entry.value,
          original,
        ),
      );
    }
    _service.library = tracks;
    _service.rebuildLibraryIndexes();
    _service.syncGroupOrderFromLibrary();
    for (final root in _refreshEntryWrites.entries) {
      final currentEntries = _service.libraryEntriesByLibrary[root.key];
      if (currentEntries == null) continue;
      for (final entry in root.value.entries) {
        if (!identical(currentEntries[entry.key], entry.value)) continue;
        final original = before.entries[root.key]?[entry.key];
        if (original == null) {
          currentEntries.remove(entry.key);
        } else {
          currentEntries[entry.key] = original;
        }
      }
    }
    for (final root in _refreshRemovedEntries.entries) {
      final current = _service.libraryEntriesByLibrary[root.key];
      if (current == null) continue;
      for (final entry in root.value.entries) {
        final original = before.entries[root.key]?[entry.key];
        if (original != null && !current.containsKey(entry.key)) {
          current[entry.key] = original.copyWith(state: entry.value.state);
        }
      }
    }
    for (final entry in _refreshFolderWrites.entries) {
      final present = _service.watchedFolders.any(
        (folder) => PathMatcher.equalsNormalized(folder, entry.key),
      );
      if (present != entry.value) continue;
      final wasPresent = before.folders.any(
        (folder) => PathMatcher.equalsNormalized(folder, entry.key),
      );
      if (wasPresent) {
        _service.addWatchedFolder(entry.key);
      } else {
        _service.removeWatchedFolder(entry.key);
      }
    }
  }

  // Native snapshots and authored edits can arrive between scan chunks.
  // Only restore catalog fields still equal to this scan's last write.
  MusicTrack _restoreRefreshTrack(
    MusicTrack current,
    MusicTrack scanned,
    MusicTrack original,
  ) => MusicTrack(
    path: current.path,
    displayName: current.displayName == scanned.displayName
        ? original.displayName
        : current.displayName,
    groupKey: current.groupKey == scanned.groupKey
        ? original.groupKey
        : current.groupKey,
    groupTitle: current.groupTitle == scanned.groupTitle
        ? original.groupTitle
        : current.groupTitle,
    groupSubtitle: current.groupSubtitle == scanned.groupSubtitle
        ? original.groupSubtitle
        : current.groupSubtitle,
    isSingle: current.isSingle == scanned.isSingle
        ? original.isSingle
        : current.isSingle,
    isVideo: current.isVideo == scanned.isVideo
        ? original.isVideo
        : current.isVideo,
    scannedAt: current.scannedAt == scanned.scannedAt
        ? original.scannedAt
        : current.scannedAt,
    fileSizeBytes: current.fileSizeBytes == scanned.fileSizeBytes
        ? original.fileSizeBytes
        : current.fileSizeBytes,
    modifiedAt: current.modifiedAt == scanned.modifiedAt
        ? original.modifiedAt
        : current.modifiedAt,
    duration: current.duration,
    lastPlayedPosition: current.lastPlayedPosition,
    lastPlayedAt: current.lastPlayedAt,
    isFavorite: current.isFavorite,
    tags: current.tags,
    coverCachePath: current.coverCachePath,
    lyricsPath: current.lyricsPath,
    manualCoverPath: current.manualCoverPath,
    remoteCoverUrl: current.remoteCoverUrl,
    remoteMetadataKind: current.remoteMetadataKind,
    remoteMetadata: current.remoteMetadata,
  );

  Future<void> endLibraryBatch({bool notify = true}) async {
    if (_service.libraryBatchDepth <= 0) return;
    _service.libraryBatchDepth--;
    if (_service.libraryBatchDepth > 0) return;
    final before = _batchBefore!;
    _batchBefore = null;
    final didChangeLibrary = _service.libraryBatchChanged;
    final entriesToPersist = _service.libraryBatchPersistEntriesByKey.values
        .map(
          (entry) =>
              _service.libraryEntryForPath(entry.libraryPath, entry.path),
        )
        .whereType<LibraryEntry>()
        .toList(growable: false);
    final tracksToPersist = <String, MusicTrack>{
      for (final track in _service.libraryBatchPersistTracks)
        if (_service.libraryByPath.containsKey(track.path))
          track.path: _service.libraryByPath[track.path]!,
    }.values.toList(growable: false);
    final initialPaths = before.tracks.map((track) => track.path).toSet();
    final removedTracks = <String>[
      for (final path in _removedTrackPaths)
        if (initialPaths.contains(path) &&
            !_service.libraryByPath.containsKey(path))
          path,
    ];
    final removedEntries = <String, List<String>>{
      for (final entry in _removedEntryPaths.entries)
        entry.key: <String>[
          for (final path in entry.value)
            if (before.entries[PathMatcher.normalize(entry.key)]?.containsKey(
                      PathMatcher.normalize(path),
                    ) ==
                    true &&
                _service.libraryEntryForPath(entry.key, path) == null)
              path,
        ],
    };
    if (didChangeLibrary) _service.syncGroupOrderFromLibrary();
    try {
      if (_persistenceCoordinator.enabled &&
          (didChangeLibrary ||
              entriesToPersist.isNotEmpty ||
              removedTracks.isNotEmpty ||
              removedEntries.isNotEmpty)) {
        await _persistenceCoordinator.commitLibraryBatch(
          tracks: tracksToPersist,
          entries: entriesToPersist,
          removedTrackPaths: removedTracks,
          removedEntryPaths: removedEntries,
        );
      }
    } catch (_) {
      final affected = _affectedTracks(before);
      if (_stagedRefresh) {
        _rollbackRefreshWrites(before);
      } else {
        before.restore(_service);
      }
      _clearBatch();
      await _rebuildDerivedSnapshot();
      _coverArtwork()?.invalidateCatalogTracks(affected);
      rethrow;
    }
    _clearBatch();
    if (didChangeLibrary) {
      final affected = _affectedTracks(before);
      final removedPaths = before.tracks
          .where((track) => !_service.libraryByPath.containsKey(track.path))
          .map((track) => track.path)
          .toList(growable: false);
      await _rebuildDerivedSnapshot();
      _coverArtwork()?.invalidateCatalogTracks(affected);
      if (removedPaths.isNotEmpty) _trackRemovalHandler?.call(removedPaths);
    }
  }

  List<MusicTrack> _affectedTracks(_LibraryBatchSnapshot before) {
    final previous = {for (final track in before.tracks) track.path: track};
    final affected = <MusicTrack>[];
    for (final track in _service.library) {
      final original = previous.remove(track.path);
      if (identical(original, track)) continue;
      affected.add(track);
      if (original != null) affected.add(original);
    }
    return affected..addAll(previous.values);
  }

  void _clearBatch() {
    _service
      ..libraryBatchChanged = false
      ..libraryBatchPersistTracks.clear()
      ..libraryBatchPersistEntriesByKey.clear();
    _removedTrackPaths.clear();
    _removedEntryPaths.clear();
    _refreshTrackWrites.clear();
    _refreshEntryWrites.clear();
    _refreshRemovedTracks.clear();
    _refreshRemovedEntries.clear();
    _refreshFolderWrites.clear();
    _stagedRefresh = false;
  }

  Future<void> _rebuildDerivedSnapshot() async {
    final derivedGeneration = ++_service.libraryDerivedGeneration;
    final snapshot = await snapshotCacheService.buildDerivedSnapshot();
    if (derivedGeneration != _service.libraryDerivedGeneration) return;
    _service
      ..library = List<MusicTrack>.of(snapshot.library)
      ..libraryByPath = LibraryService.createPathIndex(snapshot.libraryByPath)
      ..libraryIndexByPath = LibraryService.createPathIndex(
        snapshot.libraryIndexByPath,
      )
      ..tracksByGroup = Map<String, List<MusicTrack>>.of(snapshot.tracksByGroup)
      ..sortedLibraryTracks = snapshot.sortedLibraryTracks
      ..sortedLibraryTrackPaths = snapshot.sortedLibraryTrackPaths
      ..markStructureChanged();
    snapshotCacheService
      ..markStructureChanged()
      ..adoptCardSnapshot(snapshot.cardSnapshot);
    _syncStateSlice();
  }
}

/// A single batch's original catalog, used only for failure rollback.
final class _LibraryBatchSnapshot {
  _LibraryBatchSnapshot(LibraryService service)
    : tracks = List<MusicTrack>.of(service.library),
      folders = List<String>.of(service.watchedFolders),
      libraries = List<String>.of(service.watchedLibraries),
      order = List<String>.of(service.groupOrder),
      entries = {
        for (final entry in service.libraryEntriesByLibrary.entries)
          entry.key: Map<String, LibraryEntry>.of(entry.value),
      };

  final List<MusicTrack> tracks;
  final List<String> folders;
  final List<String> libraries;
  final List<String> order;
  final Map<String, Map<String, LibraryEntry>> entries;

  void restore(LibraryService service) {
    service.library = List<MusicTrack>.of(tracks);
    service.libraryByPath = LibraryService.createPathIndex({
      for (final track in tracks) track.path: track,
    });
    service.libraryIndexByPath = LibraryService.createPathIndex({
      for (var index = 0; index < tracks.length; index++)
        tracks[index].path: index,
    });
    service.watchedFolders
      ..clear()
      ..addAll(folders);
    service.watchedLibraries
      ..clear()
      ..addAll(libraries);
    service.groupOrder
      ..clear()
      ..addAll(order);
    service.groupOrderSet
      ..clear()
      ..addAll(order);
    service.libraryEntriesByLibrary
      ..clear()
      ..addAll(entries);
  }
}
