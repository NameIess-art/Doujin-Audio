import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/state/audio_state_slice.dart';
import '../../../core/app_language.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/app_interaction_feedback_settings.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../player/domain/audio_effects.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../../core/persistence/app_preferences.dart';
import 'settings_state.dart';

class SettingsRepository {
  static const _playbackSettingsKey = 'playback_settings_v1';
  static const _converterSettingsKey = 'converter_settings_v1';
  static const converterFormats = <String>['mp3', 'flac', 'wav', 'aac', 'ogg'];
  static const converterBitrates = <String>['128k', '192k', '256k', '320k'];
  String converterFormat = 'mp3';
  String converterBitrate = '320k';
  String? converterOutputDirectoryPath;
  bool autoCheckUpdates = false;
  ContentLanguagePreference dlsiteMetadataLanguage =
      ContentLanguagePreference.followPage;
  LibrarySortCriterion librarySortCriterion = LibrarySortCriterion.name;
  bool librarySortAscending = true;
  bool libraryGroupByLibrary = false;
  List<String> pinnedLibraryPaths = <String>[];
  PlaylistSortCriterion playlistSortCriterion = PlaylistSortCriterion.name;
  bool playlistSortAscending = true;
  bool playlistGroupByLibrary = false;
  List<String> pinnedPlaylistSessionIds = <String>[];
  List<EqPreset> customEqPresets = const <EqPreset>[];
  int maxCacheBytes = AppCacheService.defaultMaxCacheBytes;
  bool asmrPlaybackCacheEnabled = false;
  bool recordPlaybackProgress = true;
  bool allowVideoPlayback = true;
  bool blurPlayerBackgroundEnabled = true;
  bool uiBlurEffectEnabled = true;
  bool hapticFeedbackEnabled = true;
  bool showLocalLibrary = true;
  bool showAsmrOne = true;
  WorkNameDisplay workNameDisplay = WorkNameDisplay.workTitle;
  StartupPage startupPage = StartupPage.library;
  bool portraitLockEnabled = false;
  CoverImageResolution coverImageResolution = CoverImageResolution.balanced;
  CoverImageDisplayMode coverImageDisplayMode = CoverImageDisplayMode.fill;
  bool preferEmbeddedCover = true;
  String? asmrDownloadDestinationRoot;
  AsmrDownloadConflictPolicy asmrDownloadConflictPolicy =
      AsmrDownloadConflictPolicy.overwrite;
  int asmrDownloadRetryCount = kDefaultAsmrDownloadRetryCount;
  int asmrDownloadThreadCount = kDefaultAsmrDownloadThreadCount;
  bool asmrDownloadSaveMetadata = true;
  bool asmrDownloadSaveCover = true;
  List<AsmrDownloadFolderNameField> asmrDownloadFolderNameFields =
      kDefaultAsmrDownloadFolderNameFields;
  AudioDeviceDisconnectBehavior audioDeviceDisconnectBehavior =
      AudioDeviceDisconnectBehavior.pause;
  AudioFocusStrategy audioFocusStrategy = AudioFocusStrategy.standard;
  TransientAudioFocusLossBehavior transientAudioFocusLossBehavior =
      TransientAudioFocusLossBehavior.duck;
  InterruptionResumeBehavior interruptionResumeBehavior =
      InterruptionResumeBehavior.resume;
  SleepModeAutoTrigger sleepModeAutoTrigger = SleepModeAutoTrigger.manual;
  bool reduceAnimations = false;
  final AudioStateSlice<SettingsState> slice = AudioStateSlice<SettingsState>(
    SettingsState(),
  );

