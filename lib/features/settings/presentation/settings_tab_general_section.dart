part of 'settings_tab.dart';

const double _interfaceLanguageDropdownMaxWidth = 128;

List<Widget> _buildSettingsLanguageSection({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('language'),
      children: [
        ListTile(
          title: _settingsTitle(i18n.tr('interface_language')),
          leading: _settingsIcon(Icons.language_rounded, cs.onSurface),
          trailing: _settingsDropdown<AppLanguagePreference>(
            context,
            value: i18n.preference,
            maxWidth: _interfaceLanguageDropdownMaxWidth,
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
  required BuildContext context,
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
}) {
  return <Widget>[
    ..._buildSettingsLanguageSection(
      context: context,
      i18n: i18n,
      settings: settings,
      cs: cs,
    ),
    ..._buildSettingsPageDisplaySection(i18n: i18n, settings: settings, cs: cs),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_startup_behavior'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final settingsValue = ref.watch(settingsStateProvider).value;
            final showLocal = settingsValue?.showLocalLibrary ?? true;
            final showAsmr = settingsValue?.showAsmrOne ?? true;
            final startupPage =
                settingsValue?.startupPage ?? StartupPage.library;
            final availablePages = StartupPage.values
                .where((page) {
                  if (page == StartupPage.library) return showLocal;
                  if (page == StartupPage.asmrOne) return showAsmr;
                  return true;
                })
                .toList(growable: false);
            final effectiveStartupPage = availablePages.contains(startupPage)
                ? startupPage
                : availablePages.first;
            return ListTile(
              title: _settingsTitle(i18n.tr('startup_page')),
              leading: _settingsIcon(Icons.home_rounded, cs.onSurface),
              trailing: _settingsDropdown<StartupPage>(
                context,
                value: effectiveStartupPage,
                onChanged: (value) {
                  if (value != null) settings.setStartupPage(value);
                },
                items: availablePages
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

List<Widget> _buildSettingsPageDisplaySection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_page_display'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final settingsState = ref.watch(settingsStateProvider).value;
            final showLocal = settingsState?.showLocalLibrary ?? true;
            final showAsmr = settingsState?.showAsmrOne ?? true;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  key: const ValueKey<String>('settings_show_asmr_one_switch'),
                  title: _settingsTitle(i18n.tr('show_asmr_one')),
                  value: showAsmr,
                  onChanged: showLocal
                      ? (value) => unawaited(settings.setShowAsmrOne(value))
                      : null,
                  secondary: _settingsIcon(Icons.cloud_outlined, cs.onSurface),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                SwitchListTile(
                  key: const ValueKey<String>(
                    'settings_show_local_library_switch',
                  ),
                  title: _settingsTitle(i18n.tr('show_local_library')),
                  value: showLocal,
                  onChanged: showAsmr
                      ? (value) =>
                            unawaited(settings.setShowLocalLibrary(value))
                      : null,
                  secondary: _settingsIcon(
                    Icons.library_music_rounded,
                    cs.onSurface,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ],
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
