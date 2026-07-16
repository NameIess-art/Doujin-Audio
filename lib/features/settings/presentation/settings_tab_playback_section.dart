part of 'settings_tab.dart';

List<Widget> _buildSettingsPlaybackSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required TextStyle? descStyle,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SectionHeader(title: i18n.tr('section_playback')),
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
              subtitle: Text(
                i18n.tr('auto_play_added_sessions_subtitle'),
                style: descStyle,
              ),
              secondary: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.playlist_play_rounded,
                  color: cs.onTertiaryContainer,
                ),
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
              subtitle: Text(
                i18n.tr('asmr_playback_cache_subtitle'),
                style: descStyle,
              ),
              secondary: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.cached_rounded,
                  color: cs.onTertiaryContainer,
                ),
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
            final recordProgress = ref.watch(
              settingsStateProvider.select(
                (s) => s.valueOrNull?.recordPlaybackProgress ?? true,
              ),
            );
            return SwitchListTile(
              value: recordProgress,
              onChanged: settings.setRecordPlaybackProgress,
              title: Text(i18n.tr('record_playback_progress')),
              subtitle: Text(
                i18n.tr('record_playback_progress_subtitle'),
                style: descStyle,
              ),
              secondary: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.restore_rounded,
                  color: cs.onTertiaryContainer,
                ),
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
              subtitle: Text(
                i18n.tr('multi_thread_playback_subtitle'),
                style: descStyle,
              ),
              secondary: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.multitrack_audio_rounded,
                  color: cs.onTertiaryContainer,
                ),
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