  Future<void> loadPersistedState() async {
    _resetValues();
    final playback = await AppPreferences.readJson<Map<String, dynamic>>(
      _playbackSettingsKey,
      (value) => (value as Map<Object?, Object?>).map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    );
    if (playback != null) {
      startupPage = StartupPage.values.firstWhere(
        (value) => value.name == playback['startupPage'],
        orElse: () => StartupPage.library,
      );
      portraitLockEnabled = playback['portraitLockEnabled'] as bool? ?? false;
      autoCheckUpdates = playback['autoCheckUpdates'] as bool? ?? false;
      recordPlaybackProgress =
          playback['recordPlaybackProgress'] as bool? ?? true;
      allowVideoPlayback = playback['allowVideoPlayback'] as bool? ?? true;
      asmrPlaybackCacheEnabled =
          playback['asmrPlaybackCacheEnabled'] as bool? ?? false;
      blurPlayerBackgroundEnabled =
          playback['blurPlayerBackgroundEnabled'] as bool? ?? true;
      uiBlurEffectEnabled = playback['uiBlurEffectEnabled'] as bool? ?? true;
      hapticFeedbackEnabled =
          playback['hapticFeedbackEnabled'] as bool? ?? true;
      AppInteractionFeedbackSettings.hapticFeedbackEnabled =
          hapticFeedbackEnabled;
      showLocalLibrary = playback['showLocalLibrary'] as bool? ?? true;
      showAsmrOne = playback['showAsmrOne'] as bool? ?? true;
      workNameDisplay = WorkNameDisplay.values.firstWhere(
        (value) => value.name == playback['workNameDisplay'],
        orElse: () => WorkNameDisplay.workTitle,
      );
      if (!showLocalLibrary && !showAsmrOne) {
        showLocalLibrary = true;
      }
      coverImageResolution = CoverImageResolution.values.firstWhere(
        (value) => value.name == playback['coverImageResolution'],
        orElse: () => CoverImageResolution.balanced,
      );
      coverImageDisplayMode = CoverImageDisplayMode.values.firstWhere(
        (value) => value.name == playback['coverImageDisplayMode'],
        orElse: () => CoverImageDisplayMode.fill,
      );
      // Older builds stored this preference under the audio-only key.
      preferEmbeddedCover =
          playback['preferEmbeddedCover'] as bool? ??
          playback['preferEmbeddedAudioCover'] as bool? ??
          true;
      asmrDownloadDestinationRoot = _optionalString(
        playback['asmrDownloadDestinationRoot'],
      );
      asmrDownloadConflictPolicy = AsmrDownloadConflictPolicy.values.firstWhere(
        (value) => value.name == playback['asmrDownloadConflictPolicy'],
        orElse: () => AsmrDownloadConflictPolicy.overwrite,
      );
      asmrDownloadSaveMetadata =
          playback['asmrDownloadSaveMetadata'] as bool? ?? true;
      asmrDownloadSaveCover =
          playback['asmrDownloadSaveCover'] as bool? ?? true;
      asmrDownloadRetryCount = normalizeAsmrDownloadRetryCount(
        (playback['asmrDownloadRetryCount'] as num?)?.toInt() ??
            kDefaultAsmrDownloadRetryCount,
      );
      asmrDownloadThreadCount = normalizeAsmrDownloadThreadCount(
        (playback['asmrDownloadThreadCount'] as num?)?.toInt() ??
            kDefaultAsmrDownloadThreadCount,
      );
      asmrDownloadFolderNameFields = decodeAsmrDownloadFolderNameFields(
        playback['asmrDownloadFolderNameFields'],
      );
      audioDeviceDisconnectBehavior = AudioDeviceDisconnectBehavior.values
          .firstWhere(
            (value) => value.name == playback['audioDeviceDisconnectBehavior'],
            orElse: () => AudioDeviceDisconnectBehavior.pause,
          );
      audioFocusStrategy = AudioFocusStrategy.values.firstWhere(
        (value) => value.name == playback['audioFocusStrategy'],
        orElse: () => AudioFocusStrategy.standard,
      );
      transientAudioFocusLossBehavior = TransientAudioFocusLossBehavior.values
          .firstWhere(
            (value) =>
                value.name == playback['transientAudioFocusLossBehavior'],
            orElse: () => TransientAudioFocusLossBehavior.duck,
          );
      interruptionResumeBehavior = InterruptionResumeBehavior.values.firstWhere(
        (value) => value.name == playback['interruptionResumeBehavior'],
        orElse: () => InterruptionResumeBehavior.resume,
      );
      sleepModeAutoTrigger = SleepModeAutoTrigger.values.firstWhere(
        (value) => value.name == playback['sleepModeAutoTrigger'],
        orElse: () => SleepModeAutoTrigger.manual,
      );
      reduceAnimations = playback['reduceAnimations'] as bool? ?? false;
      dlsiteMetadataLanguage = ContentLanguagePreference.fromName(
        playback['dlsiteMetadataLanguage'],
      );
      librarySortCriterion = LibrarySortCriterion.values.firstWhere(
        (value) => value.name == playback['librarySortCriterion'],
        orElse: () => LibrarySortCriterion.name,
      );
      librarySortAscending = playback['librarySortAscending'] as bool? ?? true;
      libraryGroupByLibrary =
          playback['libraryGroupByLibrary'] as bool? ?? false;
      playlistSortCriterion = PlaylistSortCriterion.values.firstWhere(
        (value) => value.name == playback['playlistSortCriterion'],
        orElse: () => PlaylistSortCriterion.name,
      );
      playlistSortAscending =
          playback['playlistSortAscending'] as bool? ?? true;
      playlistGroupByLibrary =
          playback['playlistGroupByLibrary'] as bool? ?? false;
      final pinnedLibList = playback['pinnedLibraryPaths'];
      if (pinnedLibList is List) {
        pinnedLibraryPaths = pinnedLibList.map((e) => e.toString()).toList();
      } else {
        pinnedLibraryPaths = <String>[];
      }
      final pinnedList = playback['pinnedPlaylistSessionIds'];
      if (pinnedList is List) {
        pinnedPlaylistSessionIds = pinnedList.map((e) => e.toString()).toList();
      } else {
        pinnedPlaylistSessionIds = <String>[];
      }
      customEqPresets = _decodeEqPresets(playback['customEqPresets']);
      maxCacheBytes =
          (playback['maxCacheBytes'] as num?)?.toInt() ??
          AppCacheService.defaultMaxCacheBytes;
    }

    final converter = await AppPreferences.readJson<Map<String, dynamic>>(
      _converterSettingsKey,
      (value) => (value as Map<Object?, Object?>).map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    );
    final savedFormat = converter?['format'];
    final savedBitrate = converter?['bitrate'];
    converterOutputDirectoryPath = _optionalString(
      converter?['outputDirectoryPath'],
    );
    if (savedFormat is String && converterFormats.contains(savedFormat)) {
      converterFormat = savedFormat;
    }
    if (savedBitrate is String && converterBitrates.contains(savedBitrate)) {
      converterBitrate = savedBitrate;
    }
    await AppCacheService.setMaxCacheBytes(maxCacheBytes);
    syncSlice(isInitialized: true);
  }

