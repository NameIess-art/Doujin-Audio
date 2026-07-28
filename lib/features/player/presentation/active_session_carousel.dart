import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../application/audio_state_services.dart';
import '../application/playback_session.dart';
import '../../settings/application/settings_state.dart';
import '../domain/audio_effects.dart';
import '../../library/application/library_facade.dart';
import 'playlist_tab.dart';
import 'playback_position_ui_gate.dart';
import 'playback_error_text.dart';

part 'active_session_carousel_widgets.dart';

const double kActiveSessionCarouselBarHeight = 74;
const double kActiveSessionCarouselCapsuleHeight = 88;

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
    this.compactForFab = false,
  });

  final List<PlaybackSession>? sessions;
  final AppLanguageProvider? i18n;
  final ValueChanged<String>? onOpenSession;
  final bool compactForFab;

  @override
  ConsumerState<ActiveSessionCarousel> createState() =>
      _ActiveSessionCarouselState();
}

class _ActiveSessionCarouselState extends ConsumerState<ActiveSessionCarousel> {
  static const int _loopPageSeed = 100000;

  late PageController _pageController;
  late final ValueListenable<String?> _carouselSnapListenable;
  final ValueNotifier<double> _pageNotifier = ValueNotifier<double>(0);
  String? _lastCarouselSnapSessionId;
  BottomNavigationStyle? _lastStyle;
  bool _loopSeedScheduled = false;

  @override
  void initState() {
    super.initState();
    final initialStyle =
        ref.read(settingsStateProvider).value?.bottomNavigationStyle ??
        BottomNavigationStyle.capsule;
    _lastStyle = initialStyle;
    _pageController = PageController(
      viewportFraction: initialStyle == BottomNavigationStyle.bar ? 1.0 : 0.90,
    );
    _pageController.addListener(_handlePageTick);
    _carouselSnapListenable = ref
        .read(playlistUiControllerProvider)
        .carouselSnap;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _carouselSnapListenable.addListener(_handleCarouselSnap);
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
  }

  void _handleCarouselSnap() {
    if (!mounted) return;
    final sessionId = _carouselSnapListenable.value;
    if (sessionId == null || sessionId == _lastCarouselSnapSessionId) return;
    final sessions =
        widget.sessions ??
        (ref.read(playbackStateProvider).value?.activeSessions ??
            const <PlaybackSession>[]);
    final targetIndex = sessions.indexWhere((s) => s.id == sessionId);
    if (targetIndex < 0 || !_pageController.hasClients) return;
    _lastCarouselSnapSessionId = sessionId;
    _moveToPage(
      _pageForSessionIndex(targetIndex, sessions.length),
      duration: const Duration(milliseconds: 350),
    );
  }

