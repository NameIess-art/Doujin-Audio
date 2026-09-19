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
            final trigger = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.sleepModeAutoTrigger ??
                    SleepModeAutoTrigger.manual,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('sleep_mode_auto_trigger')),
              leading: _settingsIcon(Icons.bedtime_outlined, cs.onSurface),
              trailing: _settingsDropdown<SleepModeAutoTrigger>(
                context,
                value: trigger,
                onChanged: (value) {
                  if (value != null) {
                    settings.setSleepModeAutoTrigger(value);
                  }
                },
                items: SleepModeAutoTrigger.values
                    .map(
                      (value) => DropdownMenuItem<SleepModeAutoTrigger>(
                        value: value,
                        child: _settingsDropdownText(
                          i18n.tr('sleep_mode_auto_trigger_${value.name}'),
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
        if (defaultTargetPlatform != TargetPlatform.windows)
          Consumer(
            builder: (context, ref, _) {
              final strategy = ref.watch(
                settingsStateProvider.select(
                  (state) =>
                      state.value?.audioFocusStrategy ??
                      AudioFocusStrategy.standard,
                ),
              );
              return ListTile(
                title: _settingsTitle(i18n.tr('audio_focus_strategy')),
                leading: _settingsIcon(
                  Icons.multitrack_audio_rounded,
                  cs.onSurface,
                ),
                trailing: _settingsDropdown<AudioFocusStrategy>(
                  context,
                  value: strategy,
                  onChanged: (value) {
                    if (value != null) {
                      settingsController.setAudioFocusStrategy(value);
                    }
                  },
                  items: AudioFocusStrategy.values
                      .map(
                        (value) => DropdownMenuItem<AudioFocusStrategy>(
                          value: value,
                          child: _settingsDropdownText(
                            i18n.tr('audio_focus_strategy_${value.name}'),
                          ),
                        ),
                      )
                      .toList(),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              );
            },
          ),
        if (defaultTargetPlatform != TargetPlatform.windows)
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
