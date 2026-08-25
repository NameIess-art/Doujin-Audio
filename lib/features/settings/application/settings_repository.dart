import 'package:flutter/foundation.dart';

import '../../../core/state/audio_state_slice.dart';
import '../../../core/app_language.dart';
import '../../../core/media/card_info_field.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../player/domain/audio_effects.dart';
import 'app_cache_service.dart';
import 'app_preferences.dart';
import 'settings_state.dart';

class SettingsRepository {
  static const _playbackSettingsKey = 'playback_settings_v1';
  static const _converterSettingsKey = 'converter_settings_v1';
  static const converterFormats = <String>['mp3', 'flac', 'wav', 'aac', 'ogg'];
  static const converterBitrates = <String>['128k', '192k', '256k', '320k'];
  String converterFormat = 'mp3';
  String converterBitrate = '320k';
  bool multiThreadPlaybackEnabled = false;
  bool notificationsEnabled = true;
  bool showPlaybackCard = true;
  bool autoPlayAddedSessions = true;
  bool autoCheckUpdates = false;
  ContentLanguagePreference dlsiteMetadataLanguage =
      ContentLanguagePreference.followPage;
  List<CardInfoField> cardInfoFields = CardInfoField.defaults;
  LibrarySortCriterion librarySortCriterion = LibrarySortCriterion.name;
  bool librarySortAscending = true;
  bool libraryGroupByLibrary = false;
  PlaylistSortCriterion playlistSortCriterion = PlaylistSortCriterion.name;
  bool playlistSortAscending = true;
  bool playlistGroupByLibrary = false;
  List<EqPreset> customEqPresets = const <EqPreset>[];
  int maxCacheBytes = AppCacheService.defaultMaxCacheBytes;
  bool asmrPlaybackCacheEnabled = false;
  bool recordPlaybackProgress = true;
  bool allowVideoPlayback = true;
  bool blurPlayerBackgroundEnabled = true;
  bool uiBlurEffectEnabled = true;
  bool hapticFeedbackEnabled = true;
  StartupPage startupPage = StartupPage.library;
  bool portraitLockEnabled = false;
  BottomNavigationStyle bottomNavigationStyle = BottomNavigationStyle.capsule;
  PlaybackDetailSubtitleStyle playbackDetailSubtitleStyle =
      PlaybackDetailSubtitleStyle.compact;
  CoverImageResolution coverImageResolution = CoverImageResolution.balanced;
  CoverImageDisplayMode coverImageDisplayMode = CoverImageDisplayMode.fill;
  bool preferEmbeddedAudioCover = true;
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
  StartupPlaybackRestoreBehavior startupPlaybackRestoreBehavior =
      StartupPlaybackRestoreBehavior.resume;
  bool allowDuplicateWorks = false;
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
      multiThreadPlaybackEnabled =
          playback['multiThreadPlaybackEnabled'] as bool? ?? false;
      notificationsEnabled = playback['notificationsEnabled'] as bool? ?? true;
      showPlaybackCard = playback['showPlaybackCard'] as bool? ?? true;
      startupPage = StartupPage.values.firstWhere(
        (value) => value.name == playback['startupPage'],
        orElse: () => StartupPage.library,
      );
      portraitLockEnabled = playback['portraitLockEnabled'] as bool? ?? false;
      bottomNavigationStyle = BottomNavigationStyle.values.firstWhere(
        (value) => value.name == playback['bottomNavigationStyle'],
        orElse: () => BottomNavigationStyle.capsule,
      );
      playbackDetailSubtitleStyle = PlaybackDetailSubtitleStyle.values
          .firstWhere(
            (value) => value.name == playback['playbackDetailSubtitleStyle'],
            orElse: () => PlaybackDetailSubtitleStyle.compact,
          );
      autoPlayAddedSessions =
          playback['autoPlayAddedSessions'] as bool? ?? true;
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
      coverImageResolution = CoverImageResolution.values.firstWhere(
        (value) => value.name == playback['coverImageResolution'],
        orElse: () => CoverImageResolution.balanced,
      );
      coverImageDisplayMode = CoverImageDisplayMode.values.firstWhere(
        (value) => value.name == playback['coverImageDisplayMode'],
        orElse: () => CoverImageDisplayMode.fill,
      );
      preferEmbeddedAudioCover =
          playback['preferEmbeddedAudioCover'] as bool? ?? true;
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
      startupPlaybackRestoreBehavior = StartupPlaybackRestoreBehavior.values
          .firstWhere(
            (value) => value.name == playback['startupPlaybackRestoreBehavior'],
            orElse: () => StartupPlaybackRestoreBehavior.resume,
          );
      allowDuplicateWorks = playback['allowDuplicateWorks'] as bool? ?? false;
      reduceAnimations = playback['reduceAnimations'] as bool? ?? false;
      dlsiteMetadataLanguage = ContentLanguagePreference.fromName(
        playback['dlsiteMetadataLanguage'],
      );
      cardInfoFields = CardInfoField.decode(playback['cardInfoFields']);
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

