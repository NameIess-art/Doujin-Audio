part of 'settings_tab.dart';

List<Widget> _buildSettingsUpdateSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required TextStyle? descStyle,
  required ColorScheme cs,
  required AppUpdateInfo? updateInfo,
  required Future<AppVersionInfo> currentVersion,
  required VoidCallback onOpenPermissionCenter,
  required VoidCallback onCheckForUpdates,
}) {
  return <Widget>[
    _SectionHeader(title: i18n.tr('section_system_updates')),
    _SettingsGroupCard(
      children: [
        if (!Platform.isWindows) ...[
          ListTile(
            onTap: onOpenPermissionCenter,
            title: Text(i18n.tr('permission_center')),
            subtitle: Text(
              i18n.tr('permission_center_subtitle'),
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
                Icons.admin_panel_settings_rounded,
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
        ],
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
              textStyle: descStyle,
              onCheck: onCheckForUpdates,
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final autoCheckUpdates = ref.watch(
              settingsStateProvider.select(
                (s) => s.valueOrNull?.autoCheckUpdates ?? false,
              ),
            );
            return SwitchListTile(
              value: autoCheckUpdates,
              onChanged: settings.setAutoCheckUpdates,
              title: Text(i18n.tr('auto_check_updates')),
              subtitle: Text(
                i18n.tr('auto_check_updates_subtitle'),
                style: descStyle,
              ),
              secondary: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.update_rounded,
                  color: cs.onSecondaryContainer,
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
