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
        Navigator.of(
          context,
        ).push(buildAppPageRoute<void>(child: const AsmrDownloadTaskPage()));
      },
    );
  }
}

class _AsmrCollapsingHeaderControls extends StatelessWidget {
  const _AsmrCollapsingHeaderControls({
    required this.controller,
    required this.height,
    required this.child,
  });

  final ScrollController controller;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final offset = controller.positions.length == 1
            ? controller.positions.single.pixels
            : 0.0;
        final hidden = offset.clamp(0.0, height);
        return SizedBox(
          height: height - hidden,
          child: ClipRect(
            child: OverflowBox(
              maxHeight: height,
              minHeight: height,
              alignment: Alignment.topCenter,
              child: Transform.translate(
                offset: Offset(0, -hidden),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AsmrSearchBar extends ConsumerWidget {
  const _AsmrSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SizedBox(
        height: 34,
        child: TextSelectionTheme(
          data: TextSelectionThemeData(
            cursorColor: asmrBlue,
            selectionColor: asmrBlue.withValues(alpha: 0.28),
            selectionHandleColor: asmrBlue,
          ),
          child: TextField(
            controller: controller,
            cursorColor: asmrBlue,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontSize: 13),
            textInputAction: TextInputAction.search,
            onTapOutside: (event) =>
                FocusManager.instance.primaryFocus?.unfocus(),
            onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: InputDecoration(
              filled: true,
              fillColor: cs.surfaceContainerHigh,
              prefixIcon: Icon(
                Icons.search_rounded,
                color: cs.onSurfaceVariant,
                size: 18,
              ),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  if (value.text.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: onClear,
                    color: cs.onSurfaceVariant,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  );
                },
              ),
              floatingLabelBehavior: FloatingLabelBehavior.never,
              label: MarqueeText(
                text: i18n.tr('asmr_search_hint'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                edgePadding: 0,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(tokens.radiusCard),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(tokens.radiusCard),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(tokens.radiusCard),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 7,
              ),
              isDense: true,
            ),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _AsmrCategoryButton extends StatelessWidget {
  const _AsmrCategoryButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;

    return AnimatedContainer(
      duration: tokens.motionStandard,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected ? tokens.asmrContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        border: Border.all(
          color: selected
              ? asmrBlue.withValues(alpha: isDark ? 0.58 : 0.45)
              : cs.outlineVariant.withValues(alpha: isDark ? 0.68 : 1),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          child: SizedBox(
            height: 34,
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: tokens.motionStandard,
                curve: Curves.easeOutCubic,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium!.copyWith(
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected
                      ? tokens.onAsmrContainer
                      : cs.onSurfaceVariant,
                ),
                child: Text(label),
              ),
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
