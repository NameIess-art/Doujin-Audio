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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(AppRadius.small),
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
    required this.isBusy,
    required this.bottomInset,
    this.topInset = AppSpacing.md,
    this.physics,
  });

  final VoidCallback onImportLibrary;
  final VoidCallback onImportFolder;
  final VoidCallback onImportFile;
  final bool isBusy;
  final double bottomInset;
  final double topInset;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        topInset,
        AppSpacing.xl,
        bottomInset,
      ),
      physics: physics ?? const ClampingScrollPhysics(),
      children: [
        const SizedBox(height: AppSpacing.lg),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: AppRadius.borderDialog,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.surfaceContainerHigh.withValues(alpha: 0.6),
                cs.surfaceContainerLow.withValues(alpha: 0.4),
              ],
            ),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.1)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: 42,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Lottie.asset(
                  'assets/lottie/empty_library.json',
                  width: 140,
                  height: 140,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            cs.primaryContainer,
                            cs.primaryContainer.withValues(alpha: 0.8),
                          ],
                        ),
                        borderRadius: AppRadius.borderMedium,
                        boxShadow: [
                          BoxShadow(
                            color: cs.primary.withValues(alpha: 0.12),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.audio_file_rounded,
                        size: 36,
                        color: cs.onPrimaryContainer,
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  i18n.tr('no_audio_files'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  i18n.tr('import_audio_hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 220,
                      child: AppSecondaryButton(
                        onPressed: isBusy ? null : onImportFolder,
                        isLoading: isBusy,
                        icon: Icons.create_new_folder_rounded,
                        label: i18n.tr('import_folder'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: 220,
                      child: AppSecondaryButton(
                        onPressed: isBusy ? null : onImportFile,
                        icon: Icons.upload_file_rounded,
                        label: i18n.tr('import_file'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: 220,
                      child: AppSecondaryButton(
                        onPressed: isBusy ? null : onImportLibrary,
                        icon: Icons.library_add_rounded,
                        label: i18n.tr('import_library'),
                      ),
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