  Future<void> resetPersistedState() async {
    _resetValues();
    syncSlice();
  }

  Future<void> persist() async {
    final saved = await AppPreferences.writeJson(
      _playbackSettingsKey,
      <String, Object?>{
        'startupPage': startupPage.name,
        'portraitLockEnabled': portraitLockEnabled,
        'autoCheckUpdates': autoCheckUpdates,
        'recordPlaybackProgress': recordPlaybackProgress,
        'allowVideoPlayback': allowVideoPlayback,
        'asmrPlaybackCacheEnabled': asmrPlaybackCacheEnabled,
        'blurPlayerBackgroundEnabled': blurPlayerBackgroundEnabled,
        'uiBlurEffectEnabled': uiBlurEffectEnabled,
        'hapticFeedbackEnabled': hapticFeedbackEnabled,
        'showLocalLibrary': showLocalLibrary,
        'showAsmrOne': showAsmrOne,
        'workNameDisplay': workNameDisplay.name,
        'coverImageResolution': coverImageResolution.name,
        'coverImageDisplayMode': coverImageDisplayMode.name,
        'preferEmbeddedCover': preferEmbeddedCover,
        'asmrDownloadDestinationRoot': asmrDownloadDestinationRoot,
        'asmrDownloadConflictPolicy': asmrDownloadConflictPolicy.name,
        'asmrDownloadRetryCount': asmrDownloadRetryCount,
        'asmrDownloadThreadCount': asmrDownloadThreadCount,
        'asmrDownloadSaveMetadata': asmrDownloadSaveMetadata,
        'asmrDownloadSaveCover': asmrDownloadSaveCover,
        'asmrDownloadFolderNameFields': asmrDownloadFolderNameFields
            .map((field) => field.name)
            .toList(growable: false),
        'dlsiteMetadataLanguage': dlsiteMetadataLanguage.name,
        'librarySortCriterion': librarySortCriterion.name,
        'librarySortAscending': librarySortAscending,
        'libraryGroupByLibrary': libraryGroupByLibrary,
        'pinnedLibraryPaths': pinnedLibraryPaths,
        'playlistSortCriterion': playlistSortCriterion.name,
        'playlistSortAscending': playlistSortAscending,
        'playlistGroupByLibrary': playlistGroupByLibrary,
        'pinnedPlaylistSessionIds': pinnedPlaylistSessionIds,
        'customEqPresets': customEqPresets
            .map((preset) => preset.toJson())
            .toList(growable: false),
        'maxCacheBytes': maxCacheBytes,
        'audioDeviceDisconnectBehavior': audioDeviceDisconnectBehavior.name,
        'audioFocusStrategy': audioFocusStrategy.name,
        'transientAudioFocusLossBehavior': transientAudioFocusLossBehavior.name,
        'interruptionResumeBehavior': interruptionResumeBehavior.name,
        'reduceAnimations': reduceAnimations,
        'sleepModeAutoTrigger': sleepModeAutoTrigger.name,
      },
    );
    if (!saved) throw StateError('settings_write_failed');
  }

  Future<void> setConverterSettings({String? format, String? bitrate}) =>
      _change(() async {
        if (format != null && converterFormats.contains(format)) {
          converterFormat = format;
        }
        if (bitrate != null && converterBitrates.contains(bitrate)) {
          converterBitrate = bitrate;
        }
      }, converter: true);

