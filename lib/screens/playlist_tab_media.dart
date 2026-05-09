part of 'playlist_tab.dart';

class _SessionHeroArtwork extends ConsumerStatefulWidget {
  const _SessionHeroArtwork({
    required this.height,
    required this.coverPathFuture,
    required this.title,
    required this.folderName,
    required this.isPlaying,
    required this.trackPath,
  });

  final double height;
  final Future<String?> coverPathFuture;
  final String title;
  final String folderName;
  final bool isPlaying;
  final String trackPath;

  @override
  ConsumerState<_SessionHeroArtwork> createState() => _SessionHeroArtworkState();
}

class _SessionHeroArtworkState extends ConsumerState<_SessionHeroArtwork> {
  bool _isSelecting = false;
  List<String> _candidateImages = [];
  int _currentIndex = -1;
  int _selectionStartIndex = 0;
  double _startX = 0;
  bool _isLoadingImages = false;

  Future<void> _startSelection(Offset localPosition) async {
    setState(() {
      _isLoadingImages = true;
      _isSelecting = true;
      _startX = localPosition.dx;
    });

    unawaited(HapticFeedback.heavyImpact());

    // Resolve current cover path in parallel with discovering images
    final currentCoverPath = await widget.coverPathFuture;
    final images = await ref
        .read(audioProviderFacadeProvider)
        .discoverImagesInRoot(widget.trackPath);

    if (!mounted) return;

    // Find current cover in the candidate list to pre-select it
    int startIdx = 0;
    if (currentCoverPath != null && images.isNotEmpty) {
      final found = images.indexOf(currentCoverPath);
      if (found >= 0) startIdx = found;
    }

    setState(() {
      _candidateImages = images;
      _isLoadingImages = false;
      if (images.isNotEmpty) {
        _currentIndex = startIdx;
        _selectionStartIndex = startIdx;
      }
    });
  }

  void _updateSelection(Offset localPosition) {
    if (_candidateImages.isEmpty) return;

    final deltaX = localPosition.dx - _startX;
    const pixelsPerImage = 60.0;
    final indexOffset = (deltaX / pixelsPerImage).round();

    int nextIndex =
        (_selectionStartIndex + indexOffset) % _candidateImages.length;
    if (nextIndex < 0) nextIndex += _candidateImages.length;

    if (nextIndex != _currentIndex) {
      setState(() {
        _currentIndex = nextIndex;
      });
      unawaited(HapticFeedback.selectionClick());
    }
  }

