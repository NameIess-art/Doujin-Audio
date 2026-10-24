import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/network/network_route_settings.dart';
import '../../asmr/domain/asmr_media_sources.dart';

import '../../../core/state/audio_state_slice.dart';
import '../../../core/app_language.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/ui/app_interaction_feedback_settings.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../player/domain/audio_effects.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../../core/persistence/app_preferences.dart';
import 'settings_state.dart';

class SettingsRepository {
  SettingsRepository({
    this.onNetworkRouteChanged,
    Future<String?> Function()? readProxyPassword,
    Future<void> Function(String?)? writeProxyPassword,
  }) : _readProxyPassword = readProxyPassword ?? _readSecureProxyPassword,
       _writeProxyPassword = writeProxyPassword ?? _writeSecureProxyPassword;

  static const proxyPasswordKey = 'network_proxy_password_v1';
  static Future<String?> _readSecureProxyPassword() =>
      const FlutterSecureStorage().read(key: proxyPasswordKey);
  static Future<void> _writeSecureProxyPassword(String? value) => value == null
      ? const FlutterSecureStorage().delete(key: proxyPasswordKey)
      : const FlutterSecureStorage().write(key: proxyPasswordKey, value: value);
  final Future<void> Function(NetworkRouteSettings, String?)?
  onNetworkRouteChanged;
  final Future<String?> Function() _readProxyPassword;
  final Future<void> Function(String?) _writeProxyPassword;
  NetworkRouteSettings networkRouteSettings = const NetworkRouteSettings();
  String asmrApiDomain = asmrApiDomains.first;

  static const _playbackSettingsKey = 'playback_settings_v1';
  bool autoCheckUpdates = false;
  ContentLanguagePreference dlsiteMetadataLanguage =
      ContentLanguagePreference.followPage;
  LibrarySortCriterion librarySortCriterion = LibrarySortCriterion.name;
  bool librarySortAscending = true;
  bool libraryGroupByLibrary = false;
  List<String> pinnedLibraryPaths = <String>[];
  List<String> librarySearchHistory = const <String>[];
  List<String> asmrSearchHistory = const <String>[];
  PlaylistSortCriterion playlistSortCriterion = PlaylistSortCriterion.name;
  bool playlistSortAscending = true;
  bool playlistGroupByLibrary = false;
  List<String> pinnedPlaylistSessionIds = <String>[];
  List<EqPreset> customEqPresets = const <EqPreset>[];
  int maxCacheBytes = AppCacheService.defaultMaxCacheBytes;
  bool asmrPlaybackCacheEnabled = true;
  bool recordPlaybackProgress = true;
  bool allowVideoPlayback = true;
  bool hapticFeedbackEnabled = true;
  bool showLocalLibrary = true;
  bool showAsmrOne = true;
  WorkNameDisplay workNameDisplay = WorkNameDisplay.workTitle;
  ListeningChartStyle listeningChartStyle = ListeningChartStyle.bar;
  MySettingsPageMode mySettingsPageMode = MySettingsPageMode.settings;
  StartupPage startupPage = StartupPage.library;
  CoverImageResolution coverImageResolution = CoverImageResolution.balanced;
  bool preferEmbeddedCover = false;
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