  Future<void> setConverterOutputDirectoryPath(String directoryPath) =>
      _change(() async {
        final normalized = _optionalString(directoryPath);
        if (normalized != null) converterOutputDirectoryPath = normalized;
      }, converter: true);

  Future<void> _persistConverterSettings() async {
    final saved =
        await AppPreferences.writeJson(_converterSettingsKey, <String, Object?>{
          'format': converterFormat,
          'bitrate': converterBitrate,
          if (converterOutputDirectoryPath != null)
            'outputDirectoryPath': converterOutputDirectoryPath,
        });
    if (!saved) throw StateError('settings_write_failed');
  }

  Future<void> setAsmrDownloadDestinationRoot(String? destinationRoot) =>
      _change(() async {
        asmrDownloadDestinationRoot = _optionalString(destinationRoot);
      });

  Future<void> setLibrarySortCriterion(LibrarySortCriterion criterion) =>
      _setValue(
        unchanged: () => librarySortCriterion == criterion,
        update: () => librarySortCriterion = criterion,
      );

  Future<void> setLibrarySortAscending(bool ascending) => _setValue(
    unchanged: () => librarySortAscending == ascending,
    update: () => librarySortAscending = ascending,
  );

  Future<void> setLibraryGroupByLibrary(bool enabled) => _setValue(
    unchanged: () => libraryGroupByLibrary == enabled,
    update: () => libraryGroupByLibrary = enabled,
  );

  Future<void> setLibrarySortOptions({
    required LibrarySortCriterion criterion,
    required bool ascending,
    required bool groupByLibrary,
  }) => _setValue(
    unchanged: () =>
        librarySortCriterion == criterion &&
        librarySortAscending == ascending &&
        libraryGroupByLibrary == groupByLibrary,
    update: () {
      librarySortCriterion = criterion;
      librarySortAscending = ascending;
      libraryGroupByLibrary = groupByLibrary;
    },
  );

  Future<void> setPlaylistSortCriterion(PlaylistSortCriterion criterion) =>
      _setValue(
        unchanged: () => playlistSortCriterion == criterion,
        update: () => playlistSortCriterion = criterion,
      );

  Future<void> setPlaylistSortAscending(bool ascending) => _setValue(
    unchanged: () => playlistSortAscending == ascending,
    update: () => playlistSortAscending = ascending,
  );

  Future<void> setPlaylistGroupByLibrary(bool enabled) => _setValue(
    unchanged: () => playlistGroupByLibrary == enabled,
    update: () => playlistGroupByLibrary = enabled,
  );

  Future<void> setPlaylistSortOptions({
    required PlaylistSortCriterion criterion,
    required bool ascending,
    required bool groupByLibrary,
  }) => _setValue(
    unchanged: () =>
        playlistSortCriterion == criterion &&
        playlistSortAscending == ascending &&
        playlistGroupByLibrary == groupByLibrary,
    update: () {
      playlistSortCriterion = criterion;
      playlistSortAscending = ascending;
      playlistGroupByLibrary = groupByLibrary;
    },
  );

  Future<void> pinLibraryPaths(Iterable<String> paths) {
    final normalized = paths.map(PathMatcher.normalize).toList(growable: false);
    return _change(() async {
      pinnedLibraryPaths = <String>{
        ...pinnedLibraryPaths,
        ...normalized,
      }.toList();
    });
  }

  Future<void> unpinLibraryPaths(Iterable<String> paths) {
    final targets = paths.map(PathMatcher.normalize).toSet();
    return _change(() async {
      pinnedLibraryPaths = pinnedLibraryPaths
          .where((p) => !targets.contains(p))
          .toList();
    });
  }

  Future<void> toggleLibraryPathsPinned(Iterable<String> paths) {
    final normalized = paths.map(PathMatcher.normalize).toList(growable: false);
    return _change(() async {
      if (normalized.isEmpty) return;
      final allPinned = normalized.every(pinnedLibraryPaths.contains);
      pinnedLibraryPaths = allPinned
          ? pinnedLibraryPaths.where((p) => !normalized.contains(p)).toList()
          : <String>{...pinnedLibraryPaths, ...normalized}.toList();
    });
  }

  Future<void> toggleLibraryPathPinned(String path) =>
      toggleLibraryPathsPinned([path]);
  Future<void> unpinLibraryPath(String path) => unpinLibraryPaths([path]);

  Future<void> pinPlaylistSessions(Iterable<String> sessionIds) {
    final ids = sessionIds.toList(growable: false);
    return _change(() async {
      pinnedPlaylistSessionIds = <String>{
        ...pinnedPlaylistSessionIds,
        ...ids,
      }.toList();
    });
  }

