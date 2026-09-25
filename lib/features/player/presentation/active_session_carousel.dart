import '../../library/presentation/library_providers.dart';
import 'playback_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../application/playback_session_snapshot.dart';
import '../application/playback_subtitle_service.dart';
import '../../settings/application/settings_state.dart';
import '../domain/audio_effects.dart';
import '../../library/application/library_facade.dart';
import 'playlist_tab.dart';
import 'playback_position_ui_gate.dart';
import 'playback_error_text.dart';

part 'active_session_carousel_widgets.dart';

const double kActiveSessionCarouselCapsuleHeight = 56;
const double kActiveSessionCarouselDockHeight = 56;
const double kMobileDockBottomMargin = 12;

enum ActiveSessionCarouselPresentation {
  card,
  compact,
  embedded,
  circularCover,
}

Future<String?> _sessionCoverFutureForTrack(
  LibraryFacade library,
  MusicTrack? track,
) {
  if (track == null) {
    return Future<String?>.value();
  }
  return library.playbackCoverPathFutureForTrack(track);
}

class ActiveSessionCarousel extends ConsumerStatefulWidget {
  const ActiveSessionCarousel({
    super.key,
    this.sessions,
    this.i18n,
    this.onOpenSession,
    this.onVisibleSessionChanged,
    this.presentation = ActiveSessionCarouselPresentation.card,
    this.viewportFraction,
  });

  final List<PlaybackSessionSnapshot>? sessions;
  final AppLanguageProvider? i18n;
  final ValueChanged<String>? onOpenSession;
  final ValueChanged<String>? onVisibleSessionChanged;
  final ActiveSessionCarouselPresentation presentation;
  final double? viewportFraction;

  @override
  ConsumerState<ActiveSessionCarousel> createState() =>
      _ActiveSessionCarouselState();
}

class _ActiveSessionCarouselState extends ConsumerState<ActiveSessionCarousel> {
  static const int _loopPageSeed = 100000;

