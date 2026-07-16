part of 'settings_tab.dart';

List<Widget> _buildSettingsAsmrSection({
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required TextStyle? descStyle,
  required ColorScheme cs,
  required VoidCallback onChooseAsmrDownloadDestination,
}) {
  return <Widget>[
    _SectionHeader(title: i18n.tr('section_asmr_download')),
    _SettingsGroupCard(
      children: [
        Consumer(
          builder: (context, ref, _) {
            final destinationRoot = ref.watch(
              settingsStateProvider.select(
                (s) => s.valueOrNull?.asmrDownloadDestinationRoot,
              ),
            );
            final asmrDownloadPathOperation = ref.watch(
              uiOperationForScopeProvider(
                UiOperationScope.settingsAsmrDownloadPath,
              ),
            );
            return ListTile(
              onTap: onChooseAsmrDownloadDestination,
              title: Text(i18n.tr('asmr_download_path_setting')),
              subtitle: Text(
                destinationRoot == null || destinationRoot.trim().isEmpty
                    ? i18n.tr('asmr_download_path_not_set')
                    : PathDisplay.displayPathFor(destinationRoot),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: descStyle,
              ),
              leading: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: cs.onTertiaryContainer,
                ),
              ),
              trailing: IconButton.filledTonal(
                onPressed: asmrDownloadPathOperation.isBusy
                    ? null
                    : onChooseAsmrDownloadDestination,
                tooltip: i18n.tr('asmr_download_choose_path'),
                icon: asmrDownloadPathOperation.isBusy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.drive_folder_upload_rounded, size: 20),
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
            final conflictPolicy = ref.watch(
              settingsStateProvider.select(
                (s) =>
                    s.valueOrNull?.asmrDownloadConflictPolicy ??
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
              title: Text(i18n.tr('asmr_download_conflict_setting')),
              subtitle: Text(
                i18n.tr('asmr_download_conflict_setting_subtitle'),
                style: descStyle,
              ),
              leading: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Icon(
                  Icons.rule_folder_rounded,
                  color: cs.onTertiaryContainer,
                ),
              ),
              trailing: UnifiedDropdownButton<AsmrDownloadConflictPolicy>(
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
                        child: Text(
                          conflictLabels[value]!,
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
