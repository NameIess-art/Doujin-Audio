import 'dart:async';
import 'dart:convert';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../settings/application/app_preferences.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_service.dart';

final class LibraryPersistedState {
  const LibraryPersistedState({
    required this.tracks,
    required this.entries,
    required this.groupOrder,
    required this.watchedFolders,
    required this.watchedLibraries,
    required this.folderExclusions,
    required this.trackExclusions,
    required this.legacyFolderExclusions,
  });

  final List<MusicTrack> tracks;
  final List<LibraryEntry> entries;
  final List<String> groupOrder;
  final Map<String, Set<String>> folderExclusions;
  final Map<String, Set<String>> trackExclusions;
  final Map<String, Set<String>> legacyFolderExclusions;
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

  final LibraryPersistenceRepository _repository;
  final LibraryService _service;
  Future<void> _writeTail = Future<void>.value();
  bool _enabled = true;

  bool get enabled => _enabled;

  void configure({required bool enabled}) {
    _enabled = enabled;
  }

  Future<LibraryPersistedState> load() async {
    final tracksFuture = _repository.loadStartupTracks();
    final entriesFuture = _repository.loadAllLibraryEntries();
    final preferences = await Future.wait<Object?>(<Future<Object?>>[
      AppPreferences.readJson<List<String>>(_groupOrderKey, _decodeStringList),
      AppPreferences.readJson<List<String>>(
        _watchedFoldersKey,
        _decodeStringList,
      ),
      AppPreferences.readJson<List<String>>(
        _watchedLibrariesKey,
        _decodeStringList,
      ),
      AppPreferences.readJson<Map<String, dynamic>>(
        _exclusionsKey,
        _decodeStringMap,
      ),
      AppPreferences.readJson<Map<String, dynamic>>(
        _legacyRemovedFoldersKey,
        _decodeStringMap,
      ),
    ]);
    final folderExclusions = <String, Set<String>>{};
    final trackExclusions = <String, Set<String>>{};
    final exclusions = preferences[3] as Map<String, dynamic>?;
    _decodeExclusionMap(exclusions?['folders'], folderExclusions);
    _decodeExclusionMap(exclusions?['tracks'], trackExclusions);
    final legacyRemovedFolders = <String, Set<String>>{};
    _decodeExclusionMap(preferences[4], legacyRemovedFolders);
    if (legacyRemovedFolders.isNotEmpty) {
      final migratedFolderExclusions = <String, Set<String>>{
        for (final entry in folderExclusions.entries)
          entry.key: Set<String>.of(entry.value),
      };
      for (final entry in legacyRemovedFolders.entries) {
        migratedFolderExclusions
            .putIfAbsent(entry.key, () => <String>{})
            .addAll(entry.value);
      }
      await saveExclusionSnapshot(
        folderExclusions: migratedFolderExclusions,
        trackExclusions: trackExclusions,
      );
    }
    await AppPreferences.remove(_legacyRemovedFoldersKey);
    return LibraryPersistedState(
      tracks: await tracksFuture,
      entries: await entriesFuture,
      groupOrder: (preferences[0] as List<String>?) ?? const <String>[],
      watchedFolders: (preferences[1] as List<String>?) ?? const <String>[],
      watchedLibraries: (preferences[2] as List<String>?) ?? const <String>[],
      folderExclusions: folderExclusions,
      trackExclusions: trackExclusions,
      legacyFolderExclusions: legacyRemovedFolders,
    );
  }

  Future<void> prepareForReset() => flush();

  Future<void> flush() => _writeTail;

  Future<void> saveWatchedFolders() => _saveStringList(
    _watchedFoldersKey,
    List<String>.of(_service.watchedFolders),
  );

  Future<void> saveWatchedLibraries() => _saveStringList(
    _watchedLibrariesKey,
    List<String>.of(_service.watchedLibraries),
  );

  Future<void> saveGroupOrder() =>
      _saveStringList(_groupOrderKey, List<String>.of(_service.groupOrder));

  Future<void> saveExclusions() => saveExclusionSnapshot(
    folderExclusions: _service.excludedLibraryFolders,
    trackExclusions: _service.excludedLibraryTracks,
  );

  Future<void> saveExclusionSnapshot({
    required Map<String, Set<String>> folderExclusions,
    required Map<String, Set<String>> trackExclusions,
  }) {
    final value = json.encode(<String, Object?>{
      'folders': _encodePathSetMap(folderExclusions),
      'tracks': _encodePathSetMap(trackExclusions),
    });
    return _queueWrite(() => AppPreferences.setString(_exclusionsKey, value));
  }

  Future<void> _saveStringList(String key, List<String> value) {
    final encoded = json.encode(value);
    return _queueWrite(() => AppPreferences.setString(key, encoded));
  }

  Future<void> _queueWrite(Future<void> Function() write) {
    final task = _writeTail.then((_) => write());
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
      target[PathMatcher.normalize(entry.key.toString())] = values
          .map((value) => PathMatcher.normalize(value.toString()))
          .where((value) => value.isNotEmpty)
          .toSet();
    }
  }

  static Map<String, List<String>> _encodePathSetMap(
    Map<String, Set<String>> source,
  ) => source.map(
    (key, value) => MapEntry(key, value.toList(growable: false)..sort()),
  );
}