  Future<void> loadPersistedState({bool enforceCacheLimit = true}) async {
    _resetValues();
    final playback = await AppPreferences.readJson<Map<String, dynamic>>(
      _playbackSettingsKey,
      (value) => (value as Map<Object?, Object?>).map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    );
    if (playback != null) {
      networkRouteSettings = NetworkRouteSettings.fromJson(
        playback['networkRouteSettings'],
      );
      if (asmrApiDomains.contains(playback['asmrApiDomain'])) {
        asmrApiDomain = playback['asmrApiDomain'] as String;
      }
      startupPage = StartupPage.values.firstWhere(
        (value) => value.name == playback['startupPage'],
        orElse: () => StartupPage.library,
      );
      autoCheckUpdates = playback['autoCheckUpdates'] as bool? ?? false;
      recordPlaybackProgress =
          playback['recordPlaybackProgress'] as bool? ?? true;
      allowVideoPlayback = playback['allowVideoPlayback'] as bool? ?? true;
      asmrPlaybackCacheEnabled =
          playback['asmrPlaybackCacheEnabled'] as bool? ?? true;
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
      listeningChartStyle = ListeningChartStyle.values.firstWhere(
        (value) => value.name == playback['listeningChartStyle'],
        orElse: () => ListeningChartStyle.bar,
      );
      mySettingsPageMode = MySettingsPageMode.values.firstWhere(
        (value) => value.name == playback['mySettingsPageMode'],
        orElse: () => MySettingsPageMode.settings,
      );
      if (!showLocalLibrary && !showAsmrOne) {
        showLocalLibrary = true;
      }
      coverImageResolution = CoverImageResolution.values.firstWhere(
        (value) => value.name == playback['coverImageResolution'],
        orElse: () => CoverImageResolution.balanced,
      );
      // Older builds stored this preference under the audio-only key.
      preferEmbeddedCover =
          playback['preferEmbeddedCover'] as bool? ??
          playback['preferEmbeddedAudioCover'] as bool? ??
          false;
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
      librarySearchHistory = _decodeSearchHistory(
        playback['librarySearchHistory'],
      );
      asmrSearchHistory = _decodeSearchHistory(playback['asmrSearchHistory']);
      maxCacheBytes =
          (playback['maxCacheBytes'] as num?)?.toInt() ??
          AppCacheService.defaultMaxCacheBytes;
    }

    await AppCacheService.setMaxCacheBytes(
      maxCacheBytes,
      enforceImmediately: enforceCacheLimit,
    );
    await _applyNetworkRoute();
    syncSlice(isInitialized: true);
  }

  Future<void> resetPersistedState() async {
    _resetValues();
    await _applyNetworkRoute();
    syncSlice();
  }

