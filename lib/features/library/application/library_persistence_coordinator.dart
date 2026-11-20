import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/app_preferences.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_service.dart';
import 'library_snapshot_cache_service.dart';

final class LibraryPersistedState {
  const LibraryPersistedState({
    required this.derived,
    required this.entriesByLibrary,
    required this.groupOrder,
    required this.watchedFolders,
    required this.watchedLibraries,
    required this.folderExclusions,
    required this.trackExclusions,
  });

  final LibraryDerivedSnapshot derived;
  final Map<String, Map<String, LibraryEntry>> entriesByLibrary;
  final List<String> groupOrder;
  final Map<String, Set<String>> folderExclusions;
  final Map<String, Set<String>> trackExclusions;
  final List<String> watchedFolders;
  final List<String> watchedLibraries;
}

/// Owns library preference serialization and ordered writes.
///
/// Mutable state continues to live in [LibraryService]; this coordinator only
/// reads snapshots from it when a persistence operation is requested.
final class LibraryPersistenceCoordinator {
  LibraryPersistenceCoordinator({
    required LibraryPersistenceRepository repository,
    required LibraryService service,
  }) : _repository = repository,
       _service = service;

  static const _watchedFoldersKey = 'watched_folders_v1';
  static const _watchedLibrariesKey = 'watched_libraries_v1';
  static const _groupOrderKey = 'group_order_v1';
  static const _exclusionsKey = 'library_exclusions_v1';
  static const _legacyRemovedFoldersKey = 'removed_library_folders_v1';
  static const _catalogKeys = [
    _groupOrderKey,
    _watchedFoldersKey,
    _watchedLibrariesKey,
  ];

  final LibraryPersistenceRepository _repository;
  final LibraryService _service;
  final _committedCatalogLists = <String, List<String>>{};
  Future<void>? _writeTail;
  bool _enabled = true;
  int _loadGeneration = 0;

  bool get enabled => _enabled;

  void configure({required bool enabled}) {
    _enabled = enabled;
  }

  Future<LibraryPersistedState> load() async {
    final generation = ++_loadGeneration;
    final tracksFuture = _repository.loadStartupTracks();
    final entriesFuture = _repository.loadAllLibraryEntries();
    final catalogSettings = await _repository.loadAppSettings(_catalogKeys);
    final catalogValues = [
      for (final key in _catalogKeys) catalogSettings[key],
    ];
    final preferences = await Future.wait<Object?>(<Future<Object?>>[
      if (catalogValues[0] == null)
        AppPreferences.readJson<List<String>>(_groupOrderKey, _decodeStringList)
      else
        Future<Object?>.value(),
      if (catalogValues[1] == null)
        AppPreferences.readJson<List<String>>(
          _watchedFoldersKey,
          _decodeStringList,
        )
      else
        Future<Object?>.value(),
      if (catalogValues[2] == null)
        AppPreferences.readJson<List<String>>(
          _watchedLibrariesKey,
          _decodeStringList,
        )
      else
        Future<Object?>.value(),
      AppPreferences.readJson<Map<String, dynamic>>(
        _exclusionsKey,
        _decodeStringMap,
      ),
      AppPreferences.readJson<Map<String, dynamic>>(
        _legacyRemovedFoldersKey,
        _decodeStringMap,
      ),
    ]);
    final folderExclusions = LibraryService.createPathIndex<Set<String>>();
    final trackExclusions = LibraryService.createPathIndex<Set<String>>();
    final exclusions = preferences[3] as Map<String, dynamic>?;
    _decodeExclusionMap(exclusions?['folders'], folderExclusions);
    _decodeExclusionMap(exclusions?['tracks'], trackExclusions);
    final legacyRemovedFolders = LibraryService.createPathIndex<Set<String>>();
    _decodeExclusionMap(preferences[4], legacyRemovedFolders);
    if (legacyRemovedFolders.isNotEmpty) {
      for (final entry in legacyRemovedFolders.entries) {
        folderExclusions
            .putIfAbsent(entry.key, LibraryService.createPathSet)
            .addAll(entry.value);
      }
      final value = _encodeExclusionSnapshot(folderExclusions, trackExclusions);
      await _queueWrite(
        () async => AppPreferences.setString(_exclusionsKey, value),
        loadGeneration: generation,
      );
    }
    await _queueWrite(
      () async =>
          AppPreferences.remove(_legacyRemovedFoldersKey, ifPresent: true),
      loadGeneration: generation,
    );
    final legacyLists = preferences
        .take(3)
        .map((value) => value as List<String>?)
        .toList();
    final catalogLists = await _decodeCatalogLists(catalogValues, legacyLists);
    if (enabled) {
      await _queueWrite(() async {
        final missing = <String, List<String>>{};
        for (final (index, key) in _catalogKeys.indexed) {
          // A write queued during startup takes precedence over the earlier read.
          if (_committedCatalogLists.containsKey(key)) continue;
          final list = catalogLists[index];
          if (catalogValues[index] == null) {
            missing[key] = list;
          } else {
            _committedCatalogLists[key] = list;
          }
        }
        if (missing.isEmpty) return;
        final settings = await _encodeCatalogLists(missing);
        if (generation != _loadGeneration) return;
        await _repository.commitLibraryBatch(
          tracks: const [],
          entries: const [],
          catalogSettings: settings,
        );
        _committedCatalogLists.addAll(missing);
      }, loadGeneration: generation);
    }
    final tracks = await tracksFuture;
    final entries = await entriesFuture;
    return AppLogService.measureAsync(
      'library_derived_snapshot_build',
      () => compute(_preparePersistedLibrary, (
        tracks: tracks,
        entries: entries,
        catalogLists: catalogLists,
        folderExclusions: folderExclusions,
        trackExclusions: trackExclusions,
      )),
      details: {'tracks': tracks.length},
    );
  }

