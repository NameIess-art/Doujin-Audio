import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/subtitle_settings_provider.dart';
import '../services/audio_state_services.dart';
import '../services/subtitle_parser.dart';
import '../screens/playlist_tab.dart';
import 'app_feedback.dart';
import 'async_cover_image.dart';
import 'library_like_cards.dart';

part 'active_session_carousel_widgets.dart';

Future<String?> _sessionCoverFutureForTrack(
  AudioProvider provider,
  MusicTrack? track,
) {
  if (track == null || (track.isSingle && !track.isVideo)) {
    return Future<String?>.value();
  }
  return provider.coverPathFutureForTrack(track);
}

class ActiveSessionCarousel extends ConsumerStatefulWidget {
  const ActiveSessionCarousel({
    super.key,
    this.sessions,
    this.provider,
    this.i18n,
    this.onOpenSession,
    this.compactForFab = false,
  });

  final List<PlaybackSession>? sessions;
  final AudioProvider? provider;
  final AppLanguageProvider? i18n;
  final ValueChanged<String>? onOpenSession;
  final bool compactForFab;

  @override
  ConsumerState<ActiveSessionCarousel> createState() =>
      _ActiveSessionCarouselState();
}

class _ActiveSessionCarouselState extends ConsumerState<ActiveSessionCarousel> {
  late PageController _pageController;
  late final ValueListenable<String?> _carouselSnapListenable;
  final ValueNotifier<double> _pageNotifier = ValueNotifier<double>(0);
  String? _lastCarouselSnapSessionId;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.90);
    _pageController.addListener(_handlePageTick);
    final AudioProvider provider =
        widget.provider ?? ref.read(audioProviderFacadeProvider);
    _carouselSnapListenable = provider.carouselSnapListenable;
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
    try {
      if (_pageController.hasClients) {
        nextPage = _pageController.page ?? current;
      }
    } catch (_) {}
    if ((nextPage - current).abs() < 0.001) return;
    _pageNotifier.value = nextPage;
  }

  void _handleCarouselSnap() {
    if (!mounted) return;
    final sessionId = _carouselSnapListenable.value;
    if (sessionId == null || sessionId == _lastCarouselSnapSessionId) return;
    _lastCarouselSnapSessionId = sessionId;
    final sessions =
        widget.sessions ??
        (ref.read(playbackStateProvider).valueOrNull?.activeSessions ??
            const <PlaybackSession>[]);
    final targetIndex = sessions.indexWhere((s) => s.id == sessionId);
    if (targetIndex < 0 || !_pageController.hasClients) return;
    _pageController.animateToPage(
      targetIndex,
      duration: const Duration(milliseconds: 350),
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

  void _ensureValidPage(int length) {
    if (length == 0) return;
    final maxPage = length - 1;
    final currentPage = _pageNotifier.value.round();
    if (currentPage <= maxPage) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(maxPage);
      _pageNotifier.value = maxPage.toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final playbackState =
        ref.watch(playbackStateProvider).valueOrNull ??
        const PlaybackStateSliceData();
    final AudioProvider provider =
        widget.provider ?? ref.read(audioProviderFacadeProvider);
    final sessions = widget.sessions ?? playbackState.activeSessions;
    if (sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    _ensureValidPage(sessions.length);

    return SizedBox(
      height: 88,
      child: Listener(
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent && sessions.length > 1) {
            if (signal.scrollDelta.dy > 0) {
              _pageController.nextPage(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
              );
            } else if (signal.scrollDelta.dy < 0) {
              _pageController.previousPage(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
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
          itemCount: sessions.length,
          itemBuilder: (context, index) {
            final session = sessions[index];
            final track = provider.trackByPath(session.currentTrackPath);

            return _ActiveSessionPageTransform(
              pageListenable: _pageNotifier,
              index: index,
              child: RepaintBoundary(
                child: _ActiveSessionCard(
                  session: session,
                  provider: provider,
                  coverPathFuture: _sessionCoverFutureForTrack(provider, track),
                  compact: widget.compactForFab,
                  onOpen: () => _openSessionDetail(context, session),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ActiveSessionPageTransform extends StatelessWidget {
  const _ActiveSessionPageTransform({
    required this.pageListenable,
    required this.index,
    required this.child,
  });

  final ValueListenable<double> pageListenable;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pageListenable,
      child: child,
      builder: (context, child) {
        final pageDelta = index - pageListenable.value;
        final selectedness = (1 - pageDelta.abs()).clamp(0.0, 1.0);
        final scale = lerpDouble(0.972, 1.0, selectedness) ?? 1.0;
        final translateY = lerpDouble(4, 0, selectedness) ?? 0;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}