  Future<void> unpinPlaylistSessions(Iterable<String> sessionIds) {
    final targets = sessionIds.toSet();
    return _change(() async {
      pinnedPlaylistSessionIds = pinnedPlaylistSessionIds
          .where((id) => !targets.contains(id))
          .toList();
    });
  }

  Future<void> togglePlaylistSessionsPinned(Iterable<String> sessionIds) {
    final ids = sessionIds.toList(growable: false);
    return _change(() async {
      if (ids.isEmpty) return;
      final allPinned = ids.every(pinnedPlaylistSessionIds.contains);
      pinnedPlaylistSessionIds = allPinned
          ? pinnedPlaylistSessionIds.where((id) => !ids.contains(id)).toList()
          : <String>{...pinnedPlaylistSessionIds, ...ids}.toList();
    });
  }

  Future<void> togglePlaylistSessionPinned(String sessionId) =>
      togglePlaylistSessionsPinned([sessionId]);
  Future<void> unpinPlaylistSession(String sessionId) =>
      unpinPlaylistSessions([sessionId]);

  Future<void> saveCustomEqPreset(EqPreset preset) => _change(() async {
    customEqPresets = <EqPreset>[...customEqPresets, preset];
  });

  Future<void> deleteCustomEqPreset(
    String id, {
    required Future<bool> Function() resetSessions,
  }) => _change(
    () async {
      customEqPresets = customEqPresets
          .where((preset) => preset.id != id)
          .toList();
    },
    afterSave: (previous) async {
      if (!await resetSessions()) {
        final savedPresets = customEqPresets;
        customEqPresets = previous.customEqPresets;
        try {
          await persist();
        } catch (_) {
          customEqPresets = savedPresets;
          rethrow;
        }
      }
    },
  );

  Future<void> setAutoCheckUpdates(bool enabled) => _setValue(
    unchanged: () => autoCheckUpdates == enabled,
    update: () => autoCheckUpdates = enabled,
  );

  Future<void> setDlsiteMetadataLanguage(ContentLanguagePreference language) =>
      _setValue(
        unchanged: () => dlsiteMetadataLanguage == language,
        update: () => dlsiteMetadataLanguage = language,
      );

  Future<void> setMaxCacheBytes(
    int bytes, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => maxCacheBytes == bytes,
    update: () => maxCacheBytes = bytes,
    afterSave: afterSave,
  );

  Future<void> setAsmrPlaybackCacheEnabled(bool enabled) => _setValue(
    unchanged: () => asmrPlaybackCacheEnabled == enabled,
    update: () => asmrPlaybackCacheEnabled = enabled,
  );

  Future<void> setRecordPlaybackProgress(bool enabled) => _setValue(
    unchanged: () => recordPlaybackProgress == enabled,
    update: () => recordPlaybackProgress = enabled,
  );

  Future<void> setAllowVideoPlayback(bool enabled) => _setValue(
    unchanged: () => allowVideoPlayback == enabled,
    update: () => allowVideoPlayback = enabled,
  );

  Future<void> setBlurPlayerBackgroundEnabled(bool enabled) => _setValue(
    unchanged: () => blurPlayerBackgroundEnabled == enabled,
    update: () => blurPlayerBackgroundEnabled = enabled,
  );

  Future<void> setUiBlurEffectEnabled(bool enabled) => _setValue(
    unchanged: () => uiBlurEffectEnabled == enabled,
    update: () => uiBlurEffectEnabled = enabled,
  );

  Future<void> setHapticFeedbackEnabled(bool enabled) => _setValue(
    unchanged: () => hapticFeedbackEnabled == enabled,
    update: () {
      hapticFeedbackEnabled = enabled;
      AppInteractionFeedbackSettings.hapticFeedbackEnabled = enabled;
    },
  );

  Future<void> setShowLocalLibrary(bool enabled) => _change(() async {
    if (!enabled && !showAsmrOne) return;
    showLocalLibrary = enabled;
    if (!enabled && startupPage == StartupPage.library) {
      startupPage = StartupPage.asmrOne;
    }
  });

  Future<void> setShowAsmrOne(bool enabled) => _change(() async {
    if (!enabled && !showLocalLibrary) return;
    showAsmrOne = enabled;
    if (!enabled && startupPage == StartupPage.asmrOne) {
      startupPage = StartupPage.library;
    }
  });

  Future<void> setStartupPage(StartupPage page) => _setValue(
    unchanged: () => startupPage == page,
    update: () => startupPage = page,
  );

  Future<void> setPortraitLockEnabled(bool enabled) => _setValue(
    unchanged: () => portraitLockEnabled == enabled,
    update: () => portraitLockEnabled = enabled,
  );

  Future<void> setCoverImageResolution(
    CoverImageResolution resolution, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => coverImageResolution == resolution,
    update: () => coverImageResolution = resolution,
    afterSave: afterSave,
  );

