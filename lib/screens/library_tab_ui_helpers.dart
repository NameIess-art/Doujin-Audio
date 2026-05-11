part of 'library_tab.dart';

extension _LibraryTabUiHelpers on _LibraryTabState {
  Widget _buildLibraryCategoryTabs(AppLanguageProvider i18n) {
    final cs = Theme.of(context).colorScheme;
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
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 1, 12, 7),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = _categoryType == item.type;
          return ChoiceChip(
            selected: selected,
            label: Text(item.label),
            onSelected: (_) {
              if (_categoryType == item.type) return;
              _jumpLibraryListToTop();
              _setLocalState(() => _categoryType = item.type);
            },
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
            selectedColor: cs.primaryContainer,
            backgroundColor: cs.surfaceContainerHigh,
            side: BorderSide(
              color: selected
                  ? cs.primary.withValues(alpha: 0.45)
                  : cs.outlineVariant,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
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
                        onPressed: () {
                          _searchController.clear();
                          _searchDebounceTimer?.cancel();
                          context.read<AudioProvider>().setPageTransitioning(
                            false,
                          );
                          _jumpLibraryListToTop();
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
              onChanged: (value) {
                _searchDebounceTimer?.cancel();
                _searchDebounceTimer = Timer(
                  const Duration(milliseconds: 220),
                  () {
                    if (!mounted) return;
                    final nextQuery = value.trim();
                    if (_searchQuery == nextQuery) return;
                    context.read<AudioProvider>().setPageTransitioning(false);
                    _jumpLibraryListToTop();
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
    AudioProvider provider,
    String currentFolder,
    int found,
    int dup,
    int fail,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 4,
      shadowColor: cs.shadow,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                  child: Text(
                    i18n.tr('scanning_title'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => provider.cancelScan(),
                  icon: Icon(Icons.close_rounded, size: 16, color: cs.error),
                  label: Text(
                    i18n.tr('scan_cancel'),
                    style: TextStyle(color: cs.error, fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            if (currentFolder.isNotEmpty) ...[
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
                      currentFolder,
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
            Row(
              children: [
                _ScanCountChip(
                  label: i18n.tr('scan_found'),
                  count: found,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                _ScanCountChip(
                  label: i18n.tr('scan_duplicate'),
                  count: dup,
                  color: cs.tertiary,
                ),
                const SizedBox(width: 8),
                _ScanCountChip(
                  label: i18n.tr('scan_failure'),
                  count: fail,
                  color: cs.error,
                ),
              ],
            ),
          ],
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