  late PageController _pageController;
  late final ValueListenable<String?> _carouselSnapListenable;
  late final ActiveVisibleSessionCardIdNotifier _visibleSessionNotifier;
  final ValueNotifier<double> _pageNotifier = ValueNotifier<double>(
    _loopPageSeed.toDouble(),
  );
  List<PlaybackSessionSnapshot> _currentSessions = const [];
  List<PlaybackSessionSnapshot> _incomingSessions = const [];
  int _pageIndexOffset = 0;
  bool _removingFocusedSession = false;
  String? _lastCarouselSnapSessionId;
  String? _lastVisibleSessionId;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: _loopPageSeed,
      viewportFraction: widget.viewportFraction ?? 0.90,
    );
    _pageController.addListener(_handlePageTick);
    _carouselSnapListenable = ref
        .read(playlistUiControllerProvider)
        .carouselSnap;
    _visibleSessionNotifier = ref.read(
      activeVisibleSessionCardIdProvider.notifier,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _carouselSnapListenable.addListener(_handleCarouselSnap);
        _notifyVisibleSessionChanged();
      }
    });
  }

  @override
  void didUpdateWidget(covariant ActiveSessionCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Removed dangerous _pageController disposal and recreation
    // that caused "ScrollController attached to multiple scroll views" crashes.
  }

  @override
  void dispose() {
    _carouselSnapListenable.removeListener(_handleCarouselSnap);
    _pageController
      ..removeListener(_handlePageTick)
      ..dispose();
    _pageNotifier.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleSessionNotifier.setVisible(null);
    });
    super.dispose();
  }

  void _handlePageTick() {
    final current = _pageNotifier.value;
    double nextPage = current;
    if (_pageController.positions.length == 1) {
      nextPage = _pageController.page ?? current;
    }
    if ((nextPage - current).abs() < 0.001) return;
    _pageNotifier.value = nextPage;
    _notifyVisibleSessionChanged();
  }

  void _notifyVisibleSessionChanged() {
    final sessions = _currentSessions;
    if (sessions.isEmpty) return;
    final index = _sessionIndexForPage(
      _pageNotifier.value.round(),
      sessions.length,
    );
    final sessionId = sessions[index].id;
    if (_lastVisibleSessionId == sessionId) return;
    _lastVisibleSessionId = sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastVisibleSessionId != sessionId) return;
      ref
          .read(activeVisibleSessionCardIdProvider.notifier)
          .setVisible(sessionId);
      ref.read(notificationFacadeProvider).setFocusedSession(sessionId);
      widget.onVisibleSessionChanged?.call(sessionId);
    });
  }

  void _handleCarouselSnap() {
    if (!mounted) return;
    final sessionId = _carouselSnapListenable.value;
    if (sessionId == null) return;
    final sessions = _currentSessions;
    final targetIndex = sessions.indexWhere((s) => s.id == sessionId);
    if (targetIndex < 0 || !_pageController.hasClients) return;
    _lastCarouselSnapSessionId = sessionId;
    if (_lastVisibleSessionId == sessionId) return;
    _moveToPage(
      _pageForSessionIndex(targetIndex, sessions.length),
      duration: const Duration(milliseconds: 350),
    );
  }

  int _sessionIndexForPage(int page, int length) {
    if (length <= 0) return 0;
    final remainder = (page + _pageIndexOffset) % length;
    return remainder < 0 ? remainder + length : remainder;
  }

  void _alignPageWithSession(
    String sessionId,
    List<PlaybackSessionSnapshot> sessions,
  ) {
    final index = sessions.indexWhere((session) => session.id == sessionId);
    if (index < 0) return;
    _pageIndexOffset = (index - _pageNotifier.value.round()) % sessions.length;
  }

  bool _sameSessionOrder(List<PlaybackSessionSnapshot> sessions) {
    if (sessions.length != _currentSessions.length) return false;
    for (var index = 0; index < sessions.length; index++) {
      if (sessions[index].id != _currentSessions[index].id) return false;
    }
    return true;
  }

  Future<void> _slideToLeftSession(String leftSessionId) async {
    if (!mounted || !_pageController.hasClients) {
      _removingFocusedSession = false;
      return;
    }
    final targetPage = _pageNotifier.value.round() - 1;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(targetPage);
    } else {
      await _pageController.animateToPage(
        targetPage,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    setState(() {
      _currentSessions = _incomingSessions;
      if (_currentSessions.isNotEmpty) {
        _alignPageWithSession(leftSessionId, _currentSessions);
      }
      _removingFocusedSession = false;
    });
  }

  int _pageForSessionIndex(int targetIndex, int length) {
    if (length <= 1) return _pageNotifier.value.round();
    final currentPage = _pageNotifier.value.round();
    final currentIndex = _sessionIndexForPage(currentPage, length);
    var delta = targetIndex - currentIndex;
    if (delta > length / 2) {
      delta -= length;
    } else if (delta < -length / 2) {
      delta += length;
    }
    return currentPage + delta;
  }

  void _moveToPage(int page, {required Duration duration}) {
    if (!_pageController.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(page);
      return;
    }
    _pageController.animateToPage(
      page,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  void _openSessionDetail(
    BuildContext context,
    PlaybackSessionSnapshot session,
  ) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    final onOpenSession = widget.onOpenSession;
    if (onOpenSession != null) {
      onOpenSession(session.id);
      return;
    }
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: session.id));
  }

  double get _viewportFraction => widget.viewportFraction ?? 0.90;

  @override
  Widget build(BuildContext context) {
    ref.watch(coverGenerationProvider);
    final viewportFraction = _viewportFraction;
    if (_pageController.viewportFraction != viewportFraction) {
      final oldPage = _pageController.hasClients
          ? _pageController.page ?? 0.0
          : 0.0;
      _pageController.dispose();
      _pageController = PageController(
        initialPage: oldPage.round(),
        viewportFraction: viewportFraction,
      );
      _pageController.addListener(_handlePageTick);
    }

    final library = ref.read(libraryFacadeProvider);
    final List<PlaybackSessionSnapshot> sessions;
    final providedSessions = widget.sessions;
    if (providedSessions != null) {
      sessions = providedSessions;
    } else {
      sessions = ref.watch(
        mainOverlayUiProvider.select((state) => state.overlaySessions),
      );
    }
    if (sessions.isEmpty) {
      _currentSessions = const [];
      if (_lastVisibleSessionId != null) {
        _lastVisibleSessionId = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref
                .read(activeVisibleSessionCardIdProvider.notifier)
                .setVisible(null);
          }
        });
      }
      return const SizedBox.shrink();
    }
    _incomingSessions = sessions;
    if (_currentSessions.isEmpty) {
      _currentSessions = sessions;
      var latestIndex = 0;
      for (var index = 1; index < sessions.length; index++) {
        final candidate = sessions[index];
        final latest = sessions[latestIndex];
        if (candidate.playbackRequested != latest.playbackRequested) {
          if (candidate.playbackRequested) latestIndex = index;
          continue;
        }
        final playedAt = candidate.lastPlayedAt;
        final latestPlayedAt = latest.lastPlayedAt;
        if (playedAt != null &&
            (latestPlayedAt == null || playedAt.isAfter(latestPlayedAt))) {
          latestIndex = index;
        }
      }
      _alignPageWithSession(sessions[latestIndex].id, sessions);
    } else if (!_removingFocusedSession && !_sameSessionOrder(sessions)) {
      final visibleId =
          _currentSessions[_sessionIndexForPage(
                _pageNotifier.value.round(),
                _currentSessions.length,
              )]
              .id;
      if (sessions.any((session) => session.id == visibleId)) {
        _currentSessions = sessions;
        _alignPageWithSession(visibleId, sessions);
      } else {
        final leftSessionId =
            _currentSessions[_sessionIndexForPage(
                  _pageNotifier.value.round() - 1,
                  _currentSessions.length,
                )]
                .id;
        _removingFocusedSession = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _slideToLeftSession(leftSessionId);
        });
      }
    } else if (!_removingFocusedSession) {
      _currentSessions = sessions;
    }
    final visibleSessions = _currentSessions;
    _notifyVisibleSessionChanged();

    final snapSessionId = _carouselSnapListenable.value;
    if (snapSessionId != null && snapSessionId != _lastCarouselSnapSessionId) {
      final targetIndex = visibleSessions.indexWhere(
        (s) => s.id == snapSessionId,
      );
      if (targetIndex >= 0) {
        _lastCarouselSnapSessionId = snapSessionId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_pageController.hasClients) return;
          _moveToPage(
            _pageForSessionIndex(targetIndex, visibleSessions.length),
            duration: const Duration(milliseconds: 350),
          );
        });
      }
    }

    final requestsCircularCover =
        widget.presentation == ActiveSessionCarouselPresentation.circularCover;
    final compact =
        widget.presentation == ActiveSessionCarouselPresentation.compact;
    final embedded =
        widget.presentation == ActiveSessionCarouselPresentation.embedded;
    final dockPresentation = requestsCircularCover || embedded;

    return SizedBox(
      height: dockPresentation
          ? kActiveSessionCarouselDockHeight
          : kActiveSessionCarouselCapsuleHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final circularCover = requestsCircularCover;
          final dockCollapsed = embedded && totalWidth < 160;
          final pagingLocked = circularCover || dockCollapsed;
          final cardRightInset =
              ((totalWidth * (1.0 - viewportFraction) / 2) + 2.0).clamp(
                0.0,
                totalWidth,
              );
          final indicatorRight = cardRightInset + 16.0;
          const indicatorBottom = 4.0;

          return Stack(
            children: [
              Listener(
                onPointerSignal: (signal) {
                  if (!pagingLocked &&
                      signal is PointerScrollEvent &&
                      visibleSessions.length > 1) {
                    final currentPage = _pageNotifier.value.round();
                    final delta = signal.scrollDelta.dy > 0
                        ? 1
                        : signal.scrollDelta.dy < 0
                        ? -1
                        : 0;
                    if (delta != 0) {
                      _moveToPage(
                        currentPage + delta,
                        duration: const Duration(milliseconds: 250),
                      );
                    }
                  }
                },
                child: PageView.builder(
                  controller: _pageController,
                  scrollBehavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                    },
                  ),
                  physics: visibleSessions.length == 1 || pagingLocked
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                  itemBuilder: (context, index) {
                    final sessionIndex = _sessionIndexForPage(
                      index,
                      visibleSessions.length,
                    );
                    final session = visibleSessions[sessionIndex];
                    final track = ref
                        .read(audioPathCoordinatorProvider)
                        .sessionTrackForPath(
                          session.id,
                          session.currentTrackPath,
                        );

                    return _ActiveSessionPageTransform(
                      pageListenable: _pageNotifier,
                      index: index,
                      enabled:
                          visibleSessions.length > 1 &&
                          !circularCover &&
                          !embedded,
                      child: RepaintBoundary(
                        child: _ActiveSessionCard(
                          session: session,
                          position: sessionIndex,
                          count: visibleSessions.length,
                          coverPathFuture: _sessionCoverFutureForTrack(
                            library,
                            track,
                          ),
                          compact: compact,
                          embedded: embedded,
                          dockCollapsed: dockCollapsed,
                          circularCover: circularCover,
                          onOpen: () => _openSessionDetail(context, session),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (visibleSessions.length > 1 && !compact && !pagingLocked)
                Positioned(
                  right: indicatorRight,
                  bottom: indicatorBottom,
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _pageNotifier,
                      builder: (context, page, child) {
                        final activePage = _sessionIndexForPage(
                          page.round(),
                          visibleSessions.length,
                        );
                        return Semantics(
                          label:
                              '${activePage + 1} / ${visibleSessions.length}',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (
                                var index = 0;
                                index < visibleSessions.length;
                                index++
                              )
                                AnimatedContainer(
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 150),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  width: index == activePage ? 12 : 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: index == activePage
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                              .withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ActiveSessionPageTransform extends StatelessWidget {
  const _ActiveSessionPageTransform({
    required this.pageListenable,
    required this.index,
    required this.child,
    this.enabled = true,
  });

  final ValueListenable<double> pageListenable;
  final int index;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pageListenable,
      child: child,
      builder: (context, child) {
        final pageDelta = index - pageListenable.value;
        final selectedness = (1 - pageDelta.abs()).clamp(0.0, 1.0);
        final scale = enabled
            ? (lerpDouble(0.972, 1.0, selectedness) ?? 1.0)
            : 1.0;
        final translateY = enabled
            ? (lerpDouble(2.5, 0, selectedness) ?? 0)
            : 0.0;

        return Padding(
          padding: enabled
              ? const EdgeInsets.symmetric(horizontal: 2)
              : EdgeInsets.zero,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}
