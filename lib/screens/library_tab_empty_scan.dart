part of 'library_tab.dart';

class _ScanCountChip extends StatelessWidget {
  const _ScanCountChip({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({
    required this.onImportLibrary,
    required this.onImportFolder,
    required this.onImportFile,
    required this.bottomInset,
  });

  final VoidCallback onImportLibrary;
  final VoidCallback onImportFolder;
  final VoidCallback onImportFile;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 16, 24, bottomInset),
      physics: const BouncingScrollPhysics(),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    Icons.audio_file_rounded,
                    size: 30,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  i18n.tr('no_audio_files'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  i18n.tr('import_audio_hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onImportLibrary,
                      icon: const Icon(Icons.library_add_rounded),
                      label: Text(i18n.tr('import_library')),
                    ),
                    FilledButton.icon(
                      onPressed: onImportFolder,
                      icon: const Icon(Icons.create_new_folder_rounded),
                      label: Text(i18n.tr('import_folder')),
                    ),
                    OutlinedButton.icon(
                      onPressed: onImportFile,
                      icon: const Icon(Icons.upload_file_rounded),
                      label: Text(i18n.tr('import_file')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