  Future<void> _confirmSelection() async {
    final provider = ref.read(audioProviderFacadeProvider);
    if (_currentIndex >= 0 && _currentIndex < _candidateImages.length) {
      await provider.setTrackManualCover(
        widget.trackPath,
        _candidateImages[_currentIndex],
      );
    }

    if (!mounted) return;
    setState(() {
      _isSelecting = false;
      _candidateImages = [];
      _currentIndex = -1;
    });

    unawaited(HapticFeedback.mediumImpact());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.tertiaryContainer.withValues(alpha: 0.9),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 56,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth;
        final cacheW = (displayWidth * dpr).round();

        return GestureDetector(
          onLongPressStart: (details) => _startSelection(details.localPosition),
          onLongPressMoveUpdate: (details) => _updateSelection(details.localPosition),
          onLongPressEnd: (_) => _confirmSelection(),
          onLongPressCancel: () {
            setState(() {
              _isSelecting = false;
              _candidateImages = [];
              _currentIndex = -1;
            });
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.height),
            child: Container(
              width: displayWidth,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Main Artwork
                    AsyncCoverImage(
                      future: widget.coverPathFuture,
                      fallbackBuilder: (_) => fallback(),
                      loadingBuilder: (_) => Stack(
                        fit: StackFit.expand,
                        children: [
                          fallback(),
                          Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: cs.onPrimaryContainer.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                      imageBuilder: (context, coverPath) {
                        return RepaintBoundary(
                          child: Image(
                            image: resizeFileImageIfNeeded(
                              path: coverPath,
                              cacheWidth: cacheW,
                            ),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => fallback(),
                          ),
                        );
                      },
                    ),
                    
                    // Selection Overlay
                    if (_isSelecting)
                      Positioned.fill(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                                  CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                                ),
                                child: child,
                              ),
                            );
                          },
                          child: _isLoadingImages 
                            ? Container(
                                key: const ValueKey('loading'),
                                color: Colors.black54,
                                child: const Center(child: CircularProgressIndicator()),
                              )
                            : Container(
                                key: ValueKey(_currentIndex),
                                color: Colors.black87,
                                child: _currentIndex >= 0 && _currentIndex < _candidateImages.length
                                  ? Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.file(
                                          File(_candidateImages[_currentIndex]),
                                          fit: BoxFit.contain,
                                        ),
                                        Positioned(
                                          bottom: 16,
                                          left: 0,
                                          right: 0,
                                          child: Center(
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: Colors.black54,
                                                borderRadius: BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                '${_currentIndex + 1} / ${_candidateImages.length}',
                                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : const Center(child: Icon(Icons.image_not_supported_rounded, color: Colors.white54, size: 48)),
                              ),
                        ),
                      ),

                    // Standard Gradient Overlay
                    if (!_isSelecting)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.1),
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.2),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionCoverThumbnail extends StatelessWidget {
  const _SessionCoverThumbnail({
    required this.coverPathFuture,
    required this.title,
  });

  final Future<String?> coverPathFuture;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.secondaryContainer.withValues(alpha: 0.92),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 26,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return SizedBox(
      width: 96,
      height: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AsyncCoverImage(
          future: coverPathFuture,
          fallbackBuilder: (_) => fallback(),
          loadingBuilder: (_) => Stack(
            fit: StackFit.expand,
            children: [
              fallback(),
              Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onPrimaryContainer.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ],
          ),
          imageBuilder: (context, coverPath) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            return Image(
              image: resizeFileImageIfNeeded(
                path: coverPath,
                cacheWidth: (96 * dpr).round(),
              ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fallback(),
            );
          },
        ),
      ),
    );
  }
}

class _SessionMetaChip extends StatelessWidget {
  const _SessionMetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Icon(
            icon,
            size: 11,
            color: cs.onSurfaceVariant.withValues(alpha: 0.65),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitcherSlot extends StatelessWidget {
  const _SwitcherSlot({
    required this.child,
    required this.width,
    required this.height,
    this.duration = const Duration(milliseconds: 150),
  });

  final Widget child;
  final double width;
  final double height;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return SizedBox(
          width: width,
          height: height,
          child: Center(
            child:
                currentChild ??
                (previousChildren.isNotEmpty
                    ? previousChildren.last
                    : const SizedBox.shrink()),
          ),
        );
      },
      transitionBuilder: (child, animation) {
        final opacity = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: opacity,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1).animate(opacity),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _LoopModeButton extends StatelessWidget {
  const _LoopModeButton({
    this.icon,
    this.iconWidget,
    required this.onPressed,
    this.active = false,
  }) : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final child =
        iconWidget ??
        Icon(
          icon,
          key: ValueKey<IconData?>(icon),
          size: 18,
          color: active ? cs.primary : cs.onSurfaceVariant,
        );
    return IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        maximumSize: const Size(40, 40),
        backgroundColor: active
            ? cs.primaryContainer.withValues(alpha: 0.94)
            : cs.surfaceContainerHighest.withValues(alpha: 0.72),
        side: BorderSide(
          color: active
              ? cs.primary.withValues(alpha: 0.45)
              : cs.outlineVariant.withValues(alpha: 0.9),
        ),
      ),
      icon: _SwitcherSlot(
        width: 18,
        height: 18,
        duration: const Duration(milliseconds: 140),
        child: child,
      ),
    );
  }
}
