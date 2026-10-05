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
    required double anchorProgress,
    required double stackProgress,
    required double expandedWidth,
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
    } else if (_appearanceController.isAnimating ||
        _expandController.isAnimating) {
      coordinator.beginInteraction(_motionInteraction);
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
      if (disableAnimations) {
        _appearanceController.value = hasPlayback ? 1.0 : 0.0;
        if (!hasPlayback) {
          _cachedSessions = const [];
        }
      } else {
        if (hasPlayback) {
          _appearanceController.forward();
        } else {
          _appearanceController.reverse();
        }
      }
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
        final playbackChild = _buildPlaybackChild(context);

        return AnimatedBuilder(
          animation: _animationListenable,
          builder: (context, _) {
            final appearance = _appearanceCurve.value;
            final expand = _expandController.value;
            // Move the first icon first, then gather the others behind it.
            final anchorProgress = Curves.easeInOut.transform(
              (expand / 0.2).clamp(0.0, 1.0),
            );
            final stackProgress = Curves.easeInOut.transform(
              ((expand - 0.2) / 0.45).clamp(0.0, 1.0),
            );
            final layoutProgress = Curves.easeInOut.transform(
              ((expand - 0.25) / 0.5).clamp(0.0, 1.0),
            );
            const compactWidth = kActiveSessionCarouselDockHeight;
            final playbackWidth =
                compactWidth +
                (availableWidth - compactWidth * 2).clamp(0.0, availableWidth) *
                    layoutProgress;
            final playbackOffset = playbackWidth * (1 - appearance);
            final navigationWidth =
                (availableWidth - playbackWidth * appearance).clamp(
                  0.0,
                  availableWidth,
                );
            final navigationChild = _buildNavigationChild(
              context,
              anchorProgress: anchorProgress,
              stackProgress: stackProgress,
              expandedWidth: availableWidth - compactWidth * appearance,
            );

            return Stack(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(
                    child: SizedBox(
                      key: const ValueKey<String>('mobile_dock_navigation'),
                      width: navigationWidth,
                      height: kActiveSessionCarouselDockHeight,
                      child: navigationChild,
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

  Widget _buildNavigationChild(
    BuildContext context, {
    required double anchorProgress,
    required double stackProgress,
    required double expandedWidth,
  }) {
    return ClipRect(
      child: widget.buildBottomBar(
        context,
        isPlaybackExpanded: widget.isPlaybackExpanded,
        anchorProgress: anchorProgress,
        stackProgress: stackProgress,
        expandedWidth: expandedWidth,
        onCurrentTap: widget.onShowDestinations,
      ),
    );
  }

  Widget? _buildPlaybackChild(BuildContext context) {
    if (_cachedSessions.isEmpty) return null;
    return ActiveSessionCarousel(
      key: const ValueKey<String>('mobile_dock_carousel'),
      sessions: _cachedSessions,
      i18n: widget.i18n,
      viewportFraction: 1,
      presentation: ActiveSessionCarouselPresentation.embedded,
      onOpenSession: (sessionId) {
        if (!widget.isPlaybackExpanded) {
          widget.onShowPlayback();
          return;
        }
        Navigator.of(
          context,
        ).push(buildSessionDetailRoute(sessionId: sessionId));
      },
    );
  }
}
