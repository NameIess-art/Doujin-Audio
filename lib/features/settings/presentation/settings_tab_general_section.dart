part of 'settings_tab.dart';

List<Widget> _buildSettingsLanguageSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsGroupCard(
      children: [
        ListTile(
          title: Text(i18n.tr('interface_language')),
          leading: _settingsIcon(Icons.language_rounded, cs.primary),
          trailing: SizedBox(
            width: 136,
            child: UnifiedDropdownButton<AppLanguagePreference>(
              isExpanded: true,
              value: i18n.preference,
              onChanged: (value) {
                if (value != null) i18n.setLanguagePreference(value);
              },
              items: AppLanguagePreference.values
                  .map(
                    (preference) => DropdownMenuItem<AppLanguagePreference>(
                      value: preference,
                      child: Text(
                        preference.explicitLanguage == null
                            ? i18n.tr('follow_system')
                            : i18n.languageName(preference.explicitLanguage!),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 2,
          ),
        ),
        Consumer(
          builder: (context, ref, _) {
            final dlsiteLanguage = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.valueOrNull?.dlsiteMetadataLanguage ??
                    ContentLanguagePreference.followPage,
              ),
            );
            return ListTile(
              title: Text(i18n.tr('dlsite_metadata_language')),
              leading: _settingsIcon(Icons.public_rounded, cs.primary),
              trailing: UnifiedDropdownButton<ContentLanguagePreference>(
                value: dlsiteLanguage,
                onChanged: (value) {
                  if (value != null) settings.setDlsiteMetadataLanguage(value);
                },
                items: ContentLanguagePreference.values.map((preference) {
                  final language = preference.explicitLanguage;
                  return DropdownMenuItem<ContentLanguagePreference>(
                    value: preference,
                    child: Text(
                      language == null
                          ? i18n.tr('follow_interface_language')
                          : i18n.languageName(language),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  );
                }).toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final preference = ref.watch(
              asmrLibraryGlobalStateProvider.select(
                (state) =>
                    state.valueOrNull?.contentLanguagePreference ??
                    ContentLanguagePreference.followPage,
              ),
            );
            final controller = ref.read(asmrLibraryControllerProvider);
            return ListTile(
              title: Text(i18n.tr('asmr_page_language')),
              leading: _settingsIcon(Icons.public_rounded, cs.primary),
              trailing: UnifiedDropdownButton<ContentLanguagePreference>(
                value: preference,
                onChanged: controller == null
                    ? null
                    : (value) {
                        if (value != null) {
                          unawaited(
                            controller.setContentLanguagePreference(value),
                          );
                        }
                      },
                items: ContentLanguagePreference.values
                    .map(
                      (value) => DropdownMenuItem<ContentLanguagePreference>(
                        value: value,
                        child: Text(
                          i18n.tr(asmrLanguageLabelKey(value)),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
            );
          },
        ),
      ],
    ),
  ];
}

List<Widget> _buildSettingsGeneralSection({
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
            final startupPage = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.valueOrNull?.startupPage ?? StartupPage.library,
              ),
            );
            return ListTile(
              title: Text(i18n.tr('startup_page')),
              leading: _settingsIcon(Icons.home_rounded, cs.primary),
              trailing: UnifiedDropdownButton<StartupPage>(
                value: startupPage,
                onChanged: (value) {
                  if (value != null) settings.setStartupPage(value);
                },
                items: StartupPage.values
                    .map(
                      (page) => DropdownMenuItem<StartupPage>(
                        value: page,
                        child: Text(
                          i18n.tr('startup_page_${page.name}'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final behavior = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.valueOrNull?.startupPlaybackRestoreBehavior ??
                    StartupPlaybackRestoreBehavior.resume,
              ),
            );
            return ListTile(
              title: Text(i18n.tr('startup_playback_restore_behavior')),
              leading: _settingsIcon(Icons.restore_rounded, cs.primary),
              trailing: UnifiedDropdownButton<StartupPlaybackRestoreBehavior>(
                value: behavior,
                onChanged: (value) {
                  if (value != null) {
                    settingsController.setStartupPlaybackRestoreBehavior(value);
                  }
                },
                items: StartupPlaybackRestoreBehavior.values
                    .map(
                      (value) =>
                          DropdownMenuItem<StartupPlaybackRestoreBehavior>(
                            value: value,
                            child: Text(
                              i18n.tr('startup_playback_restore_${value.name}'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.valueOrNull?.allowDuplicateWorks ?? false,
              ),
            );
            return SwitchListTile(
              title: Text(i18n.tr('allow_duplicate_works')),
              value: enabled,
              onChanged: settings.setAllowDuplicateWorks,
              secondary: _settingsIcon(Icons.copy_all_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.valueOrNull?.reduceAnimations ?? false,
              ),
            );
            return SwitchListTile(
              title: Text(i18n.tr('reduce_animations')),
              value: enabled,
              onChanged: settings.setReduceAnimations,
              secondary: _settingsIcon(Icons.animation_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
            );
          },
        ),
        if (!Platform.isWindows)
          Consumer(
            builder: (context, ref, _) {
              final enabled = ref.watch(
                settingsStateProvider.select(
                  (s) => s.valueOrNull?.hapticFeedbackEnabled ?? true,
                ),
              );
              return SwitchListTile(
                title: Text(i18n.tr('haptic_feedback_enabled')),
                value: enabled,
                onChanged: settings.setHapticFeedbackEnabled,
                secondary: _settingsIcon(Icons.vibration_rounded, cs.primary),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
              );
            },
          ),
      ],
    ),
  ];
}

Widget _settingsIcon(IconData icon, Color color) {
  return Icon(icon, color: color, size: 30);
}
