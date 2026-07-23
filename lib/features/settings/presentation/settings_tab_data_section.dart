part of 'settings_tab.dart';

const List<int> _settingsCacheLimitOptions = <int>[
  100 * 1024 * 1024,
  300 * 1024 * 1024,
  500 * 1024 * 1024,
  1024 * 1024 * 1024,
  2 * 1024 * 1024 * 1024,
];

List<Widget> _buildSettingsDataSection({
  required AppLanguageProvider i18n,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
  required VoidCallback onOpenDataAndSupport,
  required VoidCallback onClearApplicationCache,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_data'),
      children: [
        ListTile(
          onTap: onOpenDataAndSupport,
          title: _settingsTitle(i18n.tr('data_and_support')),
          leading: _settingsIcon(Icons.health_and_safety_rounded, cs.onSurface),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderCard,
          ),
        ),
      ],
    ),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_cache'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final maxCacheBytes = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.maxCacheBytes ??
                    AppCacheService.defaultMaxCacheBytes,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('max_cache_size')),
              subtitle: Text(
                AppCacheService.formatBytes(maxCacheBytes),
                softWrap: true,
              ),
              leading: _settingsIcon(Icons.storage_rounded, cs.onSurface),
              trailing: _settingsDropdown<int>(
                context,
                value: _settingsCacheLimitOptions.contains(maxCacheBytes)
                    ? maxCacheBytes
                    : AppCacheService.defaultMaxCacheBytes,
                onChanged: (value) {
                  if (value != null) {
                    settingsController.setMaxCacheBytes(value);
                  }
                },
                items: _settingsCacheLimitOptions
                    .map(
                      (value) => DropdownMenuItem<int>(
                        value: value,
                        child: _settingsDropdownText(
                          AppCacheService.formatBytes(value),
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
            final cacheOperation = ref.watch(
              uiOperationForScopeProvider(UiOperationScope.settingsCache),
            );
            return ListTile(
              onTap: cacheOperation.isBusy ? null : onClearApplicationCache,
              title: _settingsTitle(i18n.tr('clear_app_cache')),
              leading: _settingsIcon(
                Icons.cleaning_services_rounded,
                cs.onSurface,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              trailing: cacheOperation.isBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : null,
            );
          },
        ),
      ],
    ),
  ];
}