  Future<void> persist() {
    return AppPreferences.writeJson(_playbackSettingsKey, <String, Object?>{
      'multiThreadPlaybackEnabled': multiThreadPlaybackEnabled,
      'notificationsEnabled': notificationsEnabled,
      'showPlaybackCard': showPlaybackCard,
      'startupPage': startupPage.name,
      'portraitLockEnabled': portraitLockEnabled,
      'bottomNavigationStyle': bottomNavigationStyle.name,
      'playbackDetailSubtitleStyle': playbackDetailSubtitleStyle.name,
      'autoPlayAddedSessions': autoPlayAddedSessions,
      'autoCheckUpdates': autoCheckUpdates,
      'recordPlaybackProgress': recordPlaybackProgress,
      'allowVideoPlayback': allowVideoPlayback,
      'asmrPlaybackCacheEnabled': asmrPlaybackCacheEnabled,
      'blurPlayerBackgroundEnabled': blurPlayerBackgroundEnabled,
      'uiBlurEffectEnabled': uiBlurEffectEnabled,
      'hapticFeedbackEnabled': hapticFeedbackEnabled,
      'coverImageResolution': coverImageResolution.name,
      'coverImageDisplayMode': coverImageDisplayMode.name,
      'preferEmbeddedAudioCover': preferEmbeddedAudioCover,
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
      'cardInfoFields': cardInfoFields
          .map((field) => field.name)
          .toList(growable: false),
      'librarySortCriterion': librarySortCriterion.name,
      'librarySortAscending': librarySortAscending,
      'libraryGroupByLibrary': libraryGroupByLibrary,
      'playlistSortCriterion': playlistSortCriterion.name,
      'playlistSortAscending': playlistSortAscending,
      'playlistGroupByLibrary': playlistGroupByLibrary,
      'customEqPresets': customEqPresets
          .map((preset) => preset.toJson())
          .toList(growable: false),
      'maxCacheBytes': maxCacheBytes,
      'audioDeviceDisconnectBehavior': audioDeviceDisconnectBehavior.name,
      'audioFocusStrategy': audioFocusStrategy.name,
      'transientAudioFocusLossBehavior': transientAudioFocusLossBehavior.name,
      'interruptionResumeBehavior': interruptionResumeBehavior.name,
      'startupPlaybackRestoreBehavior': startupPlaybackRestoreBehavior.name,
      'allowDuplicateWorks': allowDuplicateWorks,
      'reduceAnimations': reduceAnimations,
    });
  }

  Future<void> setConverterSettings({String? format, String? bitrate}) async {
    var changed = false;
    if (format != null &&
        converterFormats.contains(format) &&
        format != converterFormat) {
      converterFormat = format;
      changed = true;
    }
    if (bitrate != null &&
        converterBitrates.contains(bitrate) &&
        bitrate != converterBitrate) {
      converterBitrate = bitrate;
      changed = true;
    }
    if (!changed) return;
    syncSlice(isInitialized: slice.state.isInitialized);
    await _persistConverterSettings();
  }

  Future<void> _persistConverterSettings() async {
    await AppPreferences.writeJson(_converterSettingsKey, <String, Object?>{
      'format': converterFormat,
      'bitrate': converterBitrate,
    });
  }

  Future<void> setAsmrDownloadDestinationRoot(String? destinationRoot) async {
    final normalized = destinationRoot?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (asmrDownloadDestinationRoot == next) return;
    asmrDownloadDestinationRoot = next;
    syncSlice(isInitialized: slice.state.isInitialized);
    await persist();
  }

  Future<void> setCardInfoFields(Iterable<CardInfoField> fields) async {
    final normalized = CardInfoField.normalize(fields);
    if (listEquals(cardInfoFields, normalized)) return;
    cardInfoFields = normalized;
    syncSlice(isInitialized: slice.state.isInitialized);
    await persist();
  }

