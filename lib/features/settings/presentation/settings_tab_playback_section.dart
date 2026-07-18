part of 'settings_tab.dart';

List<Widget> _buildSettingsPlaybackSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsGroupCard(
      children: [
        Consumer(
          builder: (context, ref, _) {
            final autoPlay = ref.watch(
              settingsStateProvider.select(
                (s) => s.valueOrNull?.autoPlayAddedSessions ?? true,
              ),
            );
            return SwitchListTile(
              value: autoPlay,
              onChanged: settings.setAutoPlayAddedSessions,
              title: Text(i18n.tr('auto_play_added_sessions')),
              secondary: _settingsIcon(
                Icons.playlist_play_rounded,
                cs.tertiary,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                (s) => s.valueOrNull?.asmrPlaybackCacheEnabled ?? false,
              ),
            );
            return SwitchListTile(
              value: asmrPlaybackCacheEnabled,
              onChanged: settings.setAsmrPlaybackCacheEnabled,
              title: Text(i18n.tr('asmr_playback_cache')),
              secondary: _settingsIcon(Icons.cached_rounded, cs.tertiary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                (s) => s.valueOrNull?.recordPlaybackProgress ?? true,
              ),
            );
            return SwitchListTile(
              value: recordProgress,
              onChanged: settings.setRecordPlaybackProgress,
              title: Text(i18n.tr('record_playback_progress')),
              secondary: _settingsIcon(Icons.restore_rounded, cs.tertiary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                (s) => s.valueOrNull?.multiThreadPlaybackEnabled ?? false,
              ),
            );
            return SwitchListTile(
              value: multiThreadEnabled,
              onChanged: (value) {
                settingsController.setMultiThreadPlaybackEnabled(value);
                if (!value) {
                  ref
                      .read(subtitleSettingsProvider.notifier)
                      .turnOffAllSubtitles();
                }
              },
              title: Text(i18n.tr('multi_thread_playback')),
              secondary: _settingsIcon(
                Icons.multitrack_audio_rounded,
                cs.tertiary,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
      ],
    ),
  ];
}