  Future<void> prepareForReset() async {
    _loadGeneration++;
    await flush();
    _committedCatalogLists.clear();
  }

  Future<void> flush() => _writeTail ?? Future<void>.value();

  Future<void> saveCatalogLists() => _service.libraryBatchDepth > 0
      ? Future<void>.value()
      : commitLibraryBatch(tracks: const [], entries: const []);

  Future<void> commitLibraryBatch({
    required List<MusicTrack> tracks,
    required List<LibraryEntry> entries,
    List<String> removedTrackPaths = const [],
    Map<String, List<String>> removedEntryPaths = const {},
  }) {
    final lists = {
      _groupOrderKey: List<String>.of(_service.groupOrder),
      _watchedFoldersKey: List<String>.of(_service.watchedFolders),
      _watchedLibrariesKey: List<String>.of(_service.watchedLibraries),
    };
    return _queueWrite(() async {
      final changed = {
        for (final entry in lists.entries)
          if (!listEquals(_committedCatalogLists[entry.key], entry.value))
            entry.key: entry.value,
      };
      if (changed.isEmpty &&
          tracks.isEmpty &&
          entries.isEmpty &&
          removedTrackPaths.isEmpty &&
          removedEntryPaths.isEmpty) {
        return;
      }
      await _repository.commitLibraryBatch(
        tracks: tracks,
        entries: entries,
        removedTrackPaths: removedTrackPaths,
        removedEntryPaths: removedEntryPaths,
        catalogSettings: changed.isEmpty
            ? const {}
            : await _encodeCatalogLists(changed),
      );
      _committedCatalogLists.addAll(changed);
    });
  }

  static Future<List<List<String>>> _decodeCatalogLists(
    List<String?> values,
    List<List<String>?> legacyLists,
  ) => Isolate.run(
    () => <List<String>>[
      for (var index = 0; index < values.length; index++)
        values[index] == null
            ? legacyLists[index] ?? <String>[]
            : _decodeStringList(json.decode(values[index]!)),
    ],
  );

  static Future<Map<String, String>> _encodeCatalogLists(
    Map<String, List<String>> lists,
  ) => Isolate.run(
    () => {
      for (final entry in lists.entries) entry.key: json.encode(entry.value),
    },
  );

  Future<void> saveExclusions() => saveExclusionSnapshot(
    folderExclusions: _service.excludedLibraryFolders,
    trackExclusions: _service.excludedLibraryTracks,
  );

  Future<void> saveExclusionSnapshot({
    required Map<String, Set<String>> folderExclusions,
    required Map<String, Set<String>> trackExclusions,
  }) {
    final value = _encodeExclusionSnapshot(folderExclusions, trackExclusions);
    return _queueWrite(() => AppPreferences.setString(_exclusionsKey, value));
  }

  static String _encodeExclusionSnapshot(
    Map<String, Set<String>> folderExclusions,
    Map<String, Set<String>> trackExclusions,
  ) => json.encode(<String, Object?>{
    'folders': _encodePathSetMap(folderExclusions),
    'tracks': _encodePathSetMap(trackExclusions),
  });

  Future<void> _queueWrite(
    Future<void> Function() write, {
    int? loadGeneration,
  }) {
    final task = (_writeTail ?? Future<void>.value()).then<void>((_) async {
      if (loadGeneration != null && loadGeneration != _loadGeneration) return;
      await write();
    });
    _writeTail = task.catchError((Object error, StackTrace stackTrace) {
      AppLogService.error(
        'library_preference_write_failed',
        error: error,
        stackTrace: stackTrace,
      );
    });
    return task;
  }

  static List<String> _decodeStringList(Object? value) =>
      (value as List<dynamic>).cast<String>();

