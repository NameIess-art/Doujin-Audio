import 'package:flutter/foundation.dart';

import '../../../core/app_language.dart';
import '../../../core/media/card_info_field.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../player/domain/audio_effects.dart';

enum StartupPage { asmrOne, library, playlist }

enum BottomNavigationStyle { capsule, bar }

enum PlaybackDetailSubtitleStyle { compact, timeline }

enum CoverImageResolution { memorySaver, balanced, high, ultraHigh, original }

enum AudioDeviceDisconnectBehavior { pause, continuePlayback }

enum TransientAudioFocusLossBehavior { duck, pause }

enum InterruptionResumeBehavior { stayPaused, resume }

enum StartupPlaybackRestoreBehavior { resume, pause }

@immutable
class SettingsState {
  const SettingsState({
    this.converterFormat = 'mp3',
    this.converterBitrate = '320k',
    this.multiThreadPlaybackEnabled = false,
    this.notificationsEnabled = true,
    this.showPlaybackCard = true,
    this.autoPlayAddedSessions = true,
    this.autoCheckUpdates = false,
    this.dlsiteMetadataLanguage = ContentLanguagePreference.followPage,
    this.cardInfoFields = CardInfoField.defaults,
    this.cardPositionsLocked = true,
    this.customEqPresets = const <EqPreset>[],
    this.maxCacheBytes = 300 * 1024 * 1024,
    this.asmrPlaybackCacheEnabled = false,
    this.recordPlaybackProgress = true,
    this.blurPlayerBackgroundEnabled = true,
    this.uiBlurEffectEnabled = true,
    this.hapticFeedbackEnabled = true,
    this.startupPage = StartupPage.library,
    this.portraitLockEnabled = false,
    this.bottomNavigationStyle = BottomNavigationStyle.capsule,
    this.playbackDetailSubtitleStyle = PlaybackDetailSubtitleStyle.compact,
    this.coverImageResolution = CoverImageResolution.balanced,
    this.asmrDownloadDestinationRoot,
    this.asmrDownloadConflictPolicy = AsmrDownloadConflictPolicy.overwrite,
    this.asmrDownloadSaveMetadata = true,
    this.asmrDownloadFolderNameFields = kDefaultAsmrDownloadFolderNameFields,
    this.audioDeviceDisconnectBehavior = AudioDeviceDisconnectBehavior.pause,
    this.transientAudioFocusLossBehavior = TransientAudioFocusLossBehavior.duck,
    this.interruptionResumeBehavior = InterruptionResumeBehavior.resume,
    this.startupPlaybackRestoreBehavior = StartupPlaybackRestoreBehavior.resume,
    this.allowDuplicateWorks = false,
    this.reduceAnimations = false,
    this.isInitialized = false,
  });

  final String converterFormat;
  final String converterBitrate;
  final bool multiThreadPlaybackEnabled;
  final bool notificationsEnabled;
  final bool showPlaybackCard;
  final bool autoPlayAddedSessions;
  final bool autoCheckUpdates;
  final ContentLanguagePreference dlsiteMetadataLanguage;
  final List<CardInfoField> cardInfoFields;
  final bool cardPositionsLocked;
  final List<EqPreset> customEqPresets;
  final int maxCacheBytes;
  final bool asmrPlaybackCacheEnabled;
  final bool recordPlaybackProgress;
  final bool blurPlayerBackgroundEnabled;
  final bool uiBlurEffectEnabled;
  final bool hapticFeedbackEnabled;
  final StartupPage startupPage;
  final bool portraitLockEnabled;
  final BottomNavigationStyle bottomNavigationStyle;
  final PlaybackDetailSubtitleStyle playbackDetailSubtitleStyle;
  final CoverImageResolution coverImageResolution;
  final String? asmrDownloadDestinationRoot;
  final AsmrDownloadConflictPolicy asmrDownloadConflictPolicy;
  final bool asmrDownloadSaveMetadata;
  final List<AsmrDownloadFolderNameField> asmrDownloadFolderNameFields;
  final AudioDeviceDisconnectBehavior audioDeviceDisconnectBehavior;
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
        other.multiThreadPlaybackEnabled == multiThreadPlaybackEnabled &&
        other.notificationsEnabled == notificationsEnabled &&
        other.showPlaybackCard == showPlaybackCard &&
        other.autoPlayAddedSessions == autoPlayAddedSessions &&
        other.autoCheckUpdates == autoCheckUpdates &&
        other.dlsiteMetadataLanguage == dlsiteMetadataLanguage &&
        listEquals(other.cardInfoFields, cardInfoFields) &&
        other.cardPositionsLocked == cardPositionsLocked &&
        listEquals(other.customEqPresets, customEqPresets) &&
        other.maxCacheBytes == maxCacheBytes &&
        other.asmrPlaybackCacheEnabled == asmrPlaybackCacheEnabled &&
        other.recordPlaybackProgress == recordPlaybackProgress &&
        other.blurPlayerBackgroundEnabled == blurPlayerBackgroundEnabled &&
        other.uiBlurEffectEnabled == uiBlurEffectEnabled &&
        other.hapticFeedbackEnabled == hapticFeedbackEnabled &&
        other.startupPage == startupPage &&
        other.portraitLockEnabled == portraitLockEnabled &&
        other.bottomNavigationStyle == bottomNavigationStyle &&
        other.playbackDetailSubtitleStyle == playbackDetailSubtitleStyle &&
        other.coverImageResolution == coverImageResolution &&
        other.asmrDownloadDestinationRoot == asmrDownloadDestinationRoot &&
        other.asmrDownloadConflictPolicy == asmrDownloadConflictPolicy &&
        other.asmrDownloadSaveMetadata == asmrDownloadSaveMetadata &&
        listEquals(
          other.asmrDownloadFolderNameFields,
          asmrDownloadFolderNameFields,
        ) &&
        other.audioDeviceDisconnectBehavior == audioDeviceDisconnectBehavior &&
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
    multiThreadPlaybackEnabled,
    notificationsEnabled,
    showPlaybackCard,
    autoPlayAddedSessions,
    autoCheckUpdates,
    dlsiteMetadataLanguage,
    Object.hashAll(cardInfoFields),
    cardPositionsLocked,
    Object.hashAll(customEqPresets),
    maxCacheBytes,
    asmrPlaybackCacheEnabled,
    recordPlaybackProgress,
    blurPlayerBackgroundEnabled,
    uiBlurEffectEnabled,
    hapticFeedbackEnabled,
    startupPage,
    portraitLockEnabled,
    bottomNavigationStyle,
    playbackDetailSubtitleStyle,
    coverImageResolution,
    asmrDownloadDestinationRoot,
    asmrDownloadConflictPolicy,
    asmrDownloadSaveMetadata,
    Object.hashAll(asmrDownloadFolderNameFields),
    audioDeviceDisconnectBehavior,
    transientAudioFocusLossBehavior,
    interruptionResumeBehavior,
    startupPlaybackRestoreBehavior,
    allowDuplicateWorks,
    reduceAnimations,
    isInitialized,
  ]);
}
