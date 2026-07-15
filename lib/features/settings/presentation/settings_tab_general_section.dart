part of 'settings_tab.dart';

List<Widget> _buildSettingsGeneralSection({
  required AppLanguageProvider i18n,
  required AudioProvider audioProvider,
  required TextStyle? descStyle,
  required ColorScheme cs,
}) {
  return <Widget>[
    _SectionHeader(title: i18n.tr('section_general')),
    _SettingsGroupCard(
      children: [
        LayoutBuilder(
          builder: (context, constraints) => ListTile(
            title: Text(i18n.tr('language')),
            subtitle: Text(i18n.tr('language_subtitle'), style: descStyle),
            leading: constraints.maxWidth >= 300
                ? Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: AppRadius.borderMedium,
                    ),
                    child: Icon(
                      Icons.language_rounded,
                      color: cs.onPrimaryContainer,
                    ),
                  )
                : null,
            trailing: SizedBox(
              width: 72,
              child: UnifiedDropdownButton<AppLanguage>(
                isExpanded: true,
                value: i18n.language,
                onChanged: (value) {
                  if (value != null) {
                    i18n.setLanguage(value);
                  }
                },
                items: AppLanguage.values
                    .map(
                      (lang) => DropdownMenuItem<AppLanguage>(
                        value: lang,
                        child: Text(
                          i18n.languageName(lang),
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
        ),
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
              subtitle: Text(
                i18n.tr('startup_page_subtitle'),
                style: descStyle,
              ),
              leading: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(Icons.home_rounded, color: cs.onPrimaryContainer),
              ),
              trailing: UnifiedDropdownButton<StartupPage>(
                value: startupPage,
                onChanged: (value) {
                  if (value != null) {
                    audioProvider.setStartupPage(value);
                  }
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
            final dlsiteLanguage = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.valueOrNull?.dlsiteMetadataLanguage ??
                    ContentLanguagePreference.followPage,
              ),
            );
            return ListTile(
              title: Text(i18n.tr('dlsite_metadata_language')),
              subtitle: Text(
                i18n.tr('dlsite_metadata_language_subtitle'),
                style: descStyle,
              ),
              leading: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(Icons.public_rounded, color: cs.onPrimaryContainer),
              ),
              trailing: UnifiedDropdownButton<ContentLanguagePreference>(
                value: dlsiteLanguage,
                onChanged: (value) {
                  if (value != null) {
                    audioProvider.setDlsiteMetadataLanguage(value);
                  }
                },
                items: ContentLanguagePreference.values.map((preference) {
                  final language = preference.explicitLanguage;
                  return DropdownMenuItem<ContentLanguagePreference>(
                    value: preference,
                    child: Text(
                      language == null
                          ? i18n.tr('follow_page_language')
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
        if (!Platform.isWindows)
          Consumer(
            builder: (context, ref, _) {
              final hapticFeedbackEnabled = ref.watch(
                settingsStateProvider.select(
                  (s) => s.valueOrNull?.hapticFeedbackEnabled ?? true,
                ),
              );
              return SwitchListTile(
                title: Text(i18n.tr('haptic_feedback_enabled')),
                subtitle: Text(
                  i18n.tr('haptic_feedback_enabled_subtitle'),
                  style: descStyle,
                ),
                value: hapticFeedbackEnabled,
                onChanged: audioProvider.setHapticFeedbackEnabled,
                secondary: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: AppRadius.borderMedium,
                  ),
                  child: Icon(
                    Icons.vibration_rounded,
                    color: cs.onPrimaryContainer,
                  ),
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
