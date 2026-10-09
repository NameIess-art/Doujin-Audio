import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_feedback.dart';
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

class _WorkImageViewerPageState extends ConsumerState<WorkImageViewerPage> {
  static const int _loopPageSeed = 100000;
  static const double _imageHeaderGap = 24;
  static const double _imageSwitcherGap = 20;
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _switcherKey = GlobalKey();
  double _headerHeight = 0;
  double _switcherHeight = 0;
  late int _currentIndex;
  late final PageController _pageController;
  int? _targetVirtualPage;
  bool _isSettingCover = false;
  bool _isCurrentZoomed = false;

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
    final count = widget.images.length;
    _currentIndex = widget.initialIndex.clamp(
      0,
      count == 0 ? 0 : count - 1,
    );
    final initialPage = _pageForIndex(_currentIndex, count);
    _targetVirtualPage = initialPage;
    _pageController = PageController(initialPage: initialPage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    final count = widget.images.length;
    if (count == 0) return;
    _targetVirtualPage = page;
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
    final current = _pageController.page ??
        _pageForIndex(_currentIndex, widget.images.length).toDouble();
    int basePage;
    if (_targetVirtualPage != null &&
        (current - _targetVirtualPage!).abs() <= 1.0) {
      basePage = _targetVirtualPage!;
    } else {
      basePage = current.round();
    }
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
      path: imagePath,
      fit: BoxFit.contain,
      useDefaultCacheWidth: false,
      loadingBuilder: loadingIndicator,
      fallbackBuilder: loadingIndicator,
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (widget.images.isEmpty) {
      return Scaffold(
        backgroundColor: appPageBackgroundColor(context, cs.surface),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AppPageHeaderTransition(
            child: AppBar(
              backgroundColor: cs.surface,
              foregroundColor: cs.onSurface,
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
            : MediaQuery.paddingOf(context).top + 96) +
        _imageHeaderGap;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final switcherHeight = _switcherHeight > 0 ? _switcherHeight : 38.0;
    final imageBottom = widget.images.length > 1
        ? bottomInset + 20.0 + switcherHeight + _imageSwitcherGap
        : bottomInset + 20.0;

    return Scaffold(
      backgroundColor: appPageBackgroundColor(context, cs.surface),
      body: Stack(
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
                child: PageView.builder(
                  key: const ValueKey<String>('work_image_viewport'),
                  controller: _pageController,
                  physics: _isCurrentZoomed
                      ? const NeverScrollableScrollPhysics()
                      : (widget.images.length > 1
                          ? const PageScrollPhysics()
                          : const NeverScrollableScrollPhysics()),
                  onPageChanged: _onPageChanged,
                  itemCount:
                      widget.images.length > 1 ? null : widget.images.length,
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
                onPressed: () => Navigator.of(context).maybePop(),
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
        panEnabled: _isZoomed,
        minScale: 1.0,
        maxScale: 4.0,
        child: SizedBox.expand(child: widget.child),
      ),
    );
  }
}
