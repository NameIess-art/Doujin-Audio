part of 'settings_tab.dart';

List<Widget> _buildSettingsPlaybackSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_playback_behavior'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final autoPlay = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.autoPlayAddedSessions ?? true,
              ),
            );
            return SwitchListTile(
              value: autoPlay,
              onChanged: settings.setAutoPlayAddedSessions,
              title: _settingsTitle(i18n.tr('auto_play_added_sessions')),
              secondary: _settingsIcon(
                Icons.playlist_play_rounded,
                cs.onSurface,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final allowVideoPlayback = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.allowVideoPlayback ?? true,
              ),
            );
            return SwitchListTile(
              key: const ValueKey<String>('allow_video_playback_switch'),
              value: allowVideoPlayback,
              onChanged: settings.setAllowVideoPlayback,
              title: _settingsTitle(i18n.tr('allow_video_playback')),
              secondary: _settingsIcon(Icons.videocam_rounded, cs.onSurface),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final asmrPlaybackCacheEnabled = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.asmrPlaybackCacheEnabled ?? false,
              ),
            );
            return SwitchListTile(
              value: asmrPlaybackCacheEnabled,
              onChanged: settings.setAsmrPlaybackCacheEnabled,
              title: _settingsTitle(i18n.tr('asmr_playback_cache')),
              secondary: _settingsIcon(Icons.cached_rounded, cs.onSurface),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final recordProgress = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.recordPlaybackProgress ?? true,
              ),
            );
            return SwitchListTile(
              value: recordProgress,
              onChanged: settings.setRecordPlaybackProgress,
              title: _settingsTitle(i18n.tr('record_playback_progress')),
              secondary: _settingsIcon(Icons.restore_rounded, cs.onSurface),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final multiThreadEnabled = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.multiThreadPlaybackEnabled ?? false,
              ),
            );
            return SwitchListTile(
              value: multiThreadEnabled,
              onChanged: (value) async {
                final updated = await settingsController
                    .setMultiThreadPlaybackEnabled(value);
                if (!context.mounted) return;
                if (!updated) {
                  showAppSnackBar(
                    context,
                    i18n.tr('operation_failed_retry'),
                    tone: AppFeedbackTone.destructive,
                    icon: Icons.error_outline_rounded,
                  );
                  return;
                }
                if (!value) {
                  final activeSessions =
                      ref.read(playbackStateProvider).value?.activeSessions ??
                      ref.read(playbackFacadeProvider).activeSessions;
                  final activeSessionIds = activeSessions.map(
                    (session) => session.id,
                  );
                  ref
                      .read(subtitleSettingsProvider.notifier)
                      .turnOffAllSubtitles(activeSessionIds);
                }
              },
              title: _settingsTitle(i18n.tr('multi_thread_playback')),
              secondary: _settingsIcon(
                Icons.multitrack_audio_rounded,
                cs.onSurface,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
      ],
    ),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_audio_recovery'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final behavior = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.audioDeviceDisconnectBehavior ??
                    AudioDeviceDisconnectBehavior.pause,
              ),
            );
            return ListTile(
              title: _settingsTitle(
                i18n.tr('audio_device_disconnect_behavior'),
              ),
              leading: _settingsIcon(Icons.headset_off_rounded, cs.onSurface),
              trailing: _settingsDropdown<AudioDeviceDisconnectBehavior>(
                context,
                value: behavior,
                onChanged: (value) {
                  if (value != null) {
                    settingsController.setAudioDeviceDisconnectBehavior(value);
                  }
                },
                items: AudioDeviceDisconnectBehavior.values
                    .map(
                      (value) =>
                          DropdownMenuItem<AudioDeviceDisconnectBehavior>(
                            value: value,
                            child: _settingsDropdownText(
                              i18n.tr('audio_device_disconnect_${value.name}'),
                            ),
                          ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final behavior = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.transientAudioFocusLossBehavior ??
                    TransientAudioFocusLossBehavior.duck,
              ),
            );
            return ListTile(
              title: _settingsTitle(
                i18n.tr('transient_audio_focus_loss_behavior'),
              ),
              leading: _settingsIcon(Icons.volume_down_rounded, cs.onSurface),
              trailing: _settingsDropdown<TransientAudioFocusLossBehavior>(
                context,
                value: behavior,
                onChanged: (value) {
                  if (value != null) {
                    settingsController.setTransientAudioFocusLossBehavior(
                      value,
                    );
                  }
                },
                items: TransientAudioFocusLossBehavior.values
                    .map(
                      (value) =>
                          DropdownMenuItem<TransientAudioFocusLossBehavior>(
                            value: value,
                            child: _settingsDropdownText(
                              i18n.tr(
                                'transient_audio_focus_loss_${value.name}',
                              ),
                            ),
                          ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final behavior = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.interruptionResumeBehavior ??
                    InterruptionResumeBehavior.resume,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('interruption_resume_behavior')),
              leading: _settingsIcon(Icons.phone_in_talk_rounded, cs.onSurface),
              trailing: _settingsDropdown<InterruptionResumeBehavior>(
                context,
                value: behavior,
                onChanged: (value) {
                  if (value != null) {
                    settingsController.setInterruptionResumeBehavior(value);
                  }
                },
                items: InterruptionResumeBehavior.values
                    .map(
                      (value) => DropdownMenuItem<InterruptionResumeBehavior>(
                        value: value,
                        child: _settingsDropdownText(
                          i18n.tr('interruption_resume_${value.name}'),
                        ),
                      ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
      ],
    ),
  ];
}
