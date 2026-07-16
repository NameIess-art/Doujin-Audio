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
  required TextStyle? descStyle,
  required ColorScheme cs,
  required VoidCallback onOpenDataAndSupport,
  required VoidCallback onClearApplicationCache,
}) {
  return <Widget>[
    _SectionHeader(title: i18n.tr('section_data_storage')),
    _SettingsGroupCard(
      children: [
        ListTile(
          onTap: onOpenDataAndSupport,
          title: Text(i18n.tr('data_and_support')),
          subtitle: Text(
            i18n.tr('data_and_support_subtitle'),
            style: descStyle,
          ),
          leading: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: cs.secondaryContainer,
              borderRadius: AppRadius.borderMedium,
            ),
            child: Icon(
              Icons.health_and_safety_rounded,
              color: cs.onSecondaryContainer,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderCard,
          ),
        ),
        if (!Platform.isWindows) ...[
          Consumer(
            builder: (context, ref, _) {
              final maxCacheBytes = ref.watch(
                settingsStateProvider.select(
                  (s) =>
                      s.valueOrNull?.maxCacheBytes ??
                      AppCacheService.defaultMaxCacheBytes,
                ),
              );
              return ListTile(
                title: Text(i18n.tr('max_cache_size')),
                subtitle: Text(
                  i18n.tr('max_cache_size_subtitle', {
                    'size': AppCacheService.formatBytes(maxCacheBytes),
                  }),
                  style: descStyle,
                ),
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: AppRadius.borderMedium,
                  ),
                  child: Icon(
                    Icons.storage_rounded,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                trailing: UnifiedDropdownButton<int>(
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
                          child: Text(
                            AppCacheService.formatBytes(value),
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
              final cacheOperation = ref.watch(
                uiOperationForScopeProvider(UiOperationScope.settingsCache),
              );
              return ListTile(
                onTap: cacheOperation.isBusy ? null : onClearApplicationCache,
                title: Text(i18n.tr('clear_app_cache')),
                subtitle: Text(
                  i18n.tr('clear_app_cache_subtitle'),
                  style: descStyle,
                ),
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: AppRadius.borderMedium,
                  ),
                  child: Icon(
                    Icons.cleaning_services_rounded,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
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
      ],
    ),
  ];
}
