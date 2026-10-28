import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_glass_surface.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import 'library_providers.dart';

@immutable
class WorkImageItem {
  const WorkImageItem({
    required this.name,
    required this.path,
    this.relativePath = '',
  });

  final String name;
  final String path;
  final String relativePath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkImageItem &&
          name == other.name &&
          path == other.path &&
          relativePath == other.relativePath;

  @override
  int get hashCode => Object.hash(name, path, relativePath);
}

class WorkImageViewerPage extends ConsumerStatefulWidget {
  const WorkImageViewerPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.onSetAsCover,
  });

  final List<WorkImageItem> images;
  final int initialIndex;
  final Future<void> Function(WorkImageItem image)? onSetAsCover;

  @override
  ConsumerState<WorkImageViewerPage> createState() =>
      _WorkImageViewerPageState();
}

class _WorkImageViewerPageState extends ConsumerState<WorkImageViewerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const int _loopPageSeed = 100000;
  static const double _imageSwitcherGap = 20;
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _switcherKey = GlobalKey();
  final GlobalKey _viewerKey = GlobalKey();
  final OverlayPortalController _fullscreenController =
      OverlayPortalController();
  double _headerHeight = 0;
  double _switcherHeight = 0;
  late int _currentIndex;
  late final PageController _pageController;
  int? _targetVirtualPage;
  bool _isSettingCover = false;
  bool _isCurrentZoomed = false;
  late final AnimationController _fullscreenFade;
  late final Animation<double> _viewerOpacity;
  bool _fullscreenTarget = false;
  bool _movingFullscreen = false;

  static int _pageForIndex(int index, int length) {
    if (length <= 1) return index;
    final base = (_loopPageSeed ~/ length) * length;
    return base + index;
  }

  static int _indexForPage(int page, int length) {
    if (length <= 1) return 0;
    final remainder = page % length;
    return remainder < 0 ? remainder + length : remainder;
  }

  @override
  void initState() {
    super.initState();
    _fullscreenFade = AnimationController(
      vsync: this,
      duration: kAppFadeDuration,
      value: 1,
    );
    _viewerOpacity = CurvedAnimation(
      parent: _fullscreenFade,
      curve: kAppFadeCurve,
    );
    WidgetsBinding.instance.addObserver(this);
    final count = widget.images.length;
    _currentIndex = widget.initialIndex.clamp(0, count == 0 ? 0 : count - 1);
    final initialPage = _pageForIndex(_currentIndex, count);
    _pageController = PageController(initialPage: initialPage);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _fullscreenFade.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final view = View.of(context);
    if (view.physicalSize.width <= view.physicalSize.height &&
        _fullscreenTarget) {
      _fullscreenTarget = false;
      unawaited(_moveFullscreen());
    }
  }

  void _onPageChanged(int page) {
    final count = widget.images.length;
    if (count == 0) return;
    // Intermediate pages must not replace the target of rapid button presses.
    if (_targetVirtualPage != null && page != _targetVirtualPage) return;
    final index = _indexForPage(page, count);
    if (_currentIndex != index || _isCurrentZoomed) {
      setState(() {
        _currentIndex = index;
        _isCurrentZoomed = false;
      });
    }
  }

  void _goToPrevious() => _goToDelta(-1);

  void _goToNext() => _goToDelta(1);

  void _goToDelta(int delta) {
    if (widget.images.length <= 1) return;
    if (!_pageController.hasClients) return;
    final current =
        _pageController.page ??
        _pageForIndex(_currentIndex, widget.images.length).toDouble();
    final basePage = _targetVirtualPage ?? current.round();
    final targetPage = basePage + delta;
    _targetVirtualPage = targetPage;
    setState(() {
      _currentIndex = _indexForPage(targetPage, widget.images.length);
      _isCurrentZoomed = false;
    });
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppMotionSlow;
    if (duration == Duration.zero) {
      _pageController.jumpToPage(targetPage);
    } else {
      _pageController.animateToPage(
        targetPage,
        duration: duration,
        curve: Curves.easeInOutCubic,
      );
    }
  }

  bool _handlePageScroll(ScrollNotification notification) {
    if (notification.depth != 0 || !_pageController.hasClients) return false;
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        notification is ScrollEndNotification) {
      _targetVirtualPage = null;
      _onPageChanged(_pageController.page!.round());
    }
    return false;
  }

  Future<void> _handleSetAsCover() async {
    final onSetAsCover = widget.onSetAsCover;
    if (onSetAsCover == null || _isSettingCover) return;
    final currentImage = widget.images[_currentIndex];
    setState(() {
      _isSettingCover = true;
    });
    try {
      await onSetAsCover(currentImage);
      if (!mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_cover_saved'),
        tone: AppFeedbackTone.success,
      );
    } catch (_) {
      if (!mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSettingCover = false;
        });
      }
    }
  }

  Widget _buildImage(WorkImageItem image, ColorScheme cs) {
    final imagePath = image.path.trim();
    final isRemoteImage =
        imagePath.startsWith('http://') || imagePath.startsWith('https://');
    Widget loadingIndicator(BuildContext _) => Center(
      child: SizedBox.square(
        dimension: 32,
        child: CircularProgressIndicator(color: cs.primary, strokeWidth: 2.5),
      ),
    );
    if (isRemoteImage) {
      return Consumer(
        builder: (context, ref, _) {
          final library = ref.read(libraryFacadeProvider);
          ref.watch(
            coverGenerationProvider.select(
              (_) =>
                  library.coverArtworkCacheService.revisionForScope(imagePath),
            ),
          );
          final coverUi = ref.read(libraryCoverUiControllerProvider);
          final resolved = library.resolvedCoverPathForRemoteCover(imagePath);
          Future<String?> loadImage() =>
              coverUi.deferredRemoteCover(imagePath, context: context);
          return AsyncRemoteCoverImage(
            deferLoadDuringInteraction: true,
            url: imagePath,
            future: resolved != null ? Future.value(resolved) : loadImage(),
            initialPath: resolved,
            retryFutureBuilder: loadImage,
            onImageError:
                library.coverArtworkCacheService.reportArtworkReadFailure,
            fit: BoxFit.contain,
            useDefaultCacheWidth: false,
            loadingBuilder: loadingIndicator,
            fallbackBuilder: loadingIndicator,
          );
        },
      );
    }
    return RetryingFileImage(
      deferLoadDuringInteraction: true,
      path: imagePath,
      fit: BoxFit.contain,
      useDefaultCacheWidth: false,
      loadingBuilder: loadingIndicator,
      fallbackBuilder: loadingIndicator,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final windowMediaQuery = MediaQueryData.fromView(
      View.of(context),
      platformData: MediaQuery.of(context),
    );
    return PopScope<void>(
      canPop: !_fullscreenController.isShowing && !_movingFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _fullscreenTarget = false;
          unawaited(_moveFullscreen());
        }
      },
      child: OverlayPortal(
        controller: _fullscreenController,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: (context) => Positioned.fill(
          child: MediaQuery(data: windowMediaQuery, child: _fadingViewer()),
        ),
        child: _fullscreenController.isShowing
            ? const SizedBox.expand()
            : _fadingViewer(),
      ),
    );
  }

  void _toggleFullscreen() {
    _fullscreenTarget = !_fullscreenTarget;
    unawaited(_moveFullscreen());
  }

  Widget _fadingViewer() => FadeTransition(
    key: const ValueKey('work_image_fullscreen_fade'),
    opacity: _viewerOpacity,
    child: Builder(builder: _buildViewer),
  );

  Future<void> _moveFullscreen() async {
    if (_movingFullscreen) {
      if (_fullscreenTarget == _fullscreenController.isShowing) {
        unawaited(_fullscreenFade.forward());
      } else {
        unawaited(_fullscreenFade.reverse());
      }
      return;
    }
    setState(() => _movingFullscreen = true);
    try {
      while (true) {
        if (!mounted) return;
        _fullscreenFade.duration = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppFadeDuration;
        try {
          if (_fullscreenTarget == _fullscreenController.isShowing) {
            await _fullscreenFade.forward().orCancel;
            if (_fullscreenTarget == _fullscreenController.isShowing) break;
          } else {
            await _fullscreenFade.reverse().orCancel;
            if (!mounted) return;
            if (_fullscreenTarget == _fullscreenController.isShowing) continue;
            // Move the one viewer only when invisible, retaining its GlobalKey
            // and PageController instead of mounting a second zoom subtree.
            setState(() {
              if (_fullscreenTarget) {
                _fullscreenController.show();
              } else {
                _fullscreenController.hide();
              }
            });
          }
        } on TickerCanceled {
          // A new target reverses the same fade from its current opacity.
          // Disposal also cancels this await; mounted ends the loop then.
        }
      }
    } finally {
      if (mounted) setState(() => _movingFullscreen = false);
    }
  }

  Widget _buildViewer(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (widget.images.isEmpty) {
      return Scaffold(
        key: _viewerKey,
        backgroundColor: cs.surface,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AppPageHeaderTransition(
            child: AppGlassSurface(
              backgroundColor: cs.surface,
              child: AppBar(
                backgroundColor: Colors.transparent,
                foregroundColor: cs.onSurface,
                elevation: 0,
                scrolledUnderElevation: 0,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                forceMaterialTransparency: true,
              ),
            ),
          ),
        ),
        body: AppPageContentTransition(
          child: Center(
            child: Text(
              i18n.tr('no_images'),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    final currentImage = widget.images[_currentIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final height = box.size.height;
        if (height > 0 &&
            (_headerHeight == 0 || (height - _headerHeight).abs() > 0.5)) {
          setState(() => _headerHeight = height);
        }
      }
      final switcherBox =
          _switcherKey.currentContext?.findRenderObject() as RenderBox?;
      if (switcherBox != null) {
        final height = switcherBox.size.height;
        if (height > 0 &&
            (_switcherHeight == 0 || (height - _switcherHeight).abs() > 0.5)) {
          setState(() => _switcherHeight = height);
        }
      }
    });
    final imageTop =
        (_headerHeight > 0
            ? _headerHeight
            : AppPageHeaderMetrics.headerHeight(context)) +
        AppPageHeaderMetrics.firstContentSpacing;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final switcherHeight = _switcherHeight > 0 ? _switcherHeight : 38.0;
    final imageBottom = widget.images.length > 1
        ? bottomInset + 20.0 + switcherHeight + _imageSwitcherGap
        : bottomInset + 20.0;

    return Scaffold(
      // Reparent this same subtree so paging and image zoom survive the toggle.
      key: _viewerKey,
      backgroundColor: cs.surface,
      body: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              top: imageTop,
              bottom: imageBottom,
              child: AppPageContentTransition(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                    },
                  ),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handlePageScroll,
                    child: PageView.builder(
                      key: const ValueKey<String>('work_image_viewport'),
                      clipBehavior: Clip.none,
                      controller: _pageController,
                      physics: _isCurrentZoomed
                          ? const NeverScrollableScrollPhysics()
                          : (widget.images.length > 1
                                ? const PageScrollPhysics()
                                : const NeverScrollableScrollPhysics()),
                      onPageChanged: _onPageChanged,
                      itemCount: widget.images.length > 1
                          ? null
                          : widget.images.length,
                      itemBuilder: (context, page) {
                        final index = _indexForPage(page, widget.images.length);
                        final img = widget.images[index];
                        return _WorkImageViewerItem(
                          key: ValueKey<String>('image_item_${img.path}_$page'),
                          isActive: index == _currentIndex,
                          onZoomChanged: (zoomed) {
                            setState(() => _isCurrentZoomed = zoomed);
                          },
                          child: _buildImage(img, cs),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            // Floating Top Page Header
            Positioned(
              key: _headerKey,
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: const ValueKey<String>('work_image_header'),
                icon: AppDesignTokens.imageFileIcon,
                iconColor: AppDesignTokens.imageFileIconColor,
                title: currentImage.name,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(this.context).maybePop(),
                ),
                trailing: widget.onSetAsCover != null
                    ? HeaderFloatingSurface(
                        padding: EdgeInsets.zero,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            key: const ValueKey<String>(
                              'viewer_set_as_cover_button',
                            ),
                            borderRadius: BorderRadius.circular(19),
                            onTap: _isSettingCover ? null : _handleSetAsCover,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isSettingCover)
                                    const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else
                                    Icon(
                                      Icons.photo_size_select_actual_outlined,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                                  const SizedBox(width: 6),
                                  Text(
                                    ref
                                        .watch(
                                          appLanguageProviderInstanceProvider,
                                        )
                                        .tr('audio_detail_set_cover'),
                                    style: Theme.of(context).textTheme.labelMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            ),
            if (View.of(context).physicalSize.aspectRatio > 1)
              Positioned(
                left: MediaQuery.paddingOf(context).left + 16,
                bottom: bottomInset + 20,
                child: AppPageContentTransition(
                  child: HeaderFloatingButton(
                    child: IconButton(
                      key: const ValueKey('image_viewer_fullscreen_button'),
                      icon: Icon(
                        _fullscreenController.isShowing
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                      ),
                      tooltip: i18n.tr(
                        _fullscreenController.isShowing
                            ? 'exit_fullscreen'
                            : 'fullscreen',
                      ),
                      onPressed: _toggleFullscreen,
                    ),
                  ),
                ),
              ),
            // Bottom-right switcher capsule
            if (widget.images.length > 1)
              Positioned(
                key: _switcherKey,
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 20,
                child: AppPageContentTransition(
                  child: HeaderFloatingSurface(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey<String>('image_viewer_prev_button'),
                          iconSize: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          icon: const Icon(Icons.chevron_left_rounded),
                          tooltip: i18n.tr('previous'),
                          onPressed: _goToPrevious,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            '${_currentIndex + 1} / ${widget.images.length}',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  fontSize: 12.5,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey<String>('image_viewer_next_button'),
                          iconSize: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          icon: const Icon(Icons.chevron_right_rounded),
                          tooltip: i18n.tr('next'),
                          onPressed: _goToNext,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WorkImageViewerItem extends StatefulWidget {
  const _WorkImageViewerItem({
    super.key,
    required this.isActive,
    required this.onZoomChanged,
    required this.child,
  });

  final bool isActive;
  final ValueChanged<bool> onZoomChanged;
  final Widget child;

  @override
  State<_WorkImageViewerItem> createState() => _WorkImageViewerItemState();
}

class _WorkImageViewerItemState extends State<_WorkImageViewerItem> {
  late final TransformationController _controller = TransformationController();
  TapDownDetails? _doubleTapDetails;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransformationChanged);
  }

  @override
  void didUpdateWidget(covariant _WorkImageViewerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && oldWidget.isActive && _isZoomed) {
      _controller.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransformationChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTransformationChanged() {
    final scale = _controller.value.getMaxScaleOnAxis();
    final isZoomed = (scale - 1.0).abs() > 0.05;
    if (isZoomed != _isZoomed) {
      setState(() => _isZoomed = isZoomed);
      if (widget.isActive) {
        widget.onZoomChanged(isZoomed);
      }
    }
  }

  void _handleDoubleTap() {
    if (_isZoomed) {
      _controller.value = Matrix4.identity();
    } else {
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      final x = -position.dx * 1.5;
      final y = -position.dy * 1.5;
      _controller.value = Matrix4.identity()
        ..translateByDouble(x, y, 0, 1)
        ..scaleByDouble(2.5, 2.5, 1.0, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        // Keep the initial fit between controls, but paint zoom beneath them.
        clipBehavior: Clip.none,
        panEnabled: _isZoomed,
        minScale: 1.0,
        maxScale: 4.0,
        child: SizedBox.expand(child: widget.child),
      ),
    );
  }
}