  Future<void> setLibrarySortCriterion(LibrarySortCriterion criterion) =>
      _setValue(
        unchanged: librarySortCriterion == criterion,
        update: () => librarySortCriterion = criterion,
      );

  Future<void> setLibrarySortAscending(bool ascending) => _setValue(
    unchanged: librarySortAscending == ascending,
    update: () => librarySortAscending = ascending,
  );

  Future<void> setLibraryGroupByLibrary(bool enabled) => _setValue(
    unchanged: libraryGroupByLibrary == enabled,
    update: () => libraryGroupByLibrary = enabled,
  );

  Future<void> setLibrarySortOptions({
    required LibrarySortCriterion criterion,
    required bool ascending,
    required bool groupByLibrary,
  }) => _setValue(
    unchanged:
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
        unchanged: playlistSortCriterion == criterion,
        update: () => playlistSortCriterion = criterion,
      );

  Future<void> setPlaylistSortAscending(bool ascending) => _setValue(
    unchanged: playlistSortAscending == ascending,
    update: () => playlistSortAscending = ascending,
  );

  Future<void> setPlaylistGroupByLibrary(bool enabled) => _setValue(
    unchanged: playlistGroupByLibrary == enabled,
    update: () => playlistGroupByLibrary = enabled,
  );

  Future<void> setPlaylistSortOptions({
    required PlaylistSortCriterion criterion,
    required bool ascending,
    required bool groupByLibrary,
  }) => _setValue(
    unchanged:
        playlistSortCriterion == criterion &&
        playlistSortAscending == ascending &&
        playlistGroupByLibrary == groupByLibrary,
    update: () {
      playlistSortCriterion = criterion;
      playlistSortAscending = ascending;
      playlistGroupByLibrary = groupByLibrary;
    },
  );

  Future<void> setMultiThreadPlaybackEnabled(bool enabled) => _setValue(
    unchanged: multiThreadPlaybackEnabled == enabled,
    update: () => multiThreadPlaybackEnabled = enabled,
  );

  Future<void> setShowPlaybackCard(bool enabled) => _setValue(
    unchanged: showPlaybackCard == enabled,
    update: () => showPlaybackCard = enabled,
  );

  Future<void> setAutoPlayAddedSessions(bool enabled) => _setValue(
    unchanged: autoPlayAddedSessions == enabled,
    update: () => autoPlayAddedSessions = enabled,
  );

  Future<void> setAutoCheckUpdates(bool enabled) => _setValue(
    unchanged: autoCheckUpdates == enabled,
    update: () => autoCheckUpdates = enabled,
  );

  Future<void> setDlsiteMetadataLanguage(ContentLanguagePreference language) =>
      _setValue(
        unchanged: dlsiteMetadataLanguage == language,
        update: () => dlsiteMetadataLanguage = language,
      );

  Future<void> setMaxCacheBytes(int bytes) => _setValue(
    unchanged: maxCacheBytes == bytes,
    update: () => maxCacheBytes = bytes,
  );

  Future<void> setAsmrPlaybackCacheEnabled(bool enabled) => _setValue(
    unchanged: asmrPlaybackCacheEnabled == enabled,
    update: () => asmrPlaybackCacheEnabled = enabled,
  );

  Future<void> setRecordPlaybackProgress(bool enabled) => _setValue(
    unchanged: recordPlaybackProgress == enabled,
    update: () => recordPlaybackProgress = enabled,
  );

  Future<void> setAllowVideoPlayback(bool enabled) => _setValue(
    unchanged: allowVideoPlayback == enabled,
    update: () => allowVideoPlayback = enabled,
  );

  Future<void> setBlurPlayerBackgroundEnabled(bool enabled) => _setValue(
    unchanged: blurPlayerBackgroundEnabled == enabled,
    update: () => blurPlayerBackgroundEnabled = enabled,
  );

  Future<void> setUiBlurEffectEnabled(bool enabled) => _setValue(
    unchanged: uiBlurEffectEnabled == enabled,
    update: () => uiBlurEffectEnabled = enabled,
  );

  Future<void> setHapticFeedbackEnabled(bool enabled) => _setValue(
    unchanged: hapticFeedbackEnabled == enabled,
    update: () => hapticFeedbackEnabled = enabled,
  );

