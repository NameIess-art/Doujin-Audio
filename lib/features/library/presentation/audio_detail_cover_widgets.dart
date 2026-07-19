part of 'audio_detail_sheet.dart';

class _SingleFileCoverPreview extends ConsumerStatefulWidget {
  const _SingleFileCoverPreview({required this.filePath});

  final String filePath;

  @override
  ConsumerState<_SingleFileCoverPreview> createState() =>
      _SingleFileCoverPreviewState();
}

class _SingleFileCoverPreviewState
    extends ConsumerState<_SingleFileCoverPreview> {
  Future<String?>? _coverFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _futureFor(
    LibraryFacade library,
    MusicTrack track,
    int coverGeneration,
  ) {
    if (_lastTrackPath != track.path ||
        _lastCoverGeneration != coverGeneration) {
      _lastTrackPath = track.path;
      _lastCoverGeneration = coverGeneration;
      _coverFuture = library.coverPathFutureForTrack(track);
    }
    return _coverFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final track = ref.watch(libraryTrackProvider(widget.filePath));
    if (track == null) return const SizedBox.shrink();

    final coverGeneration = ref.watch(coverGenerationProvider);
    final initialPath = library.resolvedCoverPathForTrack(track);
    final coverFuture = _futureFor(library, track, coverGeneration);
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(coverImageResolutionProvider),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    return FutureBuilder<String?>(
      future: coverFuture,
      initialData: initialPath,
      builder: (context, snapshot) {
        final coverPath = snapshot.data;
        if (coverPath == null || coverPath.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          key: const ValueKey('audio_detail_single_cover_loaded'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: 1.45,
                child: RetryingFileImage(
                  path: coverPath,
                  fit: BoxFit.cover,
                  cacheWidth: coverCacheWidth,
                  useDefaultCacheWidth: coverCacheWidth != null,
                  fallbackBuilder: (_) => const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FolderCoverSelector extends ConsumerStatefulWidget {
  const _FolderCoverSelector({
    super.key,
    required this.folderPath,
    this.initialCoverPath,
    this.onCoverSelected,
  });

  final String folderPath;
  final String? initialCoverPath;
  final ValueChanged<String>? onCoverSelected;

  @override
  ConsumerState<_FolderCoverSelector> createState() =>
      _FolderCoverSelectorState();
}

class _FolderCoverSelectorState extends ConsumerState<_FolderCoverSelector> {
  PageController? _pageController;
  List<String> _images = const <String>[];
  String? _currentCoverPath;
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    final initialCoverPath = widget.initialCoverPath;
    if (initialCoverPath != null && initialCoverPath.isNotEmpty) {
      _images = <String>[initialCoverPath];
      _currentCoverPath = initialCoverPath;
      _loading = false;
      _pageController = PageController();
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final library = ref.read(libraryFacadeProvider);
      final currentCover = await library.coverPathFutureForFolder(
        widget.folderPath,
      );
      final discoveredImages = await library.discoverCoverCandidatesInFolder(
        widget.folderPath,
        selectedCoverPath: currentCover ?? widget.initialCoverPath,
      );
      final images = discoveredImages;
      if (!mounted) return;
      if (images.isEmpty) {
        setState(() {
          _images = const <String>[];
          _loading = false;
        });
        return;
      }
      var initialIndex = 0;
      if (currentCover != null) {
        final foundIndex = images.indexOf(currentCover);
        if (foundIndex >= 0) {
          initialIndex = foundIndex;
        }
      }
      final controller = PageController(initialPage: initialIndex);
      _pageController?.dispose();
      setState(() {
        _images = images;
        _currentCoverPath = currentCover;
        _currentIndex = initialIndex;
        _pageController = controller;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _handlePageChanged(int index) {
    if (index < 0 || index >= _images.length) return;
    setState(() {
      _currentIndex = index;
    });
  }

  Future<void> _commitSelection() async {
    final index = _currentIndex;
    if (!mounted || index < 0 || index >= _images.length) return;
    setState(() {
      _saving = true;
    });
    try {
      final storedCoverPath = await ref
          .read(libraryFacadeProvider)
          .setFolderManualCover(widget.folderPath, _images[index]);
      if (!mounted) return;
      setState(() {
        _currentCoverPath = _images[index];
      });
      widget.onCoverSelected?.call(storedCoverPath ?? _images[index]);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        ProviderScope.containerOf(context, listen: false)
            .read(appLanguageProviderInstanceProvider)
            .tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _buildCoverReveal(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      reverseDuration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    if (_loading) {
      return _buildCoverReveal(
        Column(
          key: const ValueKey('audio_detail_cover_loading'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
            const SizedBox(height: 10),
            Card(
              key: const ValueKey('audio_detail_cover_placeholder'),
              margin: EdgeInsets.zero,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: const AspectRatio(
                aspectRatio: 1.45,
                child: SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
    }
    if (_error != null || _images.isEmpty || _pageController == null) {
      return const SizedBox.shrink();
    }
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(coverImageResolutionProvider),
    );

    final content = Column(
      key: const ValueKey('audio_detail_cover_loaded'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
        const SizedBox(height: 10),
        ClipRRect(
          key: const ValueKey('audio_detail_cover_content'),
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 1.45,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _images.length,
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (context, index) {
                      return RetryingFileImage(
                        path: _images[index],
                        fit: BoxFit.cover,
                        cacheWidth: coverCacheWidth,
                        useDefaultCacheWidth: coverCacheWidth != null,
                        fallbackBuilder: (_) => CoverFallbackArtwork(
                          seed: _images[index],
                          icon: Icons.image_not_supported_rounded,
                          iconSize: 42,
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: _saving ? 1 : 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            '${_currentIndex + 1} / ${_images.length}',
                            style: const TextStyle(
                              color: Color(0xFFF8F5F7),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            i18n.tr('audio_detail_cover_swipe_hint'),
                            style: const TextStyle(
                              color: Color(0xFFF8F5F7),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: _currentCoverPath == _images[_currentIndex]
              ? TextButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.check_circle_rounded),
                  label: Text(i18n.tr('audio_detail_current_cover')),
                )
              : FilledButton.tonalIcon(
                  onPressed: _saving ? null : _commitSelection,
                  icon: const Icon(Icons.image_rounded),
                  label: Text(i18n.tr('audio_detail_set_cover')),
                ),
        ),
      ],
    );
    return _buildCoverReveal(content);
  }
}