  int _sessionIndexForPage(int page, int length) {
    if (length <= 0) return 0;
    final remainder = page % length;
    return remainder < 0 ? remainder + length : remainder;
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

  void _ensureLoopPageSeed(int length) {
    final currentPage = _pageNotifier.value.round();
    if (length <= 1) {
      if (currentPage == 0 || _loopSeedScheduled) return;
      _loopSeedScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loopSeedScheduled = false;
        if (!mounted || !_pageController.hasClients) return;
        _pageController.jumpToPage(0);
        _pageNotifier.value = 0;
      });
      return;
    }
    if (currentPage >= _loopPageSeed ~/ 2 || _loopSeedScheduled) return;
    _loopSeedScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loopSeedScheduled = false;
      if (!mounted || !_pageController.hasClients) return;
      final targetPage =
          _loopPageSeed + _sessionIndexForPage(currentPage, length);
      _pageController.jumpToPage(targetPage);
      _pageNotifier.value = targetPage.toDouble();
    });
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

  void _openSessionDetail(BuildContext context, PlaybackSession session) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    final onOpenSession = widget.onOpenSession;
    if (onOpenSession != null) {
      onOpenSession(session.id);
      return;
    }
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: session.id));
  }

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(
      settingsStateProvider.select(
        (s) => s.value?.bottomNavigationStyle ?? BottomNavigationStyle.capsule,
      ),
    );
    if (_lastStyle != style) {
      _lastStyle = style;
      final oldPage = _pageController.hasClients
          ? _pageController.page ?? 0.0
          : 0.0;
      _pageController.dispose();
      _pageController = PageController(
        initialPage: oldPage.round(),
        viewportFraction: style == BottomNavigationStyle.bar ? 1.0 : 0.90,
      );
      _pageController.addListener(_handlePageTick);
    }
    final isBar = style == BottomNavigationStyle.bar;

    final playbackState =
        ref.watch(playbackStateProvider).value ?? PlaybackStateSliceData();
    final library = ref.read(libraryFacadeProvider);
    final sessions = widget.sessions ?? playbackState.activeSessions;
    if (sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    final snapSessionId = _carouselSnapListenable.value;
    if (snapSessionId != null && snapSessionId != _lastCarouselSnapSessionId) {
      final targetIndex = sessions.indexWhere((s) => s.id == snapSessionId);
      if (targetIndex >= 0) {
        _lastCarouselSnapSessionId = snapSessionId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_pageController.hasClients) return;
          _moveToPage(
            _pageForSessionIndex(targetIndex, sessions.length),
            duration: const Duration(milliseconds: 350),
          );
        });
      }
    }

    _ensureLoopPageSeed(sessions.length);

    return SizedBox(
      height: isBar
          ? kActiveSessionCarouselBarHeight
          : kActiveSessionCarouselCapsuleHeight,
      child: Stack(
        children: [
          Listener(
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent && sessions.length > 1) {
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
              physics: sessions.length == 1
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              itemCount: sessions.length == 1 ? 1 : null,
              itemBuilder: (context, index) {
                final sessionIndex = _sessionIndexForPage(
                  index,
                  sessions.length,
                );
                final session = sessions[sessionIndex];
                final track = ref
                    .read(audioPathCoordinatorProvider)
                    .sessionTrackForPath(session.id, session.currentTrackPath);

                return _ActiveSessionPageTransform(
                  pageListenable: _pageNotifier,
                  index: index,
                  isBar: isBar,
                  child: RepaintBoundary(
                    child: _ActiveSessionCard(
                      session: session,
                      position: sessionIndex,
                      count: sessions.length,
                      coverPathFuture: _sessionCoverFutureForTrack(
                        library,
                        track,
                      ),
                      compact: widget.compactForFab,
                      onOpen: () => _openSessionDetail(context, session),
                    ),
                  ),
                );
              },
            ),
          ),
          if (sessions.length > 1)
            Positioned(
              right: 14,
              bottom: 3,
              child: IgnorePointer(
                child: ValueListenableBuilder<double>(
                  valueListenable: _pageNotifier,
                  builder: (context, page, child) {
                    final activePage = _sessionIndexForPage(
                      page.round(),
                      sessions.length,
                    );
                    return Semantics(
                      label: '${activePage + 1} / ${sessions.length}',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var index = 0; index < sessions.length; index++)
                            AnimatedContainer(
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 150),
                              margin: const EdgeInsets.symmetric(horizontal: 2),
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
      ),
    );
  }
}

class _ActiveSessionPageTransform extends StatelessWidget {
  const _ActiveSessionPageTransform({
    required this.pageListenable,
    required this.index,
    required this.child,
    required this.isBar,
  });

  final ValueListenable<double> pageListenable;
  final int index;
  final Widget child;
  final bool isBar;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pageListenable,
      child: child,
      builder: (context, child) {
        final pageDelta = index - pageListenable.value;
        final selectedness = (1 - pageDelta.abs()).clamp(0.0, 1.0);
        final scale = isBar
            ? 1.0
            : (lerpDouble(0.972, 1.0, selectedness) ?? 1.0);
        final translateY = isBar ? 0.0 : (lerpDouble(4, 0, selectedness) ?? 0);

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: isBar ? 0 : 2),
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}