  Future<void> setStartupPage(StartupPage page) => _setValue(
    unchanged: startupPage == page,
    update: () => startupPage = page,
  );

  Future<void> setBottomNavigationStyle(BottomNavigationStyle style) =>
      _setValue(
        unchanged: bottomNavigationStyle == style,
        update: () => bottomNavigationStyle = style,
      );

  Future<void> setPortraitLockEnabled(bool enabled) => _setValue(
    unchanged: portraitLockEnabled == enabled,
    update: () => portraitLockEnabled = enabled,
  );

  Future<void> setPlaybackDetailSubtitleStyle(
    PlaybackDetailSubtitleStyle style,
  ) => _setValue(
    unchanged: playbackDetailSubtitleStyle == style,
    update: () => playbackDetailSubtitleStyle = style,
  );

  Future<void> setCoverImageResolution(CoverImageResolution resolution) =>
      _setValue(
        unchanged: coverImageResolution == resolution,
        update: () => coverImageResolution = resolution,
      );

  Future<void> setCoverImageDisplayMode(CoverImageDisplayMode mode) =>
      _setValue(
        unchanged: coverImageDisplayMode == mode,
        update: () => coverImageDisplayMode = mode,
      );

  Future<void> setPreferEmbeddedAudioCover(bool enabled) => _setValue(
    unchanged: preferEmbeddedAudioCover == enabled,
    update: () => preferEmbeddedAudioCover = enabled,
  );

  Future<void> setAsmrDownloadConflictPolicy(
    AsmrDownloadConflictPolicy policy,
  ) => _setValue(
    unchanged: asmrDownloadConflictPolicy == policy,
    update: () => asmrDownloadConflictPolicy = policy,
  );

  Future<void> setAsmrDownloadSaveMetadata(bool enabled) => _setValue(
    unchanged: asmrDownloadSaveMetadata == enabled,
    update: () => asmrDownloadSaveMetadata = enabled,
  );

  Future<void> setAsmrDownloadRetryCount(int count) {
    final normalized = normalizeAsmrDownloadRetryCount(count);
    return _setValue(
      unchanged: asmrDownloadRetryCount == normalized,
      update: () => asmrDownloadRetryCount = normalized,
    );
  }

  Future<void> setAsmrDownloadThreadCount(int count) {
    final normalized = normalizeAsmrDownloadThreadCount(count);
    return _setValue(
      unchanged: asmrDownloadThreadCount == normalized,
      update: () => asmrDownloadThreadCount = normalized,
    );
  }

  Future<void> setAsmrDownloadSaveCover(bool enabled) => _setValue(
    unchanged: asmrDownloadSaveCover == enabled,
    update: () => asmrDownloadSaveCover = enabled,
  );

  Future<void> setAsmrDownloadFolderNameFields(
    Iterable<AsmrDownloadFolderNameField> fields,
  ) async {
    final normalized = normalizeAsmrDownloadFolderNameFields(fields);
    if (listEquals(asmrDownloadFolderNameFields, normalized)) return;
    asmrDownloadFolderNameFields = normalized;
    syncSlice(isInitialized: slice.state.isInitialized);
    await persist();
  }

  Future<void> setAudioDeviceDisconnectBehavior(
    AudioDeviceDisconnectBehavior behavior,
  ) => _setValue(
    unchanged: audioDeviceDisconnectBehavior == behavior,
    update: () => audioDeviceDisconnectBehavior = behavior,
  );

  Future<void> setAudioFocusStrategy(AudioFocusStrategy strategy) => _setValue(
    unchanged: audioFocusStrategy == strategy,
    update: () => audioFocusStrategy = strategy,
  );

  Future<void> setTransientAudioFocusLossBehavior(
    TransientAudioFocusLossBehavior behavior,
  ) => _setValue(
    unchanged: transientAudioFocusLossBehavior == behavior,
    update: () => transientAudioFocusLossBehavior = behavior,
  );

  Future<void> setInterruptionResumeBehavior(
    InterruptionResumeBehavior behavior,
  ) => _setValue(
    unchanged: interruptionResumeBehavior == behavior,
    update: () => interruptionResumeBehavior = behavior,
  );

  Future<void> setStartupPlaybackRestoreBehavior(
    StartupPlaybackRestoreBehavior behavior,
  ) => _setValue(
    unchanged: startupPlaybackRestoreBehavior == behavior,
    update: () => startupPlaybackRestoreBehavior = behavior,
  );