  Future<void> setCoverImageDisplayMode(CoverImageDisplayMode mode) =>
      _setValue(
        unchanged: () => coverImageDisplayMode == mode,
        update: () => coverImageDisplayMode = mode,
      );

  Future<void> setWorkNameDisplay(WorkNameDisplay mode) => _setValue(
    unchanged: () => workNameDisplay == mode,
    update: () => workNameDisplay = mode,
  );

  Future<void> setPreferEmbeddedCover(
    bool enabled, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => preferEmbeddedCover == enabled,
    update: () => preferEmbeddedCover = enabled,
    afterSave: afterSave,
  );

  Future<void> setAsmrDownloadConflictPolicy(
    AsmrDownloadConflictPolicy policy,
  ) => _setValue(
    unchanged: () => asmrDownloadConflictPolicy == policy,
    update: () => asmrDownloadConflictPolicy = policy,
  );

  Future<void> setAsmrDownloadSaveMetadata(bool enabled) => _setValue(
    unchanged: () => asmrDownloadSaveMetadata == enabled,
    update: () => asmrDownloadSaveMetadata = enabled,
  );

  Future<void> setAsmrDownloadRetryCount(int count) {
    final normalized = normalizeAsmrDownloadRetryCount(count);
    return _setValue(
      unchanged: () => asmrDownloadRetryCount == normalized,
      update: () => asmrDownloadRetryCount = normalized,
    );
  }

  Future<void> setAsmrDownloadThreadCount(int count) {
    final normalized = normalizeAsmrDownloadThreadCount(count);
    return _setValue(
      unchanged: () => asmrDownloadThreadCount == normalized,
      update: () => asmrDownloadThreadCount = normalized,
    );
  }

  Future<void> setAsmrDownloadSaveCover(bool enabled) => _setValue(
    unchanged: () => asmrDownloadSaveCover == enabled,
    update: () => asmrDownloadSaveCover = enabled,
  );

  Future<void> setAsmrDownloadFolderNameFields(
    Iterable<AsmrDownloadFolderNameField> fields,
  ) {
    final normalized = normalizeAsmrDownloadFolderNameFields(fields);
    return _change(() async {
      asmrDownloadFolderNameFields = normalized;
    });
  }

  Future<void> setAudioDeviceDisconnectBehavior(
    AudioDeviceDisconnectBehavior behavior, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => audioDeviceDisconnectBehavior == behavior,
    update: () => audioDeviceDisconnectBehavior = behavior,
    afterSave: afterSave,
  );

  Future<void> setAudioFocusStrategy(
    AudioFocusStrategy strategy, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => audioFocusStrategy == strategy,
    update: () => audioFocusStrategy = strategy,
    afterSave: afterSave,
  );

  Future<void> setTransientAudioFocusLossBehavior(
    TransientAudioFocusLossBehavior behavior, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => transientAudioFocusLossBehavior == behavior,
    update: () => transientAudioFocusLossBehavior = behavior,
    afterSave: afterSave,
  );

  Future<void> setInterruptionResumeBehavior(
    InterruptionResumeBehavior behavior, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => interruptionResumeBehavior == behavior,
    update: () => interruptionResumeBehavior = behavior,
    afterSave: afterSave,
  );

  Future<void> setReduceAnimations(bool enabled) => _setValue(
    unchanged: () => reduceAnimations == enabled,
    update: () => reduceAnimations = enabled,
  );

  Future<void> setSleepModeAutoTrigger(SleepModeAutoTrigger trigger) =>
      _setValue(
        unchanged: () => sleepModeAutoTrigger == trigger,
        update: () => sleepModeAutoTrigger = trigger,
      );

  Future<void> _setValue({
    required bool Function() unchanged,
    required void Function() update,
    Future<void> Function()? afterSave,
  }) => _change(() async {
    if (!unchanged()) update();
  }, afterSave: afterSave == null ? null : (_) => afterSave());

  Future<void> _writeTail = Future<void>.value();

