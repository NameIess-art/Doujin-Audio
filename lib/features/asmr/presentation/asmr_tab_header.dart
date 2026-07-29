part of 'asmr_tab.dart';

class _AsmrDownloadProgressInlineButton extends ConsumerWidget {
  const _AsmrDownloadProgressInlineButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final manager = ref.read(asmrDownloadManagerProvider);
    final state = ref.watch(asmrDownloadStateProvider).value != null
        ? manager?.buttonViewState ??
              const AsmrDownloadButtonViewState(visible: false, progress: null)
        : const AsmrDownloadButtonViewState(visible: false, progress: null);
    if (!state.visible) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(Icons.downloading_rounded),
          if (state.progress != null)
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: state.progress,
                strokeWidth: 2,
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.78),
              ),
            ),
        ],
      ),
      tooltip: i18n.tr('downloads'),
      onPressed: () {
        Navigator.of(context).push(
          buildAppPageRoute<void>(
            context: context,
            child: const AsmrDownloadTaskPage(),
          ),
        );
      },
    );
  }
}

class _AsmrAccountButton extends ConsumerWidget {
  const _AsmrAccountButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return IconButton(
      onPressed: onPressed,
      icon: const Icon(Icons.account_circle_rounded),
      tooltip: i18n.tr('asmr_account_menu'),
    );
  }
}

String _asmrCategoryLabelKey(AsmrCategoryType category) {
  return switch (category) {
    AsmrCategoryType.collected => 'asmr_category_collected',
    AsmrCategoryType.recommendation => 'asmr_category_recommendation',
    AsmrCategoryType.sales => 'asmr_category_sales',
    AsmrCategoryType.rating => 'asmr_category_rating',
    AsmrCategoryType.reviews => 'asmr_category_reviews',
    AsmrCategoryType.release => 'asmr_category_release',
    AsmrCategoryType.favorites => 'asmr_category_favorites',
    AsmrCategoryType.history => 'asmr_category_history',
  };
}