  Future<void> setAllowDuplicateWorks(bool enabled) => _setValue(
    unchanged: allowDuplicateWorks == enabled,
    update: () => allowDuplicateWorks = enabled,
  );

  Future<void> setReduceAnimations(bool enabled) => _setValue(
    unchanged: reduceAnimations == enabled,
    update: () => reduceAnimations = enabled,
  );

  Future<void> _setValue({
    required bool unchanged,
    required void Function() update,
  }) async {
    if (unchanged) return;
    update();
    syncSlice(isInitialized: slice.state.isInitialized);
    await persist();
  }

  void _resetValues() {
    converterFormat = 'mp3';
    converterBitrate = '320k';
    multiThreadPlaybackEnabled = false;
    notificationsEnabled = true;
    showPlaybackCard = true;
    autoPlayAddedSessions = true;
    autoCheckUpdates = false;
    dlsiteMetadataLanguage = ContentLanguagePreference.followPage;
    cardInfoFields = CardInfoField.defaults;
    librarySortCriterion = LibrarySortCriterion.name;
    librarySortAscending = true;
    libraryGroupByLibrary = false;
    playlistSortCriterion = PlaylistSortCriterion.name;
    playlistSortAscending = true;
    playlistGroupByLibrary = false;
    customEqPresets = const <EqPreset>[];
    maxCacheBytes = AppCacheService.defaultMaxCacheBytes;
    asmrPlaybackCacheEnabled = false;
    recordPlaybackProgress = true;
    allowVideoPlayback = true;
    blurPlayerBackgroundEnabled = true;
    uiBlurEffectEnabled = true;
    hapticFeedbackEnabled = true;
    startupPage = StartupPage.library;
    portraitLockEnabled = false;
    bottomNavigationStyle = BottomNavigationStyle.capsule;
    playbackDetailSubtitleStyle = PlaybackDetailSubtitleStyle.compact;
    coverImageResolution = CoverImageResolution.balanced;
    coverImageDisplayMode = CoverImageDisplayMode.fill;
    preferEmbeddedAudioCover = true;
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
    startupPlaybackRestoreBehavior = StartupPlaybackRestoreBehavior.resume;
    allowDuplicateWorks = false;
    reduceAnimations = false;
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
    slice.update(
      SettingsState(
        converterFormat: converterFormat,
        converterBitrate: converterBitrate,
        multiThreadPlaybackEnabled: multiThreadPlaybackEnabled,
        notificationsEnabled: notificationsEnabled,
        showPlaybackCard: showPlaybackCard,
        autoPlayAddedSessions: autoPlayAddedSessions,
        autoCheckUpdates: autoCheckUpdates,
        dlsiteMetadataLanguage: dlsiteMetadataLanguage,
        cardInfoFields: List<CardInfoField>.unmodifiable(cardInfoFields),
        librarySortCriterion: librarySortCriterion,
        librarySortAscending: librarySortAscending,
        libraryGroupByLibrary: libraryGroupByLibrary,
        playlistSortCriterion: playlistSortCriterion,
        playlistSortAscending: playlistSortAscending,
        playlistGroupByLibrary: playlistGroupByLibrary,
        customEqPresets: List<EqPreset>.unmodifiable(customEqPresets),
        maxCacheBytes: maxCacheBytes,
        asmrPlaybackCacheEnabled: asmrPlaybackCacheEnabled,
        recordPlaybackProgress: recordPlaybackProgress,
        allowVideoPlayback: allowVideoPlayback,
        blurPlayerBackgroundEnabled: blurPlayerBackgroundEnabled,
        uiBlurEffectEnabled: uiBlurEffectEnabled,
        hapticFeedbackEnabled: hapticFeedbackEnabled,
        startupPage: startupPage,
        portraitLockEnabled: portraitLockEnabled,
        bottomNavigationStyle: bottomNavigationStyle,
        playbackDetailSubtitleStyle: playbackDetailSubtitleStyle,
        coverImageResolution: coverImageResolution,
        coverImageDisplayMode: coverImageDisplayMode,
        preferEmbeddedAudioCover: preferEmbeddedAudioCover,
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
        startupPlaybackRestoreBehavior: startupPlaybackRestoreBehavior,
        allowDuplicateWorks: allowDuplicateWorks,
        reduceAnimations: reduceAnimations,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
