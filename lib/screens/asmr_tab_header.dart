part of 'asmr_tab.dart';

class _AsmrDownloadProgressButton extends StatelessWidget {
  const _AsmrDownloadProgressButton({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<AsmrDownloadManager, AsmrDownloadButtonViewState>(
          (manager) => manager.buttonViewState,
        );
    return Positioned(
      right: 16,
      bottom: bottomInset + 18,
      child: IgnorePointer(
        ignoring: !state.visible,
        child: AnimatedOpacity(
          opacity: state.visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: state.visible ? 1 : 0.92,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: FloatingActionButton.small(
              heroTag: 'asmr-one-download-progress',
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor: Theme.of(
                context,
              ).colorScheme.onSecondaryContainer,
              elevation: 0,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AsmrDownloadTaskPage(),
                  ),
                );
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Icon(Icons.downloading_rounded),
                  if (state.progress != null)
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        value: state.progress,
                        strokeWidth: 2.4,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer
                            .withValues(alpha: 0.78),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
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
            child: Transform.translate(
              offset: Offset(0, -hidden),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _AsmrSearchBar extends StatelessWidget {
  const _AsmrSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? _kAsmrBlueDark : _kAsmrBlueLight;
    final i18n = context.watch<AppLanguageProvider>();
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
            onSubmitted: (_) =>
                FocusManager.instance.primaryFocus?.unfocus(),
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
                borderRadius: BorderRadius.circular(17),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(17),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(17),
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
    final asmrBlue = isDark ? const Color(0xFF3B82F6) : const Color(0xFF1D4ED8);
    final asmrBlueContainer = isDark
        ? const Color(0xFF172554)
        : const Color(0xFFDBEAFE);
    final onAsmrBlueContainer = isDark
        ? const Color(0xFFDBEAFE)
        : const Color(0xFF1E40AF);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected ? asmrBlueContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
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
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 34,
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium!.copyWith(
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? onAsmrBlueContainer : cs.onSurfaceVariant,
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

class _AsmrMoreMenuButton extends StatelessWidget {
  const _AsmrMoreMenuButton({
    required this.onAccount,
    required this.onCategories,
    required this.onLanguage,
  });

  final VoidCallback onAccount;
  final VoidCallback onCategories;
  final VoidCallback onLanguage;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return UnifiedPopupMenuButton<_AsmrMoreAction>(
      icon: Icons.more_horiz_rounded,
      tooltip: i18n.tr('asmr_more'),
      menuWidth: 220,
      selectAfterDismiss: false,
      entries: [
        UnifiedMenuEntry<_AsmrMoreAction>.action(
          value: _AsmrMoreAction.account,
          icon: Icons.account_circle_rounded,
          label: i18n.tr('asmr_account_menu'),
        ),
        UnifiedMenuEntry<_AsmrMoreAction>.action(
          value: _AsmrMoreAction.categories,
          icon: Icons.category_rounded,
          label: i18n.tr('asmr_categories_title'),
        ),
        UnifiedMenuEntry<_AsmrMoreAction>.action(
          value: _AsmrMoreAction.language,
          icon: Icons.language_rounded,
          label: i18n.tr('asmr_language_title'),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case _AsmrMoreAction.account:
            onAccount();
            break;
          case _AsmrMoreAction.categories:
            onCategories();
            break;
          case _AsmrMoreAction.language:
            onLanguage();
            break;
        }
      },
    );
  }
}

enum _AsmrMoreAction { account, categories, language }

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

String _asmrLanguageLabelKey(AsmrContentLanguage language) {
  return switch (language) {
    AsmrContentLanguage.zh => 'asmr_language_zh',
    AsmrContentLanguage.ja => 'asmr_language_ja',
    AsmrContentLanguage.en => 'asmr_language_en',
  };
}
