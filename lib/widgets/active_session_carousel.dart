import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/subtitle_parser.dart';
import '../screens/playlist_tab.dart';
import 'async_cover_image.dart';
import 'snap_scroll_physics.dart';

part 'active_session_carousel_widgets.dart';

Future<String?> _sessionCoverFutureForTrack(
  Map<String, Future<String?>> cache,
  AudioProvider provider,
  MusicTrack? track,
) {
  if (track == null) {
    return Future<String?>.value();
  }
  final cacheKey = track.path.startsWith('content://')
      ? 'content:${track.groupKey.isNotEmpty ? track.groupKey : track.path}'
      : path.normalize(path.dirname(track.path));
  return cache.putIfAbsent(
    cacheKey,
    () => provider.coverPathFutureForTrack(track),
  );
}

class ActiveSessionCarousel extends StatefulWidget {
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
  State<ActiveSessionCarousel> createState() => _ActiveSessionCarouselState();
}

class _ActiveSessionCarouselState extends State<ActiveSessionCarousel> {
  final Map<String, Future<String?>> _coverFutures = {};
  late PageController _pageController;

  double _page = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.90);
    _pageController.addListener(_handlePageTick);
  }

  @override
  void didUpdateWidget(covariant ActiveSessionCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.compactForFab == widget.compactForFab) return;

    final currentPage = _pageController.hasClients
        ? (_pageController.page ?? _page).round()
        : _page.round();
    _pageController
      ..removeListener(_handlePageTick)
      ..dispose();
    _pageController = PageController(
      initialPage: currentPage,
      viewportFraction: 0.90,
    );
    _pageController.addListener(_handlePageTick);
  }

  @override
  void dispose() {
    _pageController
      ..removeListener(_handlePageTick)
      ..dispose();
    super.dispose();
  }

  void _handlePageTick() {
    final nextPage = _pageController.hasClients
        ? (_pageController.page ?? _page)
        : _page;
    if ((nextPage - _page).abs() < 0.001) return;
    setState(() {
      _page = nextPage;
    });
  }

  void _openSessionDetail(BuildContext context, PlaybackSession session) {
    HapticFeedback.lightImpact();
    final onOpenSession = widget.onOpenSession;
    if (onOpenSession != null) {
      onOpenSession(session.id);
      return;
    }
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: session.id));
  }

  void _ensureValidPage(int length) {
    if (!_pageController.hasClients || length == 0) return;
    final maxPage = length - 1;
    final currentPage = (_pageController.page ?? 0).round();
    if (currentPage <= maxPage) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(maxPage);
      setState(() {
        _page = maxPage.toDouble();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider ?? context.read<AudioProvider>();
    final sessions =
        widget.sessions ??
        context.select<AudioProvider, List<PlaybackSession>>(
          (value) => value.activeSessions,
        );
    if (sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    _ensureValidPage(sessions.length);

    return SizedBox(
      height: 88,
      child: PageView.builder(
        controller: _pageController,
        pageSnapping: false,
        physics: sessions.length == 1
            ? const NeverScrollableScrollPhysics()
            : const SnapScrollPhysics(parent: BouncingScrollPhysics()),
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          final pageDelta = index - _page;
          final selectedness = (1 - pageDelta.abs()).clamp(0.0, 1.0);
          final scale = lerpDouble(0.972, 1.0, selectedness) ?? 1.0;
          const translateX =
              0.0; // Remove push-away translation to keep edges visible
          final translateY = lerpDouble(4, 0, selectedness) ?? 0;
          final track = provider.trackByPath(session.currentTrackPath);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Transform.translate(
              offset: Offset(translateX, translateY),
              child: Transform.scale(
                scale: scale,
                child: _ActiveSessionCard(
                  session: session,
                  track: track,
                  provider: provider,
                  coverPathFuture: _sessionCoverFutureForTrack(
                    _coverFutures,
                    provider,
                    track,
                  ),
                  onOpen: () => _openSessionDetail(context, session),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
