import 'dart:async';
import 'dart:isolate';

import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../domain/library_entry.dart';
import 'library_organizer.dart';
import 'library_scan_models.dart';
import 'library_state_models.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';

class ScanMergeIsolatePayload {
  ScanMergeIsolatePayload({
    required List<ScannedTrack> scannedTracks,
    required List<MusicTrack> library,
    required this.libraryRoot,
    required this.promoteRootTracksToSingles,
    required this.i18nImportedFiles,
    required this.i18nManuallySelectedFiles,
    required this.exclusionMatcher,
    this.sourceFolderPath,
    this.allowRemoval = false,
    Set<String> retainedTrackPaths = const <String>{},
    Set<String> retainedEntryPaths = const <String>{},
    this.entrySnapshot,
    List<String> folderPaths = const <String>[],
    this.useWorkerEntrySnapshot = false,
  }) : scannedTracks = immutableList(scannedTracks),
       library = immutableList(library),
       retainedTrackPaths = immutableSet(retainedTrackPaths),
       retainedEntryPaths = immutableSet(retainedEntryPaths),
       folderPaths = immutableList(folderPaths);

  final List<ScannedTrack> scannedTracks;
  final List<MusicTrack> library;
  final String? libraryRoot;
  final bool promoteRootTracksToSingles;
  final String i18nImportedFiles;
  final String i18nManuallySelectedFiles;
  final LibraryExclusionMatcher? exclusionMatcher;
  final String? sourceFolderPath;
  final bool allowRemoval;
  final Set<String> retainedTrackPaths;
  final Set<String> retainedEntryPaths;
  final LibraryEntrySnapshot? entrySnapshot;
  final List<String> folderPaths;
  final bool useWorkerEntrySnapshot;
}

class ScanMergeIsolateResult {
  ScanMergeIsolateResult({
    required List<MusicTrack> trackBatch,
    required List<MusicTrack> entryBatch,
    required this.duplicatesCount,
    List<String> folderBatch = const <String>[],
    List<String> removedTrackPaths = const <String>[],
    List<String> removedEntryPaths = const <String>[],
  }) : trackBatch = immutableList(trackBatch),
       entryBatch = immutableList(entryBatch),
       folderBatch = immutableList(folderBatch),
       removedTrackPaths = immutableList(removedTrackPaths),
       removedEntryPaths = immutableList(removedEntryPaths);
  final List<MusicTrack> trackBatch;
  final List<MusicTrack> entryBatch;
  final List<String> folderBatch;
  final int duplicatesCount;
  final List<String> removedTrackPaths;
  final List<String> removedEntryPaths;
}

class RefreshFinalizeIsolateResult {
  RefreshFinalizeIsolateResult({
    required List<String> folderPaths,
    required List<String> removedTrackPaths,
    required List<String> removedEntryPaths,
  }) : folderPaths = immutableList(folderPaths),
       removedTrackPaths = immutableList(removedTrackPaths),
       removedEntryPaths = immutableList(removedEntryPaths);

  final List<String> folderPaths;
  final List<String> removedTrackPaths;
  final List<String> removedEntryPaths;
}

final class _SetEntrySnapshotRequest {
  const _SetEntrySnapshotRequest(this.snapshot);

  final LibraryEntrySnapshot? snapshot;
}

final class _FinalizeRefreshRequest {
  _FinalizeRefreshRequest({
    required this.libraryRoot,
    required this.sourceFolderPath,
    required this.exclusionMatcher,
    required List<String> folderPaths,
    required this.allowRemoval,
    required List<String> removalCandidates,
    required Set<String> retainedTrackPaths,
    required Set<String> retainedEntryPaths,
  }) : folderPaths = immutableList(folderPaths),
       removalCandidates = immutableList(removalCandidates),
       retainedTrackPaths = immutableSet(retainedTrackPaths),
       retainedEntryPaths = immutableSet(retainedEntryPaths);

  final String libraryRoot;
  final String sourceFolderPath;
  final LibraryExclusionMatcher exclusionMatcher;
  final List<String> folderPaths;
  final bool allowRemoval;
  final List<String> removalCandidates;
  final Set<String> retainedTrackPaths;
  final Set<String> retainedEntryPaths;
}

/// Reuses one isolate for the ordered chunks of a folder scan.
final class LibraryScanMergeWorker {
  final _messages = ReceivePort();
  late final _responses = StreamIterator<dynamic>(_messages);
  Isolate? _worker;
  SendPort? _requests;

