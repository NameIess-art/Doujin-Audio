import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_buttons.dart';
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
    this.sourcePath,
  });

  final String name;
  final String path;
  final String relativePath;
  final String? sourcePath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkImageItem &&
          name == other.name &&
          path == other.path &&
          relativePath == other.relativePath &&
          sourcePath == other.sourcePath;

  @override
  int get hashCode => Object.hash(name, path, relativePath, sourcePath);
}

class WorkImageViewerPage extends ConsumerStatefulWidget {
  const WorkImageViewerPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.currentCoverPath,
    this.onSetAsCover,
  });

  final List<WorkImageItem> images;
  final int initialIndex;
  final String? currentCoverPath;
  final Future<void> Function(WorkImageItem image)? onSetAsCover;

  @override
  ConsumerState<WorkImageViewerPage> createState() =>
      _WorkImageViewerPageState();
}

class _WorkImageViewerPageState extends ConsumerState<WorkImageViewerPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const int _loopPageSeed = 100000;
  static const double _imageSwitcherGap = 20;
  static const double _dismissThreshold = 110;
  static const double _dismissVelocity = 700;
  final Object _dragDismissInteraction = Object();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _switcherKey = GlobalKey();
  final GlobalKey _viewerKey = GlobalKey();
  final OverlayPortalController _fullscreenController =
      OverlayPortalController();
  double _headerHeight = 0;
  double _switcherHeight = 0;
  bool _layoutMeasurementScheduled = false;
  Object? _lastLayoutMeasurementKey;
  late int _currentIndex;
  late int _currentPage;
  late final PageController _pageController;
  int? _targetVirtualPage;
  String? _selectedCoverPath;
  bool _isSettingCover = false;
  final ValueNotifier<bool> _isCurrentZoomed = ValueNotifier<bool>(false);
  late final AnimationController _fullscreenFade;
  late final CurvedAnimation _viewerOpacity;
  late final AnimationController _chromeController;
  late final CurvedAnimation _chromeOpacity;
  late final AnimationController _dragResetController;
  Animation<double>? _dragResetAnimation;
  final ValueNotifier<double> _dragOffset = ValueNotifier<double>(0);
  final ValueNotifier<bool> _isDraggingDismiss = ValueNotifier<bool>(false);
  final ValueNotifier<double> _effectiveChromeOpacity = ValueNotifier<double>(
    1.0,
  );
  late final Animation<double> _effectiveChromeOpacityAnimation =
      Animation<double>.fromValueListenable(_effectiveChromeOpacity);
  final ValueNotifier<bool> _chromeInteractive = ValueNotifier<bool>(true);
  late final Listenable _chromeListenable;
  late final Listenable _pagerPhysicsListenable;
  bool _dismissThresholdReached = false;
  bool _chromeVisible = true;
  bool _isDismissing = false;
  bool _fullscreenTarget = false;
  bool _movingFullscreen = false;
  final Map<String, int> _localRetrySeeds = <String, int>{};
  DateTime _lastWheelTurnAt = DateTime.fromMillisecondsSinceEpoch(0);

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

  void _syncEffectiveChromeOpacity() {
    final visibleFraction = _chromeOpacity.value;
    final dragFraction = (_dragOffset.value.abs() / 260.0).clamp(0.0, 1.0);
    final dragChromeOpacity = (1.0 - dragFraction * 1.8).clamp(0.0, 1.0);
    final nextOpacity = (visibleFraction * dragChromeOpacity).clamp(0.0, 1.0);
    if (_effectiveChromeOpacity.value != nextOpacity) {
      _effectiveChromeOpacity.value = nextOpacity;
    }
    final nextInteractive = _chromeVisible && nextOpacity >= 0.05;
    if (_chromeInteractive.value != nextInteractive) {
      _chromeInteractive.value = nextInteractive;
    }
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
    _chromeController = AnimationController(
      vsync: this,
      duration: kAppMotionFast,
      value: 1,
    );
    _chromeOpacity = CurvedAnimation(
      parent: _chromeController,
      curve: kAppSpringCurve,
    );
    _chromeListenable = Listenable.merge([_chromeOpacity, _dragOffset])
      ..addListener(_syncEffectiveChromeOpacity);
    _pagerPhysicsListenable = Listenable.merge([
      _isCurrentZoomed,
      _isDraggingDismiss,
    ]);
    _dragResetController =
        AnimationController(vsync: this, duration: kAppMotionStandard)
          ..addListener(() {
            final animation = _dragResetAnimation;
            if (animation != null && mounted) {
              _dragOffset.value = animation.value;
            }
          });
    _dragOffset.addListener(() {
      final isDragging = _dragOffset.value != 0;
      if (_isDraggingDismiss.value != isDragging) {
        _isDraggingDismiss.value = isDragging;
      }
    });
    WidgetsBinding.instance.addObserver(this);
    final count = widget.images.length;
    _currentIndex = widget.initialIndex.clamp(0, count == 0 ? 0 : count - 1);
    _currentPage = _pageForIndex(_currentIndex, count);
    _pageController = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(covariant WorkImageViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.images, widget.images)) {
      final count = widget.images.length;
      _currentIndex = _currentIndex.clamp(0, count == 0 ? 0 : count - 1);
      _currentPage = _pageForIndex(_currentIndex, count);
      _targetVirtualPage = null;
      _isCurrentZoomed.value = false;
      if (_pageController.hasClients && count > 0) {
        _pageController.jumpToPage(_currentPage);
      }
    }
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(_dragDismissInteraction);
    WidgetsBinding.instance.removeObserver(this);
    _chromeListenable.removeListener(_syncEffectiveChromeOpacity);
    _pageController.dispose();
    _viewerOpacity.dispose();
    _chromeOpacity.dispose();
    _fullscreenFade.dispose();
    _chromeController.dispose();
    _dragResetController.dispose();
    _dragOffset.dispose();
    _isDraggingDismiss.dispose();
    _isCurrentZoomed.dispose();
    _effectiveChromeOpacity.dispose();
    _chromeInteractive.dispose();
    super.dispose();
  }

  void _toggleChrome() {
    if (_dragOffset.value != 0 || _isDismissing) return;
    _chromeVisible = !_chromeVisible;
    final duration =
        MediaQuery.disableAnimationsOf(context) ||
            !TickerMode.valuesOf(context).enabled
        ? Duration.zero
        : kAppMotionFast;
    _chromeController.duration = duration;
    if (_chromeVisible) {
      _chromeController.forward();
    } else {
      _chromeController.reverse();
    }
    _syncEffectiveChromeOpacity();
  }

  void _handleDragDismissStart(DragStartDetails details) {
    if (_isCurrentZoomed.value || _isDismissing) return;
    if (!Navigator.of(context).canPop()) return;
    _dragResetController.stop();
    UiInteractionCoordinator.instance.beginInteraction(_dragDismissInteraction);
  }

  void _handleDragDismissUpdate(DragUpdateDetails details) {
    if (_isCurrentZoomed.value || _isDismissing) return;
    if (!Navigator.of(context).canPop()) return;
    final nextOffset = _dragOffset.value + details.delta.dy;
    final crossed = nextOffset.abs() >= _dismissThreshold;
    if (crossed != _dismissThresholdReached) {
      _dismissThresholdReached = crossed;
      if (crossed) {
        unawaited(
          AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
        );
      }
    }
    _dragOffset.value = nextOffset;
  }

  void _handleDragDismissEnd(DragEndDetails details) {
    UiInteractionCoordinator.instance.endInteraction(_dragDismissInteraction);
    if (_isCurrentZoomed.value || _isDismissing) {
      _animateDragBack();
      return;
    }
    final velocity = details.velocity.pixelsPerSecond.dy;
    final offset = _dragOffset.value;
    final shouldDismiss =
        offset.abs() >= _dismissThreshold ||
        (velocity.abs() >= _dismissVelocity &&
            (offset == 0 || velocity.sign == offset.sign));
    if (shouldDismiss && Navigator.of(context).canPop()) {
      if (_fullscreenController.isShowing) {
        _fullscreenTarget = false;
        unawaited(_moveFullscreen());
        _animateDragBack();
        return;
      }
      _isDismissing = true;
      if (!MediaQuery.disableAnimationsOf(context) &&
          TickerMode.valuesOf(context).enabled) {
        final direction = offset != 0
            ? offset.sign
            : (velocity == 0 ? 1.0 : velocity.sign);
        final travel = MediaQuery.sizeOf(context).height * 0.45;
        final targetOffset = direction * math.max(offset.abs() + 120.0, travel);
        const dismissDuration = Duration(milliseconds: 160);
        _dragResetAnimation = Tween<double>(
          begin: offset,
          end: targetOffset,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_dragResetController);
        _dragResetController.duration = dismissDuration;
        _fullscreenFade.duration = dismissDuration;
        // Finish the vertical fly-off and fade to transparent before popping so
        // the route's horizontal pop transition does not visibly conflict.
        unawaited(
          Future.wait<void>([
            _dragResetController.forward(from: 0).orCancel,
            _fullscreenFade.reverse().orCancel,
          ]).then(
            (_) async {
              if (!mounted) return;
              final popped = await Navigator.of(context).maybePop();
              if (!popped && mounted) {
                _isDismissing = false;
                _fullscreenFade.value = 1;
                _animateDragBack();
              }
            },
            onError: (_) {},
          ),
        );
        return;
      }
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    _animateDragBack();
  }

  void _handleDragDismissCancel() {
    UiInteractionCoordinator.instance.endInteraction(_dragDismissInteraction);
    _animateDragBack();
  }

  void _animateDragBack() {
    _dismissThresholdReached = false;
    final start = _dragOffset.value;
    if (start == 0) return;
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _dragOffset.value = 0;
      return;
    }
    _dragResetAnimation = Tween<double>(
      begin: start,
      end: 0,
    ).chain(CurveTween(curve: kAppSpringCurve)).animate(_dragResetController);
    _dragResetController.duration = kAppMotionStandard;
    _dragResetController.forward(from: 0);
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
    _isCurrentZoomed.value = false;
    if (_currentPage != page || _currentIndex != index) {
      setState(() {
        _currentPage = page;
        _currentIndex = index;
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
    _isCurrentZoomed.value = false;
    setState(() {
      _currentPage = targetPage;
      _currentIndex = _indexForPage(targetPage, widget.images.length);
    });
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppMotionStandard;
    if (duration == Duration.zero) {
      _pageController.jumpToPage(targetPage);
    } else {
      _pageController.animateToPage(
        targetPage,
        duration: duration,
        curve: kAppSpringCurve,
      );
    }
  }

  bool _handlePageScroll(ScrollNotification notification) {
    if (notification.depth != 0 || !_pageController.hasClients) return false;
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        notification is ScrollEndNotification) {
      final page = _pageController.page;
      if (page == null) return false;
      _targetVirtualPage = null;
      _onPageChanged(page.round());
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
      _selectedCoverPath = currentImage.sourcePath ?? currentImage.path;
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

  void _handleEscapeShortcut() {
    if (_fullscreenController.isShowing || _fullscreenTarget) {
      _fullscreenTarget = false;
      unawaited(_moveFullscreen());
      return;
    }
    unawaited(Navigator.of(context).maybePop());
  }

  void _handleFullscreenShortcut() {
    if (View.of(context).physicalSize.aspectRatio <= 1) return;
    _toggleFullscreen();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        event is! PointerScrollEvent ||
        _isCurrentZoomed.value ||
        widget.images.length <= 1) {
      return;
    }
    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!mounted || _isCurrentZoomed.value || widget.images.length <= 1) {
        return;
      }
      final now = DateTime.now();
      if (now.difference(_lastWheelTurnAt) <
          const Duration(milliseconds: 160)) {
        return;
      }
      _lastWheelTurnAt = now;
      if (delta > 0) {
        _goToNext();
      } else {
        _goToPrevious();
      }
    });
  }

  Widget _buildImage(
    WorkImageItem image,
    ColorScheme cs, {
    required int maxCacheWidth,
  }) {
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
      return _RemoteWorkImage(
        url: imagePath,
        maxCacheWidth: maxCacheWidth,
        loadingBuilder: loadingIndicator,
      );
    }
    final retrySeed = _localRetrySeeds[imagePath] ?? 0;
    return RetryingFileImage(
      key: ValueKey<String>('local_work_image_${imagePath}_$retrySeed'),
      deferLoadDuringInteraction: true,
      retainInImageCache: false,
      path: imagePath,
      fit: BoxFit.contain,
      cacheWidth: maxCacheWidth,
      useDefaultCacheWidth: false,
      loadingBuilder: loadingIndicator,
      fallbackBuilder: (context) => _ImageLoadErrorView(
        onRetry: () {
          setState(() {
            _localRetrySeeds[imagePath] = retrySeed + 1;
          });
        },
      ),
    );
  }

  void _scheduleLayoutMeasurement(Object layoutKey) {
    final hasMeasured =
        _headerHeight > 0 &&
        (widget.images.length <= 1 || _switcherHeight > 0);
    if (hasMeasured && _lastLayoutMeasurementKey == layoutKey) return;
    _lastLayoutMeasurementKey = layoutKey;
    if (_layoutMeasurementScheduled) return;
    _layoutMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutMeasurementScheduled = false;
      if (!mounted) return;
      var updatedHeaderHeight = _headerHeight;
      var updatedSwitcherHeight = _switcherHeight;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final height = box.size.height;
        if (height > 0 &&
            (_headerHeight == 0 || (height - _headerHeight).abs() > 0.5)) {
          updatedHeaderHeight = height;
        }
      }
      final switcherBox =
          _switcherKey.currentContext?.findRenderObject() as RenderBox?;
      if (switcherBox != null) {
        final height = switcherBox.size.height;
        if (height > 0 &&
            (_switcherHeight == 0 || (height - _switcherHeight).abs() > 0.5)) {
          updatedSwitcherHeight = height;
        }
      }
      if (updatedHeaderHeight != _headerHeight ||
          updatedSwitcherHeight != _switcherHeight) {
        setState(() {
          _headerHeight = updatedHeaderHeight;
          _switcherHeight = updatedSwitcherHeight;
        });
      }
    });
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
            : kAppMotionStandard;
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
        body: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: Center(
                  child: Text(
                    i18n.tr('no_images'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: const ValueKey<String>('work_image_header'),
                icon: AppDesignTokens.imageFileIcon,
                iconColor: AppDesignTokens.of(context).imageFileColor,
                title: i18n.tr('no_images'),
                leading: const AppHeaderBackButton(),
              ),
            ),
          ],
        ),
      );
    }

    final currentImage = widget.images[_currentIndex];
    final coverPath = _selectedCoverPath ?? widget.currentCoverPath;
    final isCurrentCover =
        coverPath != null &&
        (PathMatcher.equalsNormalized(
              currentImage.sourcePath ?? currentImage.path,
              coverPath,
            ) ||
            PathMatcher.equalsNormalized(currentImage.path, coverPath));
    final mediaSize = MediaQuery.sizeOf(context);
    final mediaPadding = MediaQuery.paddingOf(context);
    _scheduleLayoutMeasurement((
      widget.images.length > 1,
      widget.onSetAsCover != null,
      mediaSize.width,
      mediaPadding.top,
      mediaPadding.bottom,
      MediaQuery.textScalerOf(context),
      i18n.language,
      _fullscreenController.isShowing,
    ));
    final imageTop =
        (_headerHeight > 0
            ? _headerHeight
            : AppPageHeaderMetrics.headerHeight(context)) +
        AppPageHeaderMetrics.firstContentSpacing;
    final bottomInset = mediaPadding.bottom;
    final switcherHeight = _switcherHeight > 0 ? _switcherHeight : 38.0;
    final imageBottom = widget.images.length > 1
        ? bottomInset + 20.0 + switcherHeight + _imageSwitcherGap
        : bottomInset + 20.0;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final maxCacheWidth = (mediaSize.longestSide * dpr * 1.5)
        .round()
        .clamp(1600, 2560);

    Widget wrapChrome(Widget child, {double slideOffsetY = 0}) {
      return ValueListenableBuilder<bool>(
        valueListenable: _chromeInteractive,
        child: FadeTransition(
          opacity: _effectiveChromeOpacityAnimation,
          child: AnimatedBuilder(
            animation: _chromeOpacity,
            child: child,
            builder: (context, inner) => Transform.translate(
              offset: Offset(0, slideOffsetY * (1.0 - _chromeOpacity.value)),
              child: inner,
            ),
          ),
        ),
        builder: (context, interactive, inner) =>
            IgnorePointer(ignoring: !interactive, child: inner),
      );
    }

    final pageContent = AppPageContentTransition(
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
          child: ListenableBuilder(
            listenable: _pagerPhysicsListenable,
            builder: (context, _) => PageView.builder(
              key: const ValueKey<String>('work_image_viewport'),
              clipBehavior: Clip.none,
              controller: _pageController,
              physics: _isCurrentZoomed.value || _isDraggingDismiss.value
                  ? const NeverScrollableScrollPhysics()
                  : (widget.images.length > 1
                        ? const PageScrollPhysics()
                        : const NeverScrollableScrollPhysics()),
              onPageChanged: _onPageChanged,
              itemCount: widget.images.length > 1 ? null : widget.images.length,
              itemBuilder: (context, page) {
                final index = _indexForPage(page, widget.images.length);
                final img = widget.images[index];
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: _handlePointerSignal,
                  child: _WorkImageViewerItem(
                    key: ValueKey<String>('image_item_${img.path}_$page'),
                    isActive: widget.images.length > 1
                        ? page == _currentPage
                        : index == _currentIndex,
                    onToggleChrome: _toggleChrome,
                    onZoomChanged: (zoomed) => _isCurrentZoomed.value = zoomed,
                    child: _buildImage(
                      img,
                      cs,
                      maxCacheWidth: maxCacheWidth,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    final pagedViewer = ValueListenableBuilder<bool>(
      valueListenable: _isCurrentZoomed,
      child: pageContent,
      builder: (context, isZoomed, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: isZoomed ? null : _handleDragDismissStart,
        onVerticalDragUpdate: isZoomed ? null : _handleDragDismissUpdate,
        onVerticalDragEnd: isZoomed ? null : _handleDragDismissEnd,
        onVerticalDragCancel: isZoomed ? null : _handleDragDismissCancel,
        child: child,
      ),
    );

    final viewerScaffold = Scaffold(
      // Reparent this same subtree so paging and image zoom survive the toggle.
      key: _viewerKey,
      backgroundColor: Colors.transparent,
      body: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleChrome,
                child: ValueListenableBuilder<double>(
                  valueListenable: _dragOffset,
                  builder: (context, dragOffset, _) {
                    final dragFraction = (dragOffset.abs() / 260.0).clamp(
                      0.0,
                      1.0,
                    );
                    final backdropOpacity = (1.0 - 0.65 * dragFraction).clamp(
                      0.0,
                      1.0,
                    );
                    return ColoredBox(
                      color: cs.surface.withValues(alpha: backdropOpacity),
                    );
                  },
                ),
              ),
            ),
            // Keep the viewport bounds fixed across chrome toggles so hiding or
            // showing controls never relayouts the image or shifts zoomed offsets.
            Positioned.fill(
              top: imageTop,
              bottom: imageBottom,
              child: ValueListenableBuilder<double>(
                valueListenable: _dragOffset,
                child: pagedViewer,
                builder: (context, dragOffset, child) {
                  final dragFraction = (dragOffset.abs() / 260.0).clamp(
                    0.0,
                    1.0,
                  );
                  final viewportScale = 1.0 - 0.14 * dragFraction;
                  return Transform.translate(
                    offset: Offset(0, dragOffset),
                    child: Transform.scale(scale: viewportScale, child: child),
                  );
                },
              ),
            ),
            // Floating Top Page Header
            Positioned(
              key: _headerKey,
              top: 0,
              left: 0,
              right: 0,
              child: wrapChrome(
                slideOffsetY: -16,
                TopPageHeader(
                  key: const ValueKey<String>('work_image_header'),
                  icon: AppDesignTokens.imageFileIcon,
                  iconColor: AppDesignTokens.of(context).imageFileColor,
                  title: currentImage.name,
                  leading: const AppHeaderBackButton(),
                  trailing: widget.onSetAsCover != null
                      ? IconButton(
                          key: const ValueKey<String>(
                            'viewer_set_as_cover_button',
                          ),
                          tooltip: i18n.tr(
                            isCurrentCover
                                ? 'audio_detail_current_cover'
                                : 'audio_detail_set_cover',
                          ),
                          onPressed: _isSettingCover || isCurrentCover
                              ? null
                              : _handleSetAsCover,
                          style: IconButton.styleFrom(
                            disabledForegroundColor: cs.onSurface,
                          ),
                          icon: isCurrentCover
                              ? SizedBox.square(
                                  dimension: 20,
                                  child: Stack(
                                    children: [
                                      const Icon(
                                        Icons.photo_size_select_actual_outlined,
                                      ),
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: cs.surface,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.check_circle_rounded,
                                            size: 11,
                                            color: cs.primary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : _isSettingCover
                              ? SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: cs.primary,
                                  ),
                                )
                              : const Icon(
                                  Icons.photo_size_select_actual_outlined,
                                ),
                        )
                      : null,
                ),
              ),
            ),
            if (View.of(context).physicalSize.aspectRatio > 1)
              Positioned(
                left: MediaQuery.paddingOf(context).left + 16,
                bottom: bottomInset + 20,
                child: wrapChrome(
                  slideOffsetY: 16,
                  AppPageContentTransition(
                    child: HeaderFloatingButton(
                      followBarGlass: true,
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
              ),
            // Bottom-right switcher capsule
            if (widget.images.length > 1)
              Positioned(
                key: _switcherKey,
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 20,
                child: wrapChrome(
                  slideOffsetY: 16,
                  AppPageContentTransition(
                    child: HeaderFloatingSurface(
                      followBarGlass: true,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: const ValueKey<String>(
                              'image_viewer_prev_button',
                            ),
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
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey<String>(
                              'image_viewer_next_button',
                            ),
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
              ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _goToPrevious,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _goToNext,
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscapeShortcut,
        const SingleActivator(LogicalKeyboardKey.keyF):
            _handleFullscreenShortcut,
        const SingleActivator(LogicalKeyboardKey.f11):
            _handleFullscreenShortcut,
      },
      child: Focus(autofocus: true, child: viewerScaffold),
    );
  }
}

class _ImageLoadErrorView extends ConsumerWidget {
  const _ImageLoadErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      key: const ValueKey<String>('work_image_load_error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              i18n.tr('image_load_failed'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            AppPillButton(
              key: const ValueKey<String>('image_viewer_retry_button'),
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: cs.secondaryContainer,
                foregroundColor: cs.onSecondaryContainer,
              ),
              child: Text(i18n.tr('retry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteWorkImage extends ConsumerStatefulWidget {
  const _RemoteWorkImage({
    required this.url,
    required this.maxCacheWidth,
    required this.loadingBuilder,
  });

  final String url;
  final int maxCacheWidth;
  final WidgetBuilder loadingBuilder;

  @override
  ConsumerState<_RemoteWorkImage> createState() => _RemoteWorkImageState();
}

class _RemoteWorkImageState extends ConsumerState<_RemoteWorkImage> {
  Object? _requestKey;
  Future<String?>? _future;
  int _retryCount = 0;

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final (revision, resolved) = ref.watch(
      coverGenerationProvider.select(
        (_) => (
          library.coverArtworkCacheService.revisionForScope(widget.url),
          library.resolvedCoverPathForRemoteCover(widget.url),
        ),
      ),
    );
    Future<String?> loadImage() =>
        library.coverPathFutureForRemoteCover(widget.url);
    final requestKey = (widget.url, resolved, revision, _retryCount);
    if (_requestKey != requestKey) {
      _requestKey = requestKey;
      _future = resolved != null && _retryCount == 0
          ? SynchronousFuture<String?>(resolved)
          : loadImage();
    }
    return AsyncRemoteCoverImage(
      key: ValueKey<String>('remote_work_image_${widget.url}_$_retryCount'),
      deferLoadDuringInteraction: true,
      retainInImageCache: false,
      url: widget.url,
      future: _future!,
      initialPath: _retryCount == 0 ? resolved : null,
      retryFutureBuilder: loadImage,
      onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
      fit: BoxFit.contain,
      cacheWidth: widget.maxCacheWidth,
      useDefaultCacheWidth: false,
      loadingBuilder: widget.loadingBuilder,
      fallbackBuilder: (_) => _ImageLoadErrorView(
        onRetry: () {
          library.invalidateRemoteCover(widget.url);
          setState(() {
            _retryCount += 1;
          });
        },
      ),
    );
  }
}

class _WorkImageViewerItem extends StatefulWidget {
  const _WorkImageViewerItem({
    super.key,
    required this.isActive,
    required this.onToggleChrome,
    required this.onZoomChanged,
    required this.child,
  });

  final bool isActive;
  final VoidCallback onToggleChrome;
  final ValueChanged<bool> onZoomChanged;
  final Widget child;

  @override
  State<_WorkImageViewerItem> createState() => _WorkImageViewerItemState();
}

class _WorkImageViewerItemState extends State<_WorkImageViewerItem>
    with SingleTickerProviderStateMixin {
  late final TransformationController _controller = TransformationController();
  late final AnimationController _zoomController;
  Animation<Matrix4>? _zoomAnimation;
  TapDownDetails? _doubleTapDetails;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransformationChanged);
    _zoomController = AnimationController(
      vsync: this,
      duration: kAppMotionStandard,
    )..addListener(() {
        final anim = _zoomAnimation;
        if (anim != null) {
          _controller.value = anim.value;
        }
      });
  }

  @override
  void didUpdateWidget(covariant _WorkImageViewerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && oldWidget.isActive && _isZoomed) {
      _zoomController.stop();
      _controller.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _zoomController.dispose();
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
    final Matrix4 target;
    if (_isZoomed) {
      target = Matrix4.identity();
    } else {
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      final x = -position.dx * 1.5;
      final y = -position.dy * 1.5;
      target = Matrix4.identity()
        ..translateByDouble(x, y, 0, 1)
        ..scaleByDouble(2.5, 2.5, 1.0, 1);
    }
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _zoomController.stop();
      _controller.value = target;
      return;
    }
    _zoomAnimation = Matrix4Tween(
      begin: _controller.value.clone(),
      end: target,
    ).chain(CurveTween(curve: kAppSpringCurve)).animate(_zoomController);
    _zoomController.duration = kAppMotionStandard;
    _zoomController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onToggleChrome,
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        // Keep the initial fit between controls, but paint zoom beneath them.
        clipBehavior: Clip.none,
        panEnabled: _isZoomed,
        minScale: 1.0,
        maxScale: 4.0,
        onInteractionStart: (_) => _zoomController.stop(),
        child: SizedBox.expand(child: widget.child),
      ),
    );
  }
}
