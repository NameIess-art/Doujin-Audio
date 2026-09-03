import 'package:flutter/foundation.dart';

import '../../../core/app_language.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/media/card_info_field.dart';
import '../../../core/media/cover_image_resolution.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../player/domain/audio_effects.dart';

export '../../../core/media/cover_image_resolution.dart';

enum StartupPage { asmrOne, library, playlist }

enum PlaybackDetailSubtitleStyle { compact, timeline }

enum AudioDeviceDisconnectBehavior { pause, continuePlayback }

enum AudioFocusStrategy { standard, mixWithOthers }

enum TransientAudioFocusLossBehavior { duck, pause }

enum InterruptionResumeBehavior { stayPaused, resume }

enum StartupPlaybackRestoreBehavior { resume, pause }

enum LibrarySortCriterion {
  name,
  voiceActor,
  duration,
  releaseDate,
  addedAt,
  playbackTime,
}

enum PlaylistSortCriterion {
  name,
  voiceActor,
  releaseDate,
  addedAt,
  playbackTime,
}

@immutable
class SettingsState {
  SettingsState({
    this.converterFormat = 'mp3',
    this.converterBitrate = '320k',
    this.converterOutputDirectoryPath,
    this.multiThreadPlaybackEnabled = false,
    this.notificationsEnabled = true,
    this.showPlaybackCard = true,
    this.autoPlayAddedSessions = true,
    this.autoCheckUpdates = false,
    this.dlsiteMetadataLanguage = ContentLanguagePreference.followPage,
    List<CardInfoField> cardInfoFields = CardInfoField.defaults,
    this.librarySortCriterion = LibrarySortCriterion.name,
    this.librarySortAscending = true,
    this.libraryGroupByLibrary = false,
    this.playlistSortCriterion = PlaylistSortCriterion.name,
    this.playlistSortAscending = true,
    this.playlistGroupByLibrary = false,
    List<EqPreset> customEqPresets = const <EqPreset>[],
    this.maxCacheBytes = 300 * 1024 * 1024,
    this.asmrPlaybackCacheEnabled = false,
    this.recordPlaybackProgress = true,
    this.allowVideoPlayback = true,
    this.blurPlayerBackgroundEnabled = true,
    this.uiBlurEffectEnabled = true,
    this.hapticFeedbackEnabled = true,
    this.showLocalLibrary = true,
    this.showAsmrOne = true,
    this.startupPage = StartupPage.library,
    this.portraitLockEnabled = false,
    this.playbackDetailSubtitleStyle = PlaybackDetailSubtitleStyle.compact,
    this.coverImageResolution = CoverImageResolution.balanced,
    this.coverImageDisplayMode = CoverImageDisplayMode.fill,
    this.preferEmbeddedAudioCover = true,
    this.asmrDownloadDestinationRoot,
    this.asmrDownloadConflictPolicy = AsmrDownloadConflictPolicy.overwrite,
    this.asmrDownloadRetryCount = kDefaultAsmrDownloadRetryCount,
    this.asmrDownloadThreadCount = kDefaultAsmrDownloadThreadCount,
    this.asmrDownloadSaveMetadata = true,
    this.asmrDownloadSaveCover = true,
    List<AsmrDownloadFolderNameField> asmrDownloadFolderNameFields =
        kDefaultAsmrDownloadFolderNameFields,
    this.audioDeviceDisconnectBehavior = AudioDeviceDisconnectBehavior.pause,
    this.audioFocusStrategy = AudioFocusStrategy.standard,
    this.transientAudioFocusLossBehavior = TransientAudioFocusLossBehavior.duck,
    this.interruptionResumeBehavior = InterruptionResumeBehavior.resume,
    this.startupPlaybackRestoreBehavior = StartupPlaybackRestoreBehavior.resume,
    this.allowDuplicateWorks = false,
    this.reduceAnimations = false,
    this.isInitialized = false,
  }) : cardInfoFields = immutableList(cardInfoFields),
       customEqPresets = immutableList(customEqPresets),
       asmrDownloadFolderNameFields = immutableList(
         asmrDownloadFolderNameFields,
       );

