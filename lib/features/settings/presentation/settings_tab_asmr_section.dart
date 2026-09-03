part of 'settings_tab.dart';

List<Widget> _buildSettingsAsmrSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required ColorScheme cs,
  required VoidCallback onChooseAsmrDownloadDestination,
}) {
  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_download'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final destinationRoot = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.asmrDownloadDestinationRoot,
              ),
            );
            final asmrDownloadPathOperation = ref.watch(
              uiOperationForScopeProvider(
                UiOperationScope.settingsAsmrDownloadPath,
              ),
            );
            return ListTile(
              onTap: onChooseAsmrDownloadDestination,
              title: _SettingsTitleBlock(
                title: i18n.tr('asmr_download_path_setting'),
                subtitle: Text(
                  destinationRoot == null || destinationRoot.trim().isEmpty
                      ? i18n.tr('asmr_download_path_not_set')
                      : PathDisplay.displayPathFor(destinationRoot),
                  softWrap: true,
                ),
              ),
              leading: _settingsIcon(Icons.folder_rounded, cs.onSurface),
              trailing: IconButton(
                onPressed: asmrDownloadPathOperation.isBusy
                    ? null
                    : onChooseAsmrDownloadDestination,
                tooltip: i18n.tr('asmr_download_choose_path'),
                color: cs.onSurfaceVariant,
                icon: asmrDownloadPathOperation.isBusy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.drive_folder_upload_rounded, size: 20),
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.borderCard,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final conflictPolicy = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.asmrDownloadConflictPolicy ??
                    AsmrDownloadConflictPolicy.overwrite,
              ),
            );
            final conflictLabels = <AsmrDownloadConflictPolicy, String>{
              AsmrDownloadConflictPolicy.overwrite: i18n.tr(
                'asmr_download_conflict_overwrite',
              ),
              AsmrDownloadConflictPolicy.skip: i18n.tr(
                'asmr_download_conflict_skip',
              ),
            };
            return ListTile(
              title: _settingsTitle(i18n.tr('asmr_download_conflict_setting')),
              leading: _settingsIcon(Icons.rule_folder_rounded, cs.onSurface),
              trailing: _settingsDropdown<AsmrDownloadConflictPolicy>(
                context,
                value: conflictPolicy,
                onChanged: (value) {
                  if (value != null) {
                    settings.setAsmrDownloadConflictPolicy(value);
                  }
                },
                items: AsmrDownloadConflictPolicy.values
                    .map(
                      (value) => DropdownMenuItem<AsmrDownloadConflictPolicy>(
                        value: value,
                        child: _settingsDropdownText(conflictLabels[value]!),
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
            final retryCount = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.asmrDownloadRetryCount ??
                    kDefaultAsmrDownloadRetryCount,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('asmr_download_retry_count')),
              leading: _settingsIcon(Icons.refresh_rounded, cs.onSurface),
              trailing: _settingsDropdown<int>(
                context,
                value: retryCount,
                onChanged: (value) {
                  if (value != null) settings.setAsmrDownloadRetryCount(value);
                },
                items:
                    <int>[
                          for (
                            var value = kMinAsmrDownloadRetryCount;
                            value <= kMaxAsmrDownloadRetryCount;
                            value++
                          )
                            value,
                        ]
                        .map(
                          (value) => DropdownMenuItem<int>(
                            value: value,
                            child: _settingsDropdownText(value.toString()),
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
            final threadCount = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.asmrDownloadThreadCount ??
                    kDefaultAsmrDownloadThreadCount,
              ),
            );
            return ListTile(
              title: _settingsTitle(i18n.tr('asmr_download_thread_count')),
              leading: _settingsIcon(Icons.dynamic_feed_rounded, cs.onSurface),
              trailing: _settingsDropdown<int>(
                context,
                value: threadCount,
                onChanged: (value) {
                  if (value != null) {
                    settings.setAsmrDownloadThreadCount(value);
                  }
                },
                items:
                    <int>[
                          for (
                            var value = kMinAsmrDownloadThreadCount;
                            value <= kMaxAsmrDownloadThreadCount;
                            value++
                          )
                            value,
                        ]
                        .map(
                          (value) => DropdownMenuItem<int>(
                            value: value,
                            child: _settingsDropdownText(value.toString()),
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
      title: i18n.tr('settings_group_download_files'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final saveMetadata = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.asmrDownloadSaveMetadata ?? true,
              ),
            );
            return SwitchListTile(
              value: saveMetadata,
              onChanged: settings.setAsmrDownloadSaveMetadata,
              title: _settingsTitle(
                i18n.tr('asmr_download_save_metadata_setting'),
              ),
              secondary: _settingsIcon(
                Icons.description_outlined,
                cs.onSurface,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final saveCover = ref.watch(
              settingsStateProvider.select(
                (s) => s.value?.asmrDownloadSaveCover ?? true,
              ),
            );
            return SwitchListTile(
              value: saveCover,
              onChanged: settings.setAsmrDownloadSaveCover,
              title: _settingsTitle(i18n.tr('asmr_download_save_cover')),
              secondary: _settingsIcon(Icons.image_outlined, cs.onSurface),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final fields = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.value?.asmrDownloadFolderNameFields ??
                    kDefaultAsmrDownloadFolderNameFields,
              ),
            );
            return ListTile(
              onTap: () => AppBottomSheet.show<void>(
                context: context,
                builder: (_) => const _AsmrDownloadFolderNameSettingsSheet(),
              ),
              title: _SettingsTitleBlock(
                title: i18n.tr('asmr_download_folder_name_setting'),
                subtitle: Text(
                  fields
                      .map(
                        (field) =>
                            _asmrDownloadFolderNameFieldLabel(i18n, field),
                      )
                      .join(' - '),
                  softWrap: true,
                ),
              ),
              leading: _settingsIcon(
                Icons.drive_file_rename_outline,
                cs.onSurface,
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: cs.onSurfaceVariant,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
      ],
    ),
  ];
}