  static Map<String, dynamic> _decodeStringMap(Object? value) =>
      (value as Map<Object?, Object?>).map(
        (key, value) => MapEntry(key.toString(), value),
      );

  static void _decodeExclusionMap(
    Object? raw,
    Map<String, Set<String>> target,
  ) {
    target.clear();
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final values = entry.value;
      if (values is! List) continue;
      final normalizedKey = PathMatcher.normalize(entry.key.toString());
      final set = target.putIfAbsent(
        normalizedKey,
        LibraryService.createPathSet,
      );
      for (final value in values) {
        final normalizedValue = PathMatcher.normalize(value.toString());
        if (normalizedValue.isNotEmpty) set.add(normalizedValue);
      }
    }
  }

  static Map<String, List<String>> _encodePathSetMap(
    Map<String, Set<String>> source,
  ) => source.map(
    (key, value) => MapEntry(key, value.toList(growable: false)..sort()),
  );
  void queueOrPersistEntries(
    List<LibraryEntry> entries, {
    required bool persist,
  }) {
    if (entries.isEmpty || !persist || !enabled) {
      return;
    }
    if (_service.libraryBatchDepth > 0) {
      for (final entry in entries) {
        final key = <String>[
          PathMatcher.equivalenceKey(entry.libraryPath),
          PathMatcher.equivalenceKey(entry.path),
          entry.kind.dbValue,
        ].join('\x1F');
        _service.libraryBatchPersistEntriesByKey[key] = entry;
      }
      return;
    }
    unawaited(_repository.upsertLibraryEntries(entries));
  }
}

LibraryPersistedState _preparePersistedLibrary(
  ({
    List<MusicTrack> tracks,
    Iterable<LibraryEntry> entries,
    List<List<String>> catalogLists,
    Map<String, Set<String>> folderExclusions,
    Map<String, Set<String>> trackExclusions,
  })
  payload,
) {
  final tracks = payload.tracks;
  final entries = payload.entries;
  final catalogLists = payload.catalogLists;
  final roots = LibraryService.createPathIndex<String>({
    for (final root in [...catalogLists[2], ...catalogLists[1]])
      PathMatcher.normalize(root): PathMatcher.normalize(root),
  });
  String canonicalRoot(String value) {
    final normalized = PathMatcher.normalize(value);
    return roots.putIfAbsent(normalized, () => normalized);
  }

  final entriesByLibrary =
      LibraryService.createPathIndex<Map<String, LibraryEntry>>();
  Map<String, Set<String>> restoreExclusions(Map<String, Set<String>> source) {
    final restored = LibraryService.createPathIndex<Set<String>>();
    for (final entry in source.entries) {
      restored
          .putIfAbsent(canonicalRoot(entry.key), LibraryService.createPathSet)
          .addAll(entry.value);
    }
    return restored;
  }

  final folderExclusions = restoreExclusions(payload.folderExclusions);
  final trackExclusions = restoreExclusions(payload.trackExclusions);
  for (final entry in entries) {
    final root = canonicalRoot(entry.libraryPath);
    final path = PathMatcher.normalize(entry.path);
    entriesByLibrary.putIfAbsent(
      root,
      LibraryService.createPathIndex<LibraryEntry>,
    )[path] = entry;
    final excluded = entry.isFolder ? folderExclusions : trackExclusions;
    // Indexed entries carry current state; preference-only paths still belong
    // to older libraries without a complete entry index.
    excluded[root]?.remove(path);
    if (entry.isExcluded) {
      excluded.putIfAbsent(root, LibraryService.createPathSet).add(path);
    }
  }
  final trackIndex = PathMembershipIndex(
    trackExclusions.values.expand((paths) => paths),
  );
  final folderIndex = PathMembershipIndex(
    folderExclusions.values.expand((paths) => paths),
  );
  final retained = tracks
      .where(
        (track) =>
            !trackIndex.containsEquivalent(track.path) &&
            !folderIndex.containsAncestorOrEqual(track.path) &&
            !folderIndex.containsAncestorOrEqual(track.groupKey),
      )
      .toList();
  final activeGroups = retained.map((track) => track.groupKey).toSet();
  final order = catalogLists[0].where(activeGroups.contains).toList();
  final ordered = order.toSet();
  order.addAll(activeGroups.where(ordered.add));
  return LibraryPersistedState(
    derived: buildLibraryDerivedSnapshot(
      LibraryDerivedSnapshotPayload(
        tracks: retained,
        watchedFolders: catalogLists[1],
        watchedLibraries: catalogLists[2],
      ),
    ),
    entriesByLibrary: entriesByLibrary,
    groupOrder: order,
    watchedFolders: catalogLists[1],
    watchedLibraries: catalogLists[2],
    folderExclusions: folderExclusions,
    trackExclusions: trackExclusions,
  );
}
