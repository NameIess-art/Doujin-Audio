part of 'settings_tab.dart';

List<Widget> _buildSettingsUpdateSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required ColorScheme cs,
  required AppUpdateInfo? updateInfo,
  required Future<AppVersionInfo> currentVersion,
  required VoidCallback onCheckForUpdates,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_permissions'),
      childrenUseOwnCards: true,
      children: const [PermissionSettingsControls()],
    ),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_updates'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final updateOperation = ref.watch(
              uiOperationForScopeProvider(UiOperationScope.settingsUpdate),
            );
            final downloading =
                updateOperation.isBusy &&
                updateOperation.labelKey == 'downloading_update';
            return _UpdateSettingsTile(
              checking: updateOperation.isBusy && !downloading,
              downloading: downloading,
              progress: updateOperation.progress,
              updateInfo: updateInfo,
              currentVersion: currentVersion,
              textStyle: null,
              onCheck: onCheckForUpdates,
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final autoCheckUpdates = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.autoCheckUpdates ?? false,
              ),
            );
            return SwitchListTile(
              value: autoCheckUpdates,
              onChanged: settings.setAutoCheckUpdates,
              title: _settingsTitle(i18n.tr('auto_check_updates')),
              secondary: _settingsIcon(Icons.update_rounded, cs.onSurface),
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
