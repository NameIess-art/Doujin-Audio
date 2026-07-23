part of 'settings_tab.dart';

List<Widget> _buildSettingsLanguageSection({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsGroupCard(
      children: [
        ListTile(
          title: _settingsTitle(i18n.tr('interface_language')),
          leading: _settingsIcon(Icons.language_rounded, cs.onSurface),
          trailing: _settingsDropdown<AppLanguagePreference>(
            context,
            value: i18n.preference,
            onChanged: (value) {
              if (value != null) i18n.setLanguagePreference(value);
            },
            items: AppLanguagePreference.values
                .map(
                  (preference) => DropdownMenuItem<AppLanguagePreference>(
                    value: preference,
                    child: _settingsDropdownText(
                      preference.explicitLanguage == null
                          ? i18n.tr('follow_system')
                          : i18n.languageName(preference.explicitLanguage!),
                    ),
                  ),
                )
                .toList(),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        Consumer(
          builder: (context, ref, _) {
            final dlsiteLanguage = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.dlsiteMetadataLanguage ??
                    ContentLanguagePreference.followPage,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('dlsite_metadata_language')),
              leading: _settingsIcon(Icons.public_rounded, cs.onSurface),
              trailing: _settingsDropdown<ContentLanguagePreference>(
                context,
                value: dlsiteLanguage,
                onChanged: (value) {
                  if (value != null) settings.setDlsiteMetadataLanguage(value);
                },
                items: ContentLanguagePreference.values.map((preference) {
                  final language = preference.explicitLanguage;
                  return DropdownMenuItem<ContentLanguagePreference>(
                    value: preference,
                    child: _settingsDropdownText(
                      language == null
                          ? i18n.tr('follow_interface_language')
                          : i18n.languageName(language),
                    ),
                  );
                }).toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final preference = ref.watch(
              asmrLibraryGlobalStateProvider.select(
                (state) =>
                    state.value?.contentLanguagePreference ??
                    ContentLanguagePreference.followPage,
              ),
            );
            final controller = ref.read(asmrLibraryControllerProvider);
            return ListTile(
              title: _settingsTitle(i18n.tr('asmr_page_language')),
              leading: _settingsIcon(Icons.public_rounded, cs.onSurface),
              trailing: _settingsDropdown<ContentLanguagePreference>(
                context,
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
                        child: _settingsDropdownText(
                          i18n.tr(asmrLanguageLabelKey(value)),
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

List<Widget> _buildSettingsGeneralSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_startup_behavior'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final startupPage = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.startupPage ?? StartupPage.library,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('startup_page')),
              leading: _settingsIcon(Icons.home_rounded, cs.onSurface),
              trailing: _settingsDropdown<StartupPage>(
                context,
                value: startupPage,
                onChanged: (value) {
                  if (value != null) settings.setStartupPage(value);
                },
                items: StartupPage.values
                    .map(
                      (page) => DropdownMenuItem<StartupPage>(
                        value: page,
                        child: _settingsDropdownText(
                          i18n.tr('startup_page_${page.name}'),
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
                    state.value?.startupPlaybackRestoreBehavior ??
                    StartupPlaybackRestoreBehavior.resume,
              ),
            );
            return ListTile(
              title: _settingsTitle(
                i18n.tr('startup_playback_restore_behavior'),
              ),
              leading: _settingsIcon(Icons.restore_rounded, cs.onSurface),
              trailing: _settingsDropdown<StartupPlaybackRestoreBehavior>(
                context,
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
                            child: _settingsDropdownText(
                              i18n.tr('startup_playback_restore_${value.name}'),
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
      title: i18n.tr('settings_group_general_behavior'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.portraitLockEnabled ?? false,
              ),
            );
            return SwitchListTile(
              title: _settingsTitle(i18n.tr('portrait_lock')),
              value: enabled,
              onChanged: settings.setPortraitLockEnabled,
              secondary: _settingsIcon(
                Icons.screen_lock_portrait_rounded,
                cs.onSurface,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.allowDuplicateWorks ?? false,
              ),
            );
            return SwitchListTile(
              title: _settingsTitle(i18n.tr('allow_duplicate_works')),
              value: enabled,
              onChanged: settings.setAllowDuplicateWorks,
              secondary: _settingsIcon(Icons.copy_all_rounded, cs.onSurface),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.reduceAnimations ?? false,
              ),
            );
            return SwitchListTile(
              title: _settingsTitle(i18n.tr('reduce_animations')),
              value: enabled,
              onChanged: settings.setReduceAnimations,
              secondary: _settingsIcon(Icons.animation_rounded, cs.onSurface),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.hapticFeedbackEnabled ?? true,
              ),
            );
            return SwitchListTile(
              title: _settingsTitle(i18n.tr('haptic_feedback_enabled')),
              value: enabled,
              onChanged: settings.setHapticFeedbackEnabled,
              secondary: _settingsIcon(Icons.vibration_rounded, cs.onSurface),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
      ],
    ),
  ];
}

Widget _settingsIcon(IconData icon, Color color) {
  return Container(
    width: 40,
    alignment: Alignment.center,
    child: Icon(icon, color: color, size: 30),
  );
}
