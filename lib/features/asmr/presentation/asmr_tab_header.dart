part of 'asmr_tab.dart';

class _AsmrDownloadProgressInlineButton extends ConsumerWidget {
  const _AsmrDownloadProgressInlineButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final state =
        ref.watch(asmrDownloadButtonViewStateProvider).value ??
        const AsmrDownloadButtonViewState(visible: false, progress: null);
    final reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedSize(
      duration: reducedMotion ? Duration.zero : kAppMotionFast,
      curve: kAppSpringCurve,
      alignment: Alignment.centerRight,
      child: AppDeferredFade(
        visible: state.visible,
        beginScale: 0.88,
        fadeInDuration: kAppMotionFast,
        fadeOutDuration: const Duration(milliseconds: 160),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: HeaderFloatingButton(
            child: IconButton(
              icon: RepaintBoundary(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.downloading_rounded),
                    if (state.progress != null)
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: state.progress!),
                          duration: reducedMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) =>
                              CircularProgressIndicator(
                                value: value,
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ),
                  ],
                ),
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
            ),
          ),
        ),
      ),
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
    final isLoggedIn = ref.watch(
      asmrAuthStateProvider.select((state) => state.value?.isLoggedIn ?? false),
    );
    final syncFailed = ref.watch(
      asmrSyncStateProvider.select(
        (state) => state.value?.phase == AsmrSyncPhase.failed,
      ),
    );
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final badgeColor = !isLoggedIn
        ? null
        : syncFailed
        ? cs.error
        : tokens.success;
    return IconButton(
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            Icons.account_circle_rounded,
            color: syncFailed && isLoggedIn ? cs.error : null,
          ),
          if (badgeColor != null)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                key: ValueKey<String>(
                  syncFailed
                      ? 'asmr_account_status_error'
                      : 'asmr_account_status_logged_in',
                ),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
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
