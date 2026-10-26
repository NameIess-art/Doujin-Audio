import 'package:flutter/material.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../localization/app_language_provider.dart';
import '../../features/player/application/playback_session_snapshot.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../features/player/presentation/playlist/session_detail_page.dart';

class MobileDockCapsuleContent extends StatefulWidget {
  const MobileDockCapsuleContent({
    super.key,
    required this.overlaySessions,
    required this.isPlaybackExpanded,
    required this.i18n,
    required this.mobilePlaybackGeometryKey,
    required this.onShowPlayback,
    required this.onShowDestinations,
    required this.onReportPlaybackCoverRect,
    required this.buildBottomBar,
  });

  final List<PlaybackSessionSnapshot> overlaySessions;
  final bool isPlaybackExpanded;
  final AppLanguageProvider i18n;
  final GlobalKey mobilePlaybackGeometryKey;
  final VoidCallback onShowPlayback;
  final VoidCallback onShowDestinations;
  final VoidCallback onReportPlaybackCoverRect;
  final Widget Function(
    BuildContext context, {
    required bool isPlaybackExpanded,
    required Animation<double> appearance,
    required Animation<double> expansion,
    required double availableWidth,
    required VoidCallback onCurrentTap,
  })
  buildBottomBar;

  @override
  State<MobileDockCapsuleContent> createState() =>
      MobileDockCapsuleContentState();
}