  Future<void> _change(
    Future<void> Function() update, {
    bool converter = false,
    Future<void> Function(SettingsState)? afterSave,
  }) {
    final operation = _writeTail.then((_) async {
      final snapshot = _snapshot(isInitialized: slice.state.isInitialized);
      try {
        try {
          await update();
          if (_snapshot(isInitialized: snapshot.isInitialized) == snapshot) {
            return;
          }
          if (converter) {
            await _persistConverterSettings();
          } else {
            await persist();
          }
        } catch (_) {
          _restore(snapshot);
          rethrow;
        }
        // Side effects run after the commit while the queue is still held.
        // Their failure must not undo only the in-memory copy of saved settings.
        await afterSave?.call(snapshot);
      } finally {
        syncSlice(isInitialized: snapshot.isInitialized);
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _restore(SettingsState snapshot) {
    converterFormat = snapshot.converterFormat;
    converterBitrate = snapshot.converterBitrate;
    converterOutputDirectoryPath = snapshot.converterOutputDirectoryPath;
    autoCheckUpdates = snapshot.autoCheckUpdates;
    dlsiteMetadataLanguage = snapshot.dlsiteMetadataLanguage;
    librarySortCriterion = snapshot.librarySortCriterion;
    librarySortAscending = snapshot.librarySortAscending;
    libraryGroupByLibrary = snapshot.libraryGroupByLibrary;
    pinnedLibraryPaths = snapshot.pinnedLibraryPaths;
    playlistSortCriterion = snapshot.playlistSortCriterion;
    playlistSortAscending = snapshot.playlistSortAscending;
    playlistGroupByLibrary = snapshot.playlistGroupByLibrary;
    pinnedPlaylistSessionIds = snapshot.pinnedPlaylistSessionIds;
    customEqPresets = snapshot.customEqPresets;
    maxCacheBytes = snapshot.maxCacheBytes;
    asmrPlaybackCacheEnabled = snapshot.asmrPlaybackCacheEnabled;
    recordPlaybackProgress = snapshot.recordPlaybackProgress;
    allowVideoPlayback = snapshot.allowVideoPlayback;
    blurPlayerBackgroundEnabled = snapshot.blurPlayerBackgroundEnabled;
    uiBlurEffectEnabled = snapshot.uiBlurEffectEnabled;
    hapticFeedbackEnabled = snapshot.hapticFeedbackEnabled;
    showLocalLibrary = snapshot.showLocalLibrary;
    showAsmrOne = snapshot.showAsmrOne;
    workNameDisplay = snapshot.workNameDisplay;
    startupPage = snapshot.startupPage;
    portraitLockEnabled = snapshot.portraitLockEnabled;
    coverImageResolution = snapshot.coverImageResolution;
    coverImageDisplayMode = snapshot.coverImageDisplayMode;
    preferEmbeddedCover = snapshot.preferEmbeddedCover;
    asmrDownloadDestinationRoot = snapshot.asmrDownloadDestinationRoot;
    asmrDownloadConflictPolicy = snapshot.asmrDownloadConflictPolicy;
    asmrDownloadRetryCount = snapshot.asmrDownloadRetryCount;
    asmrDownloadThreadCount = snapshot.asmrDownloadThreadCount;
    asmrDownloadSaveMetadata = snapshot.asmrDownloadSaveMetadata;
    asmrDownloadSaveCover = snapshot.asmrDownloadSaveCover;
    asmrDownloadFolderNameFields = snapshot.asmrDownloadFolderNameFields;
    audioDeviceDisconnectBehavior = snapshot.audioDeviceDisconnectBehavior;
    audioFocusStrategy = snapshot.audioFocusStrategy;
    transientAudioFocusLossBehavior = snapshot.transientAudioFocusLossBehavior;
    interruptionResumeBehavior = snapshot.interruptionResumeBehavior;
    sleepModeAutoTrigger = snapshot.sleepModeAutoTrigger;
    reduceAnimations = snapshot.reduceAnimations;
    AppInteractionFeedbackSettings.hapticFeedbackEnabled =
        hapticFeedbackEnabled;
  }

  void _resetValues() {
    converterFormat = 'mp3';
    converterBitrate = '320k';
    converterOutputDirectoryPath = null;
    autoCheckUpdates = false;
    dlsiteMetadataLanguage = ContentLanguagePreference.followPage;
    librarySortCriterion = LibrarySortCriterion.name;
    librarySortAscending = true;
    libraryGroupByLibrary = false;
    pinnedLibraryPaths = <String>[];
    playlistSortCriterion = PlaylistSortCriterion.name;
    playlistSortAscending = true;
    playlistGroupByLibrary = false;
    pinnedPlaylistSessionIds = <String>[];
    customEqPresets = const <EqPreset>[];
    maxCacheBytes = AppCacheService.defaultMaxCacheBytes;
    asmrPlaybackCacheEnabled = false;
    recordPlaybackProgress = true;
    allowVideoPlayback = true;
    blurPlayerBackgroundEnabled = true;
    uiBlurEffectEnabled = true;
    hapticFeedbackEnabled = true;
    AppInteractionFeedbackSettings.hapticFeedbackEnabled = true;
    showLocalLibrary = true;
    showAsmrOne = true;
    workNameDisplay = WorkNameDisplay.workTitle;
    startupPage = StartupPage.library;
    portraitLockEnabled = false;
    coverImageResolution = CoverImageResolution.balanced;
    coverImageDisplayMode = CoverImageDisplayMode.fill;
    preferEmbeddedCover = true;
    asmrDownloadDestinationRoot = null;
    asmrDownloadConflictPolicy = AsmrDownloadConflictPolicy.overwrite;
    asmrDownloadRetryCount = kDefaultAsmrDownloadRetryCount;
    asmrDownloadThreadCount = kDefaultAsmrDownloadThreadCount;
    asmrDownloadSaveMetadata = true;
    asmrDownloadSaveCover = true;
    asmrDownloadFolderNameFields = kDefaultAsmrDownloadFolderNameFields;
    audioDeviceDisconnectBehavior = AudioDeviceDisconnectBehavior.pause;
    audioFocusStrategy = AudioFocusStrategy.standard;
    transientAudioFocusLossBehavior = TransientAudioFocusLossBehavior.duck;
    interruptionResumeBehavior = InterruptionResumeBehavior.resume;
    reduceAnimations = false;
    sleepModeAutoTrigger = SleepModeAutoTrigger.manual;
  }

  String? _optionalString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<EqPreset> _decodeEqPresets(Object? value) {
    if (value is! List) return const <EqPreset>[];
    return value
        .map(EqPreset.fromJson)
        .where((preset) => preset.id.isNotEmpty && preset.labelKey.isNotEmpty)
        .toList(growable: false);
  }

  void syncSlice({bool isInitialized = false}) {
    slice.update(_snapshot(isInitialized: isInitialized));
  }

  SettingsState _snapshot({required bool isInitialized}) {
    final previous = slice.state;
    return SettingsState(
      converterFormat: converterFormat,
      converterBitrate: converterBitrate,
      converterOutputDirectoryPath: converterOutputDirectoryPath,
      autoCheckUpdates: autoCheckUpdates,
      dlsiteMetadataLanguage: dlsiteMetadataLanguage,
      librarySortCriterion: librarySortCriterion,
      librarySortAscending: librarySortAscending,
      libraryGroupByLibrary: libraryGroupByLibrary,
      pinnedLibraryPaths:
          listEquals(previous.pinnedLibraryPaths, pinnedLibraryPaths)
          ? previous.pinnedLibraryPaths
          : pinnedLibraryPaths,
      playlistSortCriterion: playlistSortCriterion,
      playlistSortAscending: playlistSortAscending,
      playlistGroupByLibrary: playlistGroupByLibrary,
      pinnedPlaylistSessionIds:
          listEquals(
            previous.pinnedPlaylistSessionIds,
            pinnedPlaylistSessionIds,
          )
          ? previous.pinnedPlaylistSessionIds
          : pinnedPlaylistSessionIds,
      customEqPresets: List<EqPreset>.unmodifiable(customEqPresets),
      maxCacheBytes: maxCacheBytes,
      asmrPlaybackCacheEnabled: asmrPlaybackCacheEnabled,
      recordPlaybackProgress: recordPlaybackProgress,
      allowVideoPlayback: allowVideoPlayback,
      blurPlayerBackgroundEnabled: blurPlayerBackgroundEnabled,
      uiBlurEffectEnabled: uiBlurEffectEnabled,
      hapticFeedbackEnabled: hapticFeedbackEnabled,
      showLocalLibrary: showLocalLibrary,
      showAsmrOne: showAsmrOne,
      workNameDisplay: workNameDisplay,
      startupPage: startupPage,
      portraitLockEnabled: portraitLockEnabled,
      coverImageResolution: coverImageResolution,
      coverImageDisplayMode: coverImageDisplayMode,
      preferEmbeddedCover: preferEmbeddedCover,
      asmrDownloadDestinationRoot: asmrDownloadDestinationRoot,
      asmrDownloadConflictPolicy: asmrDownloadConflictPolicy,
      asmrDownloadRetryCount: asmrDownloadRetryCount,
      asmrDownloadThreadCount: asmrDownloadThreadCount,
      asmrDownloadSaveMetadata: asmrDownloadSaveMetadata,
      asmrDownloadSaveCover: asmrDownloadSaveCover,
      asmrDownloadFolderNameFields:
          List<AsmrDownloadFolderNameField>.unmodifiable(
            asmrDownloadFolderNameFields,
          ),
      audioDeviceDisconnectBehavior: audioDeviceDisconnectBehavior,
      audioFocusStrategy: audioFocusStrategy,
      transientAudioFocusLossBehavior: transientAudioFocusLossBehavior,
      interruptionResumeBehavior: interruptionResumeBehavior,
      reduceAnimations: reduceAnimations,
      sleepModeAutoTrigger: sleepModeAutoTrigger,
      isInitialized: isInitialized,
    );
  }

  Future<void> dispose() async {
    await _writeTail;
    await slice.dispose();
  }
}
