part of 'settings_tab.dart';

List<Widget> _buildSettingsAppearanceSection({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
  required VoidCallback onShowSubtitleWindowSettings,
  required VoidCallback onShowCardInfoFieldsSettings,
}) {
  final coverResolutionLabels = <CoverImageResolution, String>{
    CoverImageResolution.memorySaver: i18n.tr('cover_image_resolution_300'),
    CoverImageResolution.balanced: i18n.tr('cover_image_resolution_600'),
    CoverImageResolution.high: i18n.tr('cover_image_resolution_900'),
    CoverImageResolution.original: i18n.tr('cover_image_resolution_original'),
  };

  return <Widget>[
    _SettingsGroupCard(
      children: [
        Consumer(
          builder: (context, ref, _) {
            final themeMode =
                ref.watch(themeStateProvider).value?.themeMode ??
                ref.read(themeProviderInstanceProvider).themeMode;
            final modeLabels = <ThemeMode, String>{
              ThemeMode.system: i18n.tr('theme_system'),
              ThemeMode.light: i18n.tr('theme_light'),
              ThemeMode.dark: i18n.tr('theme_dark'),
            };
            return ListTile(
              title: _settingsTitle(i18n.tr('dark_mode')),
              leading: _settingsIcon(Icons.dark_mode_rounded, cs.primary),
              trailing: _settingsDropdown<ThemeMode>(
                context,
                value: themeMode,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(themeProviderInstanceProvider).setThemeMode(value);
                  }
                },
                items: ThemeMode.values
                    .map(
                      (mode) => DropdownMenuItem<ThemeMode>(
                        value: mode,
                        child: _settingsDropdownText(modeLabels[mode]!),
                      ),
                    )
                    .toList(),
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
            final themeState =
                ref.watch(themeStateProvider).value ??
                ThemeState.from(ref.read(themeProviderInstanceProvider));
            final provider = ref.read(themeProviderInstanceProvider);
            return SwitchListTile(
              title: _settingsTitle(i18n.tr('differentiate_asmr_theme')),
              value: themeState.differentiateAsmrTheme,
              onChanged: (val) => provider.setDifferentiateAsmrTheme(val),
              secondary: _settingsIcon(Icons.palette_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        ListTile(
          title: _settingsTitle(i18n.tr('cover_image_resolution')),
          leading: _settingsIcon(
            Icons.photo_size_select_large_rounded,
            cs.primary,
          ),
          trailing: Consumer(
            builder: (context, ref, _) {
              return _settingsDropdown<CoverImageResolution>(
                context,
                value: ref.watch(coverImageResolutionProvider),
                onChanged: (value) {
                  if (value != null) {
                    settingsController.setCoverImageResolution(value);
                  }
                },
                items: CoverImageResolution.values
                    .map(
                      (value) => DropdownMenuItem<CoverImageResolution>(
                        value: value,
                        child: _settingsDropdownText(
                          coverResolutionLabels[value]!,
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderCard,
          ),
        ),
        Consumer(
          builder: (context, ref, _) {
            final style = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.bottomNavigationStyle ??
                    BottomNavigationStyle.capsule,
              ),
            );
            return SwitchListTile(
              value: style == BottomNavigationStyle.capsule,
              onChanged: (value) {
                settings.setBottomNavigationStyle(
                  value
                      ? BottomNavigationStyle.capsule
                      : BottomNavigationStyle.bar,
                );
              },
              title: _settingsTitle(i18n.tr('bottom_navigation_style')),
              secondary: _settingsIcon(Icons.space_bar_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final uiBlurEnabled = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.uiBlurEffectEnabled ?? true,
              ),
            );
            return SwitchListTile(
              value: uiBlurEnabled,
              onChanged: settings.setUiBlurEffectEnabled,
              title: _settingsTitle(i18n.tr('ui_blur_effect')),
              secondary: _settingsIcon(Icons.blur_linear_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final blurEnabled = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.blurPlayerBackgroundEnabled ?? true,
              ),
            );
            return SwitchListTile(
              value: blurEnabled,
              onChanged: settings.setBlurPlayerBackgroundEnabled,
              title: _settingsTitle(i18n.tr('blur_player_background')),
              secondary: _settingsIcon(Icons.blur_on_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final showPlaybackCard = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.showPlaybackCard ?? true,
              ),
            );
            return SwitchListTile(
              value: showPlaybackCard,
              onChanged: settings.setShowPlaybackCard,
              title: _settingsTitle(i18n.tr('show_playback_card')),
              secondary: _settingsIcon(
                Icons.play_circle_outline_rounded,
                cs.primary,
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
            final fields = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.cardInfoFields ?? CardInfoField.defaults,
              ),
            );
            final summary = fields.isEmpty
                ? i18n.tr('card_info_none')
                : fields
                      .map((field) => _cardInfoFieldLabel(i18n, field))
                      .join('\uFF0C');
            return ListTile(
              title: _settingsTitle(i18n.tr('card_info_display')),
              subtitle: Text(summary, softWrap: true),
              leading: _settingsIcon(Icons.badge_rounded, cs.primary),
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: cs.primary,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
              onTap: onShowCardInfoFieldsSettings,
            );
          },
        ),
        ListTile(
          title: _settingsTitle(i18n.tr('subtitle_window_settings')),
          leading: _settingsIcon(Icons.subtitles_rounded, cs.primary),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.primary,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderCard,
          ),
          onTap: onShowSubtitleWindowSettings,
        ),
      ],
    ),
  ];
}