  final String converterFormat;
  final String converterBitrate;
  final String? converterOutputDirectoryPath;
  final bool multiThreadPlaybackEnabled;
  final bool notificationsEnabled;
  final bool showPlaybackCard;
  final bool autoPlayAddedSessions;
  final bool autoCheckUpdates;
  final ContentLanguagePreference dlsiteMetadataLanguage;
  final List<CardInfoField> cardInfoFields;
  final LibrarySortCriterion librarySortCriterion;
  final bool librarySortAscending;
  final bool libraryGroupByLibrary;
  final PlaylistSortCriterion playlistSortCriterion;
  final bool playlistSortAscending;
  final bool playlistGroupByLibrary;
  final List<EqPreset> customEqPresets;
  final int maxCacheBytes;
  final bool asmrPlaybackCacheEnabled;
  final bool recordPlaybackProgress;
  final bool allowVideoPlayback;
  final bool blurPlayerBackgroundEnabled;
  final bool uiBlurEffectEnabled;
  final bool hapticFeedbackEnabled;
  final bool showLocalLibrary;
  final bool showAsmrOne;
  final StartupPage startupPage;
  final bool portraitLockEnabled;
  final PlaybackDetailSubtitleStyle playbackDetailSubtitleStyle;
  final CoverImageResolution coverImageResolution;
  final CoverImageDisplayMode coverImageDisplayMode;
  final bool preferEmbeddedAudioCover;
  final String? asmrDownloadDestinationRoot;
  final AsmrDownloadConflictPolicy asmrDownloadConflictPolicy;
  final int asmrDownloadRetryCount;
  final int asmrDownloadThreadCount;
  final bool asmrDownloadSaveMetadata;
  final bool asmrDownloadSaveCover;
  final List<AsmrDownloadFolderNameField> asmrDownloadFolderNameFields;
  final AudioDeviceDisconnectBehavior audioDeviceDisconnectBehavior;
  final AudioFocusStrategy audioFocusStrategy;
  final TransientAudioFocusLossBehavior transientAudioFocusLossBehavior;
  final InterruptionResumeBehavior interruptionResumeBehavior;
  final StartupPlaybackRestoreBehavior startupPlaybackRestoreBehavior;
  final bool allowDuplicateWorks;
  final bool reduceAnimations;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is SettingsState &&
        other.converterFormat == converterFormat &&
        other.converterBitrate == converterBitrate &&
        other.converterOutputDirectoryPath == converterOutputDirectoryPath &&
        other.multiThreadPlaybackEnabled == multiThreadPlaybackEnabled &&
        other.notificationsEnabled == notificationsEnabled &&
        other.showPlaybackCard == showPlaybackCard &&
        other.autoPlayAddedSessions == autoPlayAddedSessions &&
        other.autoCheckUpdates == autoCheckUpdates &&
        other.dlsiteMetadataLanguage == dlsiteMetadataLanguage &&
        listEquals(other.cardInfoFields, cardInfoFields) &&
        other.librarySortCriterion == librarySortCriterion &&
        other.librarySortAscending == librarySortAscending &&
        other.libraryGroupByLibrary == libraryGroupByLibrary &&
        other.playlistSortCriterion == playlistSortCriterion &&
        other.playlistSortAscending == playlistSortAscending &&
        other.playlistGroupByLibrary == playlistGroupByLibrary &&
        listEquals(other.customEqPresets, customEqPresets) &&
        other.maxCacheBytes == maxCacheBytes &&
        other.asmrPlaybackCacheEnabled == asmrPlaybackCacheEnabled &&
        other.recordPlaybackProgress == recordPlaybackProgress &&
        other.allowVideoPlayback == allowVideoPlayback &&
        other.blurPlayerBackgroundEnabled == blurPlayerBackgroundEnabled &&
        other.uiBlurEffectEnabled == uiBlurEffectEnabled &&
        other.hapticFeedbackEnabled == hapticFeedbackEnabled &&
        other.showLocalLibrary == showLocalLibrary &&
        other.showAsmrOne == showAsmrOne &&
        other.startupPage == startupPage &&
        other.portraitLockEnabled == portraitLockEnabled &&
        other.playbackDetailSubtitleStyle == playbackDetailSubtitleStyle &&
        other.coverImageResolution == coverImageResolution &&
        other.coverImageDisplayMode == coverImageDisplayMode &&
        other.preferEmbeddedAudioCover == preferEmbeddedAudioCover &&
        other.asmrDownloadDestinationRoot == asmrDownloadDestinationRoot &&
        other.asmrDownloadConflictPolicy == asmrDownloadConflictPolicy &&
        other.asmrDownloadRetryCount == asmrDownloadRetryCount &&
        other.asmrDownloadThreadCount == asmrDownloadThreadCount &&
        other.asmrDownloadSaveMetadata == asmrDownloadSaveMetadata &&
        other.asmrDownloadSaveCover == asmrDownloadSaveCover &&
        listEquals(
          other.asmrDownloadFolderNameFields,
          asmrDownloadFolderNameFields,
        ) &&
        other.audioDeviceDisconnectBehavior == audioDeviceDisconnectBehavior &&
        other.audioFocusStrategy == audioFocusStrategy &&
        other.transientAudioFocusLossBehavior ==
            transientAudioFocusLossBehavior &&
        other.interruptionResumeBehavior == interruptionResumeBehavior &&
        other.startupPlaybackRestoreBehavior ==
            startupPlaybackRestoreBehavior &&
        other.allowDuplicateWorks == allowDuplicateWorks &&
        other.reduceAnimations == reduceAnimations &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    converterFormat,
    converterBitrate,
    converterOutputDirectoryPath,
    multiThreadPlaybackEnabled,
    notificationsEnabled,
    showPlaybackCard,
    autoPlayAddedSessions,
    autoCheckUpdates,
    dlsiteMetadataLanguage,
    Object.hashAll(cardInfoFields),
    librarySortCriterion,
    librarySortAscending,
    libraryGroupByLibrary,
    playlistSortCriterion,
    playlistSortAscending,
    playlistGroupByLibrary,
    Object.hashAll(customEqPresets),
    maxCacheBytes,
    asmrPlaybackCacheEnabled,
    recordPlaybackProgress,
    allowVideoPlayback,
    blurPlayerBackgroundEnabled,
    uiBlurEffectEnabled,
    hapticFeedbackEnabled,
    showLocalLibrary,
    showAsmrOne,
    startupPage,
    portraitLockEnabled,
    playbackDetailSubtitleStyle,
    coverImageResolution,
    coverImageDisplayMode,
    preferEmbeddedAudioCover,
    asmrDownloadDestinationRoot,
    asmrDownloadConflictPolicy,
    asmrDownloadRetryCount,
    asmrDownloadThreadCount,
    asmrDownloadSaveMetadata,
    asmrDownloadSaveCover,
    Object.hashAll(asmrDownloadFolderNameFields),
    audioDeviceDisconnectBehavior,
    audioFocusStrategy,
    transientAudioFocusLossBehavior,
    interruptionResumeBehavior,
    startupPlaybackRestoreBehavior,
    allowDuplicateWorks,
    reduceAnimations,
    isInitialized,
  ]);
}