  Future<SendPort> _ensureStarted() async {
    if (_requests == null) {
      _worker = await Isolate.spawn(
        _serveScanMergeRequests,
        _messages.sendPort,
        onError: _messages.sendPort,
        onExit: _messages.sendPort,
      );
      _requests = await _readResponse<SendPort>();
    }
    return _requests!;
  }

  Future<void> setEntrySnapshot(LibraryEntrySnapshot? snapshot) async {
    final requests = await _ensureStarted();
    requests.send(_SetEntrySnapshotRequest(snapshot));
    await _readResponse<bool>();
  }

  Future<ScanMergeIsolateResult> merge(ScanMergeIsolatePayload payload) async {
    final requests = await _ensureStarted();
    requests.send(payload);
    return _readResponse<ScanMergeIsolateResult>();
  }

  Future<RefreshFinalizeIsolateResult> finalizeRefresh({
    required String libraryRoot,
    required String sourceFolderPath,
    required LibraryExclusionMatcher exclusionMatcher,
    required List<String> folderPaths,
    required bool allowRemoval,
    required List<String> removalCandidates,
    required Set<String> retainedTrackPaths,
    required Set<String> retainedEntryPaths,
  }) async {
    final requests = await _ensureStarted();
    requests.send(
      _FinalizeRefreshRequest(
        libraryRoot: libraryRoot,
        sourceFolderPath: sourceFolderPath,
        exclusionMatcher: exclusionMatcher,
        folderPaths: folderPaths,
        allowRemoval: allowRemoval,
        removalCandidates: removalCandidates,
        retainedTrackPaths: retainedTrackPaths,
        retainedEntryPaths: retainedEntryPaths,
      ),
    );
    return _readResponse<RefreshFinalizeIsolateResult>();
  }

  Future<T> _readResponse<T>() async {
    if (await _responses.moveNext()) {
      final response = _responses.current;
      if (response is T) return response;
      if (response is List && response.length == 2) {
        throw RemoteError(response[0].toString(), response[1].toString());
      }
    }
    throw StateError('Library scan merge isolate stopped.');
  }

  Future<void> dispose() async {
    _worker?.kill(priority: Isolate.immediate);
    _messages.close();
    await _responses.cancel();
  }
}

void _serveScanMergeRequests(SendPort responses) {
  final requests = ReceivePort();
  LibraryEntrySnapshot? cachedEntrySnapshot;
  responses.send(requests.sendPort);
  requests.listen((message) {
    if (message is _SetEntrySnapshotRequest) {
      cachedEntrySnapshot = message.snapshot;
      responses.send(true);
    } else if (message is _FinalizeRefreshRequest) {
      responses.send(_finalizeRefreshInIsolate(message, cachedEntrySnapshot));
    } else {
      responses.send(
        processScannedTracksInIsolate(
          message as ScanMergeIsolatePayload,
          cachedEntrySnapshot: cachedEntrySnapshot,
        ),
      );
    }
  });
}

RefreshFinalizeIsolateResult _finalizeRefreshInIsolate(
  _FinalizeRefreshRequest request,
  LibraryEntrySnapshot? entrySnapshot,
) {
  final neededFolderPaths = <String>[];
  if (request.folderPaths.isNotEmpty) {
    if (entrySnapshot == null) {
      neededFolderPaths.addAll(request.folderPaths);
    } else {
      final entries = const LibraryOrganizer().buildLibraryEntries(
        request.libraryRoot,
        const <MusicTrack>[],
        folderPaths: request.folderPaths,
        exclusionMatcher: request.exclusionMatcher,
      );
      final needed = <LibraryEntry>[];
      for (final entry in entries) {
        if (!entrySnapshot.entryNeedsRefresh(entry)) continue;
        needed.add(entry);
        if (entry.isFolder) neededFolderPaths.add(entry.path);
      }
      if (needed.isNotEmpty) entrySnapshot.remember(needed);
    }
  }

  final removedTrackPaths = <String>[];
  final removedEntryPaths = <String>[];
  if (request.allowRemoval) {
    if (request.removalCandidates.isNotEmpty) {
      final retainedTrackIndex = PathMembershipIndex(
        request.retainedTrackPaths,
      );
      for (final path in request.removalCandidates) {
        if (!retainedTrackIndex.containsEquivalent(path)) {
          removedTrackPaths.add(path);
        }
      }
    }

    if (entrySnapshot != null && entrySnapshot.entriesByPath.isNotEmpty) {
      final normalizedSource = PathMatcher.normalize(request.sourceFolderPath);
      final retainedEntryIndex = PathMembershipIndex(
        request.retainedEntryPaths,
      );
      for (final entry in entrySnapshot.entriesByPath.values) {
        if (!PathMatcher.isWithinOrEqualNormalized(
          entry.path,
          normalizedSource,
        )) {
          continue;
        }
        final retained = entry.isFolder
            ? retainedEntryIndex.containsDescendantOrEqual(entry.path)
            : retainedEntryIndex.containsEquivalent(entry.path);
        if (!retained) removedEntryPaths.add(entry.path);
      }
    }
  }

  return RefreshFinalizeIsolateResult(
    folderPaths: neededFolderPaths,
    removedTrackPaths: removedTrackPaths,
    removedEntryPaths: removedEntryPaths,
  );
}