class MobileDockCapsuleContentState extends State<MobileDockCapsuleContent>
    with TickerProviderStateMixin {
  late final AnimationController _appearanceController;
  late final CurvedAnimation _appearanceCurve;
  late final AnimationController _expandController;
  late final Listenable _animationListenable;
  List<PlaybackSessionSnapshot> _cachedSessions = const [];
  final Object _motionInteraction = Object();
  Object? _appearancePreparation;
  bool _tickerModeEnabled = true;
  bool _disableAnimations = false;

  static const Duration _appearanceDuration = Duration(milliseconds: 280);
  static const Duration _motionDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    final hasPlayback = widget.overlaySessions.isNotEmpty;
    if (hasPlayback) {
      _cachedSessions = widget.overlaySessions;
    }
    _appearanceController = AnimationController(
      vsync: this,
      duration: _appearanceDuration,
      value: hasPlayback ? 1.0 : 0.0,
    );
    _appearanceCurve = CurvedAnimation(
      parent: _appearanceController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );
    _expandController = AnimationController(
      vsync: this,
      duration: _motionDuration,
      value: (hasPlayback && widget.isPlaybackExpanded) ? 1.0 : 0.0,
    );
    _animationListenable = Listenable.merge([
      _appearanceCurve,
      _expandController,
    ]);

    _appearanceController.addStatusListener((status) {
      _syncMotionInteraction();
      if (status == AnimationStatus.dismissed) {
        if (mounted && widget.overlaySessions.isEmpty) {
          setState(() {
            _cachedSessions = const [];
          });
        }
      }
      widget.onReportPlaybackCoverRect();
    });
    _expandController.addStatusListener((_) {
      _syncMotionInteraction();
      widget.onReportPlaybackCoverRect();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReportPlaybackCoverRect();
    });
  }

  void _syncMotionInteraction() {
    final coordinator = UiInteractionCoordinator.instance;
    if (!_tickerModeEnabled || _disableAnimations) {
      coordinator.cancelInteraction(_motionInteraction);
    } else if (_appearancePreparation != null ||
        _appearanceController.isAnimating ||
        _expandController.isAnimating) {
      // Keep new image decodes out of the moving dock's frames. Already
      // decoded covers can still be reused by RetryingImage during motion.
      coordinator.beginInteraction(
        _motionInteraction,
        deferVisualUpdates: true,
      );
    } else {
      coordinator.endInteraction(_motionInteraction);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations) {
      _appearancePreparation = null;
      final hasPlayback = widget.overlaySessions.isNotEmpty;
      _appearanceController.value = hasPlayback ? 1 : 0;
      _expandController.value = hasPlayback && widget.isPlaybackExpanded
          ? 1
          : 0;
    }
    _syncMotionInteraction();
  }

  @override
  void didUpdateWidget(covariant MobileDockCapsuleContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasPlayback = widget.overlaySessions.isNotEmpty;
    final hadPlayback = oldWidget.overlaySessions.isNotEmpty;

    if (hasPlayback) {
      _cachedSessions = widget.overlaySessions;
    }

    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    _disableAnimations = disableAnimations;

    if (hasPlayback != hadPlayback) {
      _appearancePreparation = null;
      if (disableAnimations) {
        _appearanceController.value = hasPlayback ? 1.0 : 0.0;
        if (!hasPlayback) {
          _cachedSessions = const [];
        }
      } else {
        if (hasPlayback) {
          if (_appearanceController.isDismissed) {
            _prepareAppearance();
          } else {
            _appearanceController.forward();
          }
        } else {
          _appearanceController.reverse();
          if (_appearanceController.isDismissed) _cachedSessions = const [];
        }
      }
      _syncMotionInteraction();
    }

    final isExpanded = hasPlayback && widget.isPlaybackExpanded;
    final wasExpanded = hadPlayback && oldWidget.isPlaybackExpanded;
    if (isExpanded != wasExpanded) {
      if (disableAnimations) {
        _expandController.value = isExpanded ? 1.0 : 0.0;
      } else {
        if (isExpanded) {
          _expandController.forward();
        } else {
          _expandController.reverse();
        }
      }
    }
  }

  void _prepareAppearance() {
    final preparation = _appearancePreparation = Object();
    _syncMotionInteraction();
    // Mount and paint the offscreen card before starting its clock. A slow
    // first layout must not consume the visible entrance animation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _appearancePreparation != preparation) return;
      _appearancePreparation = null;
      if (_disableAnimations || !_tickerModeEnabled) {
        _appearanceController.value = 1;
        _syncMotionInteraction();
      } else {
        _appearanceController.forward();
      }
    });
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(_motionInteraction);
    _appearanceCurve.dispose();
    _appearanceController.dispose();
    _expandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        const compactWidth = kActiveSessionCarouselDockHeight;
        final expandedPlaybackWidth =
            compactWidth +
            (availableWidth - compactWidth * 2).clamp(0.0, availableWidth);
        final playbackChild = _buildPlaybackChild(
          context,
          expandedPlaybackWidth,
        );
        final navigationChild = widget.buildBottomBar(
          context,
          isPlaybackExpanded: widget.isPlaybackExpanded,
          appearance: _appearanceCurve,
          expansion: _expandController,
          availableWidth: availableWidth,
          onCurrentTap: widget.onShowDestinations,
        );

        return AnimatedBuilder(
          animation: _animationListenable,
          builder: (context, _) {
            final appearance = _appearanceCurve.value;
            final expand = _expandController.value;
            final layoutProgress = Curves.easeInOut.transform(
              ((expand - 0.25) / 0.5).clamp(0.0, 1.0),
            );
            final playbackWidth =
                compactWidth +
                (expandedPlaybackWidth - compactWidth) * layoutProgress;
            final playbackOffset = playbackWidth * (1 - appearance);
            final navigationWidth =
                (availableWidth - playbackWidth * appearance).clamp(
                  0.0,
                  availableWidth,
                );

            return Stack(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    key: const ValueKey<String>('mobile_dock_navigation'),
                    width: navigationWidth,
                    height: kActiveSessionCarouselDockHeight,
                    // Change only the visible window. The icons already move
                    // with appearance, so their layout can retain full width.
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: availableWidth,
                        maxWidth: availableWidth,
                        minHeight: kActiveSessionCarouselDockHeight,
                        maxHeight: kActiveSessionCarouselDockHeight,
                        child: RepaintBoundary(child: navigationChild),
                      ),
                    ),
                  ),
                ),
                if (playbackChild != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Transform.translate(
                      offset: Offset(playbackOffset, 0),
                      child: RepaintBoundary(
                        child: SizedBox(
                          key: const ValueKey<String>('mobile_dock_playback'),
                          width: playbackWidth,
                          height: kActiveSessionCarouselDockHeight,
                          child: SizedBox.expand(
                            key: widget.mobilePlaybackGeometryKey,
                            child: ClipRRect(
                              key: const ValueKey<String>(
                                'mobile_dock_playback_viewport',
                              ),
                              borderRadius: BorderRadius.circular(
                                kActiveSessionCarouselDockHeight / 2,
                              ),
                              child: playbackChild,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget? _buildPlaybackChild(BuildContext context, double expandedWidth) {
    if (_cachedSessions.isEmpty) return null;
    return ActiveSessionCarousel(
      key: const ValueKey<String>('mobile_dock_carousel'),
      sessions: _cachedSessions,
      i18n: widget.i18n,
      viewportFraction: 1,
      expandedDockWidth: expandedWidth,
      presentation: ActiveSessionCarouselPresentation.embedded,
      onOpenSession: (sessionId) {
        if (!widget.isPlaybackExpanded) {
          widget.onShowPlayback();
          return;
        }
        Navigator.of(
          context,
          rootNavigator: true,
        ).push(buildSessionDetailRoute(sessionId: sessionId));
      },
    );
  }
}
