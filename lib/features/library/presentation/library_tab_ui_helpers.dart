part of 'library_tab.dart';

extension _LibraryTabUiHelpers on _LibraryTabState {
  Widget _buildLibraryCategoryTabs(AppLanguageProvider i18n) {
    final items = <({AudioLibraryCategoryType type, String label})>[
      (
        type: AudioLibraryCategoryType.all,
        label: i18n.tr('library_category_all'),
      ),
      (
        type: AudioLibraryCategoryType.tags,
        label: i18n.tr('library_category_tags'),
      ),
      (
        type: AudioLibraryCategoryType.voiceActors,
        label: i18n.tr('library_category_voice_actors'),
      ),
      (
        type: AudioLibraryCategoryType.circles,
        label: i18n.tr('library_category_circles'),
      ),
    ];
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isPortraitMobile =
        MediaQuery.orientationOf(context) == Orientation.portrait;

    final itemWidth = isPortraitMobile ? (screenWidth - 24.0 - 24.0) / 4 : 86.0;

    return SizedBox(
      height: 34 + 8,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 1, 12, 7),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return SizedBox(
            width: itemWidth,
            child: _LibraryCategoryButton(
              label: items[index].label,
              selected: _categoryType == items[index].type,
              onTap: () {
                if (_categoryType == items[index].type) return;
                FocusScope.of(context).unfocus();

                _setLocalState(() {
                  _categoryType = items[index].type;
                  _hasSwitchedCategory = true;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) measureHeader();
                });
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchBar(
    AppLanguageProvider i18n,
    int matchCount,
    int totalCount,
  ) {
    final cs = Theme.of(context).colorScheme;
    final hasText = _searchController.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 34,
            child: TextField(
              controller: _searchController,
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
                suffixIcon: hasText
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        tooltip: i18n.tr('clear'),
                        onPressed: () {
                          _searchController.clear();
                          _searchDebounceTimer?.cancel();
                          jumpToTop();
                          _setLocalState(() => _searchQuery = '');
                        },
                        color: cs.onSurfaceVariant,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      )
                    : null,
                hintText: i18n.tr('search_audio_placeholder'),
                hintStyle: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    AppDesignTokens.of(context).radiusCard,
                  ),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    AppDesignTokens.of(context).radiusCard,
                  ),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    AppDesignTokens.of(context).radiusCard,
                  ),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                isDense: true,
              ),
              onChanged: (value) {
                _searchDebounceTimer?.cancel();
                _searchDebounceTimer = Timer(
                  const Duration(milliseconds: 220),
                  () {
                    if (!mounted) return;
                    final nextQuery = value.trim();
                    if (_searchQuery == nextQuery) return;
                    jumpToTop();
                    _setLocalState(() => _searchQuery = nextQuery);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanProgressCard(
    AppLanguageProvider i18n,
    LibraryScanUiState scanState,
  ) {
    final cs = Theme.of(context).colorScheme;
    final total = scanState.total;
    final progress = total != null && total > 0
        ? (scanState.processed / total).clamp(0.0, 1.0)
        : null;
    final stageLabel = i18n.tr(switch (scanState.stage) {
      FolderScanStage.preparing => 'scan_stage_preparing',
      FolderScanStage.enumerating => 'scan_stage_enumerating',
      FolderScanStage.merging => 'scan_stage_merging',
      FolderScanStage.saving => 'scan_stage_saving',
      FolderScanStage.loadingCovers => 'scan_stage_covers',
      FolderScanStage.idle => 'scanning_title',
    });
    final tokens = AppDesignTokens.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      label: stageLabel,
      child: Card(
        key: const ValueKey('library_scan_progress_card'),
        elevation: 4,
        shadowColor: cs.shadow,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        stageLabel,
                        key: ValueKey(scanState.stage),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _scanCoordinator.cancel(
                      ref.read(libraryFacadeProvider),
                    ),
                    icon: Icon(Icons.close_rounded, size: 16, color: cs.error),
                    label: Text(
                      i18n.tr('scan_cancel'),
                      style: TextStyle(color: cs.error, fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (scanState.source.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        scanState.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  total == null
                      ? i18n.tr('scan_processed', {
                          'processed': scanState.processed,
                        })
                      : i18n.tr('scan_processed_total', {
                          'processed': scanState.processed,
                          'total': total,
                        }),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ScanCountChip(
                    label: i18n.tr('scan_found'),
                    count: scanState.foundCount,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  _ScanCountChip(
                    label: i18n.tr('scan_duplicate'),
                    count: scanState.duplicateCount,
                    color: cs.tertiary,
                  ),
                  const SizedBox(width: 8),
                  _ScanCountChip(
                    label: i18n.tr('scan_failure'),
                    count: scanState.failureCount,
                    color: cs.error,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReorderProxy(
    BuildContext context,
    Widget child,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final double animValue = Curves.easeInOut.transform(animation.value);
        final double scale = 1.0 + (0.012 * animValue);
        final double elevation = 3.0 * animValue;

        return Transform.scale(
          scale: scale,
          child: Material(
            elevation: elevation,
            color: Colors.transparent,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.12),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _LibraryCategoryButton extends StatelessWidget {
  const _LibraryCategoryButton({
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
    final tokens = AppDesignTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedScale(
        scale: selected ? 1.0 : 0.98,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : tokens.motionStandard,
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : tokens.motionStandard,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(tokens.radiusCard),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: isDark ? 0.58 : 0.45)
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
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : tokens.motionStandard,
                    curve: Curves.easeOutCubic,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium!.copyWith(
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: selected
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant,
                    ),
                    child: Text(label),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