ScanMergeIsolateResult processScannedTracksInIsolate(
  ScanMergeIsolatePayload payload, {
  LibraryEntrySnapshot? cachedEntrySnapshot,
}) {
  final libraryRoot = payload.libraryRoot;
  final promoteRootTracksToSingles = payload.promoteRootTracksToSingles;

  final existingTracks = <String, MusicTrack>{};
  for (final track in payload.library) {
    existingTracks[PathMatcher.equivalenceKey(track.path)] = track;
  }

  bool trackIsDirectlyInFolder(String folderPath, ScannedTrack track) {
    return PathMatcher.equalsNormalized(track.groupKey, folderPath) ||
        track.groupKey == folderPath;
  }

  MusicTrack canonicalizeTrackPath(MusicTrack track) {
    final existing = existingTracks[PathMatcher.equivalenceKey(track.path)];
    if (existing == null || existing.path == track.path) return track;
    return MusicTrack(
      path: existing.path,
      displayName: track.displayName,
      groupKey: track.groupKey,
      groupTitle: track.groupTitle,
      groupSubtitle: track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
      lastPlayedPosition: existing.lastPlayedPosition,
      lastPlayedAt: existing.lastPlayedAt,
      isFavorite: existing.isFavorite,
      tags: existing.tags,
      coverCachePath: existing.coverCachePath ?? track.coverCachePath,
      lyricsPath: existing.lyricsPath ?? track.lyricsPath,
      manualCoverPath: existing.manualCoverPath ?? track.manualCoverPath,
      remoteCoverUrl: existing.remoteCoverUrl,
      remoteMetadataKind: existing.remoteMetadataKind,
      remoteMetadata: existing.remoteMetadata,
      duration: existing.duration == Duration.zero
          ? track.duration
          : existing.duration,
    );
  }

  bool mergedTrackHasChanges(MusicTrack existing, MusicTrack scanned) {
    return existing.displayName != scanned.displayName ||
        existing.groupKey != scanned.groupKey ||
        existing.groupTitle != scanned.groupTitle ||
        existing.groupSubtitle != scanned.groupSubtitle ||
        existing.isSingle != scanned.isSingle ||
        existing.isVideo != scanned.isVideo ||
        existing.fileSizeBytes != scanned.fileSizeBytes ||
        existing.modifiedAt?.millisecondsSinceEpoch !=
            scanned.modifiedAt?.millisecondsSinceEpoch ||
        (existing.coverCachePath == null && scanned.coverCachePath != null) ||
        (existing.lyricsPath == null && scanned.lyricsPath != null) ||
        (existing.manualCoverPath == null && scanned.manualCoverPath != null) ||
        (existing.duration == Duration.zero &&
            scanned.duration != Duration.zero);
  }

  bool trackNeedsRefresh(MusicTrack nextTrack) {
    final existing = existingTracks[PathMatcher.equivalenceKey(nextTrack.path)];
    return existing == null || mergedTrackHasChanges(existing, nextTrack);
  }

  final trackBatch = <MusicTrack>[];
  final convertedForEntries = <MusicTrack>[];
  var duplicates = 0;

  for (final scanned in payload.scannedTracks) {
    MusicTrack converted;
    if (promoteRootTracksToSingles &&
        libraryRoot != null &&
        trackIsDirectlyInFolder(libraryRoot, scanned)) {
      converted = MusicTrack(
        path: scanned.path,
        displayName:
            scanned.displayName ??
            PathDisplay.fileName(scanned.path, withoutExtension: true),
        groupKey: '__single_files__',
        groupTitle: payload.i18nImportedFiles,
        groupSubtitle: payload.i18nManuallySelectedFiles,
        isSingle: true,
        isVideo: scanned.isVideo,
        scannedAt: scanned.scannedAt ?? DateTime.now(),
        fileSizeBytes: scanned.fileSizeBytes,
        modifiedAt: scanned.modifiedAt,
      );
    } else {
      converted = MusicTrack(
        path: scanned.path,
        displayName:
            scanned.displayName ??
            PathDisplay.fileName(scanned.path, withoutExtension: true),
        groupKey: scanned.groupKey,
        groupTitle: scanned.groupTitle,
        groupSubtitle: scanned.groupSubtitle,
        isSingle: scanned.isSingle,
        isVideo: scanned.isVideo,
        scannedAt: scanned.scannedAt ?? DateTime.now(),
        fileSizeBytes: scanned.fileSizeBytes,
        modifiedAt: scanned.modifiedAt,
      );
    }

    converted = canonicalizeTrackPath(converted);

    if (libraryRoot != null) {
      convertedForEntries.add(converted);
    }

    if (trackNeedsRefresh(converted)) {
      if (libraryRoot == null ||
          payload.exclusionMatcher == null ||
          !payload.exclusionMatcher!.isTrackPathExcluded(
            converted.path,
            parentPath: converted.groupKey,
          )) {
        trackBatch.add(converted);
      }
    } else {
      duplicates++;
    }
  }

  final effectiveEntrySnapshot =
      payload.entrySnapshot ??
      (payload.useWorkerEntrySnapshot ? cachedEntrySnapshot : null);
  final List<MusicTrack> entryBatch;
  final List<String> folderBatch;
  if (libraryRoot != null &&
      effectiveEntrySnapshot != null &&
      (convertedForEntries.isNotEmpty || payload.folderPaths.isNotEmpty)) {
    final builtEntries = const LibraryOrganizer().buildLibraryEntries(
      libraryRoot,
      convertedForEntries,
      folderPaths: payload.folderPaths,
      exclusionMatcher:
          payload.exclusionMatcher ??
          LibraryExclusionMatcher(libraryPath: libraryRoot),
    );
    final neededEntries = <LibraryEntry>[];
    final neededTrackKeys = <String>{};
    final neededFolders = <String>[];
    for (final entry in builtEntries) {
      if (!effectiveEntrySnapshot.entryNeedsRefresh(entry)) continue;
      neededEntries.add(entry);
      if (entry.isFolder) {
        neededFolders.add(entry.path);
      } else {
        neededTrackKeys.add(PathMatcher.equivalenceKey(entry.path));
      }
    }
    if (neededEntries.isNotEmpty) {
      effectiveEntrySnapshot.remember(neededEntries);
    }
    entryBatch = neededTrackKeys.isEmpty
        ? const <MusicTrack>[]
        : <MusicTrack>[
            for (final track in convertedForEntries)
              if (neededTrackKeys.contains(
                PathMatcher.equivalenceKey(track.path),
              ))
                track,
          ];
    folderBatch = neededFolders;
  } else {
    entryBatch = convertedForEntries;
    folderBatch = payload.folderPaths;
  }

  final removedTrackPaths = <String>[];
  final removedEntryPaths = <String>[];
  final sourceFolderPath = payload.sourceFolderPath;
  if (payload.allowRemoval && sourceFolderPath != null) {
    final normalizedSourceFolder = PathMatcher.normalize(sourceFolderPath);
    if (payload.retainedTrackPaths.isNotEmpty) {
      final retainedTrackIndex = PathMembershipIndex(
        payload.retainedTrackPaths,
      );
      for (final track in payload.library) {
        if (!PathMatcher.isWithinOrEqualNormalized(
          track.path,
          normalizedSourceFolder,
        )) {
          continue;
        }
        if (!retainedTrackIndex.containsEquivalent(track.path)) {
          removedTrackPaths.add(track.path);
        }
      }
    }

    final snapshot = effectiveEntrySnapshot;
    if (snapshot != null && payload.retainedEntryPaths.isNotEmpty) {
      final retainedEntryIndex = PathMembershipIndex(
        payload.retainedEntryPaths,
      );
      for (final entry in snapshot.entriesByPath.values) {
        if (!PathMatcher.isWithinOrEqualNormalized(
          entry.path,
          normalizedSourceFolder,
        )) {
          continue;
        }
        final retained = entry.isFolder
            ? retainedEntryIndex.containsDescendantOrEqual(entry.path)
            : retainedEntryIndex.containsEquivalent(entry.path);
        if (!retained) {
          removedEntryPaths.add(entry.path);
        }
      }
    }
  }

  return ScanMergeIsolateResult(
    trackBatch: trackBatch,
    entryBatch: entryBatch,
    folderBatch: folderBatch,
    duplicatesCount: duplicates,
    removedTrackPaths: List<String>.unmodifiable(removedTrackPaths),
    removedEntryPaths: List<String>.unmodifiable(removedEntryPaths),
  );
}