  Future<void> persist() async {
    final saved = await AppPreferences.writeJson(
      _playbackSettingsKey,
      <String, Object?>{
        'networkRouteSettings': networkRouteSettings.toJson(),
        'asmrApiDomain': asmrApiDomain,
        'startupPage': startupPage.name,
        'autoCheckUpdates': autoCheckUpdates,
        'recordPlaybackProgress': recordPlaybackProgress,
        'allowVideoPlayback': allowVideoPlayback,
        'asmrPlaybackCacheEnabled': asmrPlaybackCacheEnabled,
        'hapticFeedbackEnabled': hapticFeedbackEnabled,
        'showLocalLibrary': showLocalLibrary,
        'showAsmrOne': showAsmrOne,
        'workNameDisplay': workNameDisplay.name,
        'listeningChartStyle': listeningChartStyle.name,
        'mySettingsPageMode': mySettingsPageMode.name,
        'coverImageResolution': coverImageResolution.name,
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
        'librarySearchHistory': librarySearchHistory,
        'asmrSearchHistory': asmrSearchHistory,
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

  Future<void> _applyNetworkRoute() async {
    final secret = networkRouteSettings.proxyPasswordConfigured
        ? await _readProxyPassword()
        : null;
    networkRouteSettings = networkRouteSettings.copyWith(
      proxyPasswordConfigured: secret?.isNotEmpty == true,
    );
    await onNetworkRouteChanged?.call(networkRouteSettings, secret);
  }

  Future<void> setNetworkRouteSettings(
    NetworkRouteSettings value, {
    String? password,
  }) {
    String? previousPassword;
    var secretChanged = false;
    final hasNewPassword = password != null && password.isNotEmpty;
    return _change(
      () async {
        previousPassword =
            value.proxyPasswordConfigured ||
                networkRouteSettings.proxyPasswordConfigured ||
                hasNewPassword
            ? await _readProxyPassword()
            : null;
        final committed = value.copyWith(
          proxyHost:
              NetworkRouteSettings.normalizeHost(value.proxyHost) ??
              value.proxyHost.trim(),
          proxyUsername: value.proxyUsername.trim(),
          customDnsServer:
              NetworkRouteSettings.normalizeDns(value.customDnsServer) ??
              value.customDnsServer.trim(),
          proxyPasswordConfigured:
              hasNewPassword || previousPassword?.isNotEmpty == true,
        );
        committed.validate();
        if (committed.proxyMode == AppProxyMode.socks5 &&
            committed.proxyAuthenticationEnabled &&
            utf8.encode(hasNewPassword ? password : previousPassword!).length >
                255) {
          throw const FormatException(
            'SOCKS5 password exceeds 255 UTF-8 bytes',
          );
        }
        if (hasNewPassword) {
          await _writeProxyPassword(password);
          secretChanged = true;
        }
        networkRouteSettings = committed;
      },
      // An explicit apply also retries a previous native synchronization error.
      forceSave: true,
      onFailure: () async {
        if (secretChanged) await _writeProxyPassword(previousPassword);
      },
      afterSave: (_) => _applyNetworkRoute(),
    );
  }

  Future<void> setAsmrApiDomain(String domain) {
    if (!asmrApiDomains.contains(domain)) {
      throw ArgumentError.value(domain, 'domain');
    }
    return _setValue(
      unchanged: () => asmrApiDomain == domain,
      update: () => asmrApiDomain = domain,
    );
  }

  Future<void> setAsmrDownloadDestinationRoot(String? destinationRoot) =>
      _change(() async {
        asmrDownloadDestinationRoot = _optionalString(destinationRoot);
      });

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

  Future<void> recordSearchQuery(String query, {required bool online}) {
    final normalized = canonicalSearchQuery(query);
    if (normalized.isEmpty) return Future<void>.value();
    return _change(() async {
      final history = online ? asmrSearchHistory : librarySearchHistory;
      final next = _decodeSearchHistory(<String>[normalized, ...history]);
      if (online) {
        asmrSearchHistory = next;
      } else {
        librarySearchHistory = next;
      }
    });
  }

  Future<List<String>> clearSearchHistory({required bool online}) async {
    var removed = const <String>[];
    await _change(() async {
      removed = List<String>.unmodifiable(
        online ? asmrSearchHistory : librarySearchHistory,
      );
      if (online) {
        asmrSearchHistory = const <String>[];
      } else {
        librarySearchHistory = const <String>[];
      }
    });
    return removed;
  }

  Future<void> restoreSearchHistory(
    List<String> removed, {
    required bool online,
  }) => _change(() async {
    final history = online ? asmrSearchHistory : librarySearchHistory;
    final restored = _decodeSearchHistory(<String>[...history, ...removed]);
    if (online) {
      asmrSearchHistory = restored;
    } else {
      librarySearchHistory = restored;
    }
  });

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

  Future<void> setCoverImageResolution(
    CoverImageResolution resolution, {
    Future<void> Function()? afterSave,
  }) => _setValue(
    unchanged: () => coverImageResolution == resolution,
    update: () => coverImageResolution = resolution,
    afterSave: afterSave,
  );

  Future<void> setWorkNameDisplay(WorkNameDisplay mode) => _setValue(
    unchanged: () => workNameDisplay == mode,
    update: () => workNameDisplay = mode,
  );

  Future<void> setListeningChartStyle(ListeningChartStyle style) => _setValue(
    unchanged: () => listeningChartStyle == style,
    update: () => listeningChartStyle = style,
  );

  Future<void> setMySettingsPageMode(MySettingsPageMode mode) => _setValue(
    unchanged: () => mySettingsPageMode == mode,
    update: () => mySettingsPageMode = mode,
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
    Future<void> Function(SettingsState)? afterSave,
    Future<void> Function()? onFailure,
    bool forceSave = false,
  }) {
    final operation = _writeTail.then((_) async {
      final snapshot = _snapshot(isInitialized: slice.state.isInitialized);
      try {
        try {
          await update();
          if (!forceSave &&
              _snapshot(isInitialized: snapshot.isInitialized) == snapshot) {
            return;
          }
          await persist();
        } catch (_) {
          _restore(snapshot);
          await onFailure?.call();
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
    networkRouteSettings = snapshot.networkRouteSettings;
    asmrApiDomain = snapshot.asmrApiDomain;
    autoCheckUpdates = snapshot.autoCheckUpdates;
    dlsiteMetadataLanguage = snapshot.dlsiteMetadataLanguage;
    librarySortCriterion = snapshot.librarySortCriterion;
    librarySortAscending = snapshot.librarySortAscending;
    libraryGroupByLibrary = snapshot.libraryGroupByLibrary;
    pinnedLibraryPaths = snapshot.pinnedLibraryPaths;
    librarySearchHistory = snapshot.librarySearchHistory;
    asmrSearchHistory = snapshot.asmrSearchHistory;
    playlistSortCriterion = snapshot.playlistSortCriterion;
    playlistSortAscending = snapshot.playlistSortAscending;
    playlistGroupByLibrary = snapshot.playlistGroupByLibrary;
    pinnedPlaylistSessionIds = snapshot.pinnedPlaylistSessionIds;
    customEqPresets = snapshot.customEqPresets;
    maxCacheBytes = snapshot.maxCacheBytes;
    asmrPlaybackCacheEnabled = snapshot.asmrPlaybackCacheEnabled;
    recordPlaybackProgress = snapshot.recordPlaybackProgress;
    allowVideoPlayback = snapshot.allowVideoPlayback;
    hapticFeedbackEnabled = snapshot.hapticFeedbackEnabled;
    showLocalLibrary = snapshot.showLocalLibrary;
    showAsmrOne = snapshot.showAsmrOne;
    workNameDisplay = snapshot.workNameDisplay;
    listeningChartStyle = snapshot.listeningChartStyle;
    mySettingsPageMode = snapshot.mySettingsPageMode;
    startupPage = snapshot.startupPage;
    coverImageResolution = snapshot.coverImageResolution;
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
    networkRouteSettings = const NetworkRouteSettings();
    asmrApiDomain = asmrApiDomains.first;
    autoCheckUpdates = false;
    dlsiteMetadataLanguage = ContentLanguagePreference.followPage;
    librarySortCriterion = LibrarySortCriterion.name;
    librarySortAscending = true;
    libraryGroupByLibrary = false;
    pinnedLibraryPaths = <String>[];
    librarySearchHistory = const <String>[];
    asmrSearchHistory = const <String>[];
    playlistSortCriterion = PlaylistSortCriterion.name;
    playlistSortAscending = true;
    playlistGroupByLibrary = false;
    pinnedPlaylistSessionIds = <String>[];
    customEqPresets = const <EqPreset>[];
    maxCacheBytes = AppCacheService.defaultMaxCacheBytes;
    asmrPlaybackCacheEnabled = true;
    recordPlaybackProgress = true;
    allowVideoPlayback = true;
    hapticFeedbackEnabled = true;
    AppInteractionFeedbackSettings.hapticFeedbackEnabled = true;
    showLocalLibrary = true;
    showAsmrOne = true;
    workNameDisplay = WorkNameDisplay.workTitle;
    listeningChartStyle = ListeningChartStyle.bar;
    mySettingsPageMode = MySettingsPageMode.settings;
    startupPage = StartupPage.library;
    coverImageResolution = CoverImageResolution.balanced;
    preferEmbeddedCover = false;
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

  List<String> _decodeSearchHistory(Object? value) {
    if (value is! List) return const <String>[];
    final seen = <String>{};
    return List<String>.unmodifiable(
      value
          .whereType<String>()
          .map(canonicalSearchQuery)
          .where((query) {
            return query.isNotEmpty && seen.add(query.toLowerCase());
          })
          .take(50),
    );
  }

  void syncSlice({bool isInitialized = false}) {
    slice.update(_snapshot(isInitialized: isInitialized));
  }

  SettingsState _snapshot({required bool isInitialized}) {
    final previous = slice.state;
    return SettingsState(
      networkRouteSettings: networkRouteSettings,
      asmrApiDomain: asmrApiDomain,
      autoCheckUpdates: autoCheckUpdates,
      dlsiteMetadataLanguage: dlsiteMetadataLanguage,
      librarySortCriterion: librarySortCriterion,
      librarySortAscending: librarySortAscending,
      libraryGroupByLibrary: libraryGroupByLibrary,
      pinnedLibraryPaths:
          listEquals(previous.pinnedLibraryPaths, pinnedLibraryPaths)
          ? previous.pinnedLibraryPaths
          : pinnedLibraryPaths,
      librarySearchHistory:
          listEquals(previous.librarySearchHistory, librarySearchHistory)
          ? previous.librarySearchHistory
          : librarySearchHistory,
      asmrSearchHistory:
          listEquals(previous.asmrSearchHistory, asmrSearchHistory)
          ? previous.asmrSearchHistory
          : asmrSearchHistory,
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
      hapticFeedbackEnabled: hapticFeedbackEnabled,
      showLocalLibrary: showLocalLibrary,
      showAsmrOne: showAsmrOne,
      workNameDisplay: workNameDisplay,
      listeningChartStyle: listeningChartStyle,
      mySettingsPageMode: mySettingsPageMode,
      startupPage: startupPage,
      coverImageResolution: coverImageResolution,
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
