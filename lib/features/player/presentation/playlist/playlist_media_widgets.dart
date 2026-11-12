import 'dart:math' as math;
import 'dart:ui' as ui show Image;

import '../../../library/presentation/library_providers.dart';
import '../../../settings/presentation/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/ui/visual_settings_providers.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../application/playback_session_snapshot.dart';
import '../playback_position_ui_gate.dart';
import '../playback_providers.dart';
import '../session_video_surface.dart';
import '../session_video_viewport.dart';
import 'playlist_shared_helpers.dart';
import 'playlist_video_widgets.dart';
import 'session_cover_transition.dart';

class SessionHeroArtwork extends ConsumerWidget {
  const SessionHeroArtwork({
    super.key,
    required this.session,
    required this.height,
    required this.track,
    required this.coverPathFuture,
    this.initialCoverPath,
    this.coverAnchorKey,
    this.coverPreview,
    this.mountVideoSurface = true,
  });

  final PlaybackSessionSnapshot session;
  final double height;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;
  final String? initialCoverPath;
  final GlobalKey<SessionCoverAnchorState>? coverAnchorKey;
  final ui.Image? coverPreview;
  final bool mountVideoSurface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final sessionId = session.id;
    final cs = Theme.of(context).colorScheme;
    final allowVideoPlayback = ref.watch(
      settingsStateProvider.select((s) => s.value?.allowVideoPlayback ?? true),
    );
    final videoReady =
        allowVideoPlayback && isSessionVideoReady(session, track);
    final coverResolution = ref.watch(coverImageResolutionProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth;
        final coverCacheWidth = coverCacheWidthForResolution(coverResolution);
        final coverPoster = Stack(
          fit: StackFit.expand,
          children: [
            TickerMode(
              // Do not freeze a cover image's loading fade mid-frame while the
              // detail route is transitioning.
              enabled: true,
              child: AsyncLocalCoverImage(
                deferLoadDuringInteraction: true,
                onImageError:
                    library.coverArtworkCacheService.reportArtworkReadFailure,
                future: coverPathFuture,
                requestKey: (
                  sessionId,
                  track?.path ?? session.currentTrackPath,
                ),
                initialPath: initialCoverPath,
                cacheWidth: coverCacheWidth,
                useDefaultCacheWidth: false,
                fit: BoxFit.cover,
                fallbackBuilder: coverPreview == null
                    ? null
                    : (_) => RawImage(
                        key: const ValueKey('session_detail_cover_preview'),
                        image: coverPreview,
                        fit: BoxFit.cover,
                      ),
              ),
            ),
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
        );

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: Container(
            key: ValueKey('session_detail_cover_$sessionId'),
            width: displayWidth,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cs.onSurface.withValues(alpha: 0.12),
                width: 0.5,
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: RepaintBoundary(
                // Match the pixels inside the frame's border padding.
                child: SessionCoverAnchor(
                  key: coverAnchorKey,
                  sessionId: sessionId,
                  radius: 16,
                  enabled: !videoReady,
                  child: SessionVideoViewport(
                    videoReady: videoReady && mountVideoSurface,
                    surfaceBuilder: (_) => NativeSessionVideoSurface(
                      sessionId: sessionId,
                      nativeRepository: ref
                          .read(playbackFacadeProvider)
                          .nativeRepository,
                    ),
                    onFullscreen: () => showSessionVideoFullscreen(
                      context,
                      ref,
                      sessionId: sessionId,
                      trackPath: track!.path,
                    ),
                    fullscreenTooltip: ref
                        .read(appLanguageProviderInstanceProvider)
                        .tr('fullscreen'),
                    poster: allowVideoPlayback && track?.isVideo == true
                        ? SessionVideoBlurredBackdrop(child: coverPoster)
                        : coverPoster,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SessionCoverThumbnail extends ConsumerStatefulWidget {
  const SessionCoverThumbnail({
    super.key,
    required this.sessionId,
    required this.track,
    required this.coverPath,
    required this.coverGeneration,
    required this.coverCacheWidth,
    this.dimension = playlistCoverSize,
  });

  final String sessionId;
  final MusicTrack? track;
  final String? coverPath;
  final int coverGeneration;
  final int? coverCacheWidth;
  final double dimension;

  @override
  ConsumerState<SessionCoverThumbnail> createState() =>
      _SessionCoverThumbnailState();
}

class _SessionCoverThumbnailState extends ConsumerState<SessionCoverThumbnail> {
  Future<String?>? _coverFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _futureFor() {
    final trackPath = widget.track?.path;
    if (_coverFuture == null ||
        _lastTrackPath != trackPath ||
        _lastCoverGeneration != widget.coverGeneration) {
      _lastTrackPath = trackPath;
      _lastCoverGeneration = widget.coverGeneration;
      // Admit discovery through the same bounded queue as library artwork;
      // deferring image decode alone still starts source work during layout.
      _coverFuture = ref
          .read(libraryCoverUiControllerProvider)
          .deferredPlaybackCover(widget.track, context: context);
    }
    return _coverFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final cover = AsyncLocalCoverImage(
      deferLoadDuringInteraction: true,
      onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
      future: _futureFor(),
      requestKey: (widget.sessionId, widget.track?.path),
      initialPath: widget.coverPath,
      retryFutureBuilder: () => ref
          .read(libraryCoverUiControllerProvider)
          .deferredPlaybackCover(widget.track, context: context),
      cacheWidth: widget.coverCacheWidth,
      useDefaultCacheWidth: widget.coverCacheWidth != null,
      fit: BoxFit.cover,
    );
    return SizedBox.square(
      key: ValueKey<String>('playlist_cover_${widget.sessionId}'),
      dimension: widget.dimension,
      child: SessionCoverAnchor(
        sessionId: widget.sessionId,
        radius: widget.dimension / 2,
        location: SessionCoverLocation.playlist,
        child: CoverArtworkFrame(
          borderRadius: BorderRadius.circular(widget.dimension / 2),
          child: cover,
        ),
      ),
    );
  }
}

const double kCoverProgressStrokeWidth = 2.5;
const double kCoverProgressGap = 0.0;

double coverProgressInnerDimension(
  double outerDimension, {
  double strokeWidth = kCoverProgressStrokeWidth,
  double gap = kCoverProgressGap,
}) {
  return (outerDimension - 2 * (strokeWidth + gap)).clamp(0.0, double.infinity);
}

class SessionCoverProgressRing extends ConsumerStatefulWidget {
  const SessionCoverProgressRing({
    super.key,
    this.session,
    this.sessionId,
    this.size,
    this.width,
    this.height,
    this.borderRadius,
    required this.child,
    this.activeColor,
    this.trackColor,
    this.strokeWidth = kCoverProgressStrokeWidth,
    this.gap = kCoverProgressGap,
  });

  final PlaybackSessionSnapshot? session;
  final String? sessionId;
  final double? size;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Widget child;
  final Color? activeColor;
  final Color? trackColor;
  final double strokeWidth;
  final double gap;

  @override
  ConsumerState<SessionCoverProgressRing> createState() =>
      _SessionCoverProgressRingState();
}

class _SessionCoverProgressRingState
    extends ConsumerState<SessionCoverProgressRing> {
  PlaybackPositionUiGate? _positionGate;
  PlaybackSessionSnapshot? _lastSession;

  PlaybackSessionSnapshot? _resolveSession() {
    if (widget.session != null) return widget.session;
    final id = widget.sessionId;
    if (id != null) {
      return ref.read(playbackFacadeProvider).sessionSnapshotById(id);
    }
    return null;
  }

  void _syncGate(PlaybackSessionSnapshot? session) {
    if (session == null) {
      _positionGate?.dispose();
      _positionGate = null;
      _lastSession = null;
      return;
    }

    if (_positionGate == null) {
      _positionGate = PlaybackPositionUiGate(
        session: session,
        includeBufferedPosition: false,
      );
      _positionGate!.tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    } else if (_lastSession != session) {
      _positionGate!.updateSession(session);
    }
    _lastSession = session;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_positionGate == null) {
      _syncGate(_resolveSession());
    } else {
      _positionGate!.tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    }
  }

  @override
  void didUpdateWidget(covariant SessionCoverProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGate(_resolveSession());
  }

  @override
  void dispose() {
    _positionGate?.dispose();
    _positionGate = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeColor = widget.activeColor ?? cs.primary;
    final trackColor = widget.trackColor ??
        activeColor.withValues(alpha: 0.18);

    final w = widget.width ?? widget.size ?? playlistCoverSize;
    final h = widget.height ?? widget.size ?? playlistCoverSize;
    final insets = 2 * (widget.strokeWidth + widget.gap);
    final innerW = (w - insets).clamp(0.0, double.infinity);
    final innerH = (h - insets).clamp(0.0, double.infinity);

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(width: innerW, height: innerH, child: widget.child),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _CoverProgressRingPainter(
                    positionGate: _positionGate,
                    activeColor: activeColor,
                    trackColor: trackColor,
                    strokeWidth: widget.strokeWidth,
                    borderRadius: widget.borderRadius,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverProgressRingPainter extends CustomPainter {
  _CoverProgressRingPainter({
    required this.positionGate,
    required this.activeColor,
    required this.trackColor,
    required this.strokeWidth,
    this.borderRadius,
  }) : super(repaint: positionGate);

  final PlaybackPositionUiGate? positionGate;
  final Color activeColor;
  final Color trackColor;
  final double strokeWidth;
  final BorderRadius? borderRadius;

  double get fraction {
    final snapshot = positionGate?.value;
    final duration = snapshot?.duration;
    if (snapshot == null || duration == null || duration.inMilliseconds <= 0) {
      return 0;
    }
    return snapshot.position.inMilliseconds / duration.inMilliseconds;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final br = borderRadius;
    if (br == null) {
      final center = Offset(size.width / 2, size.height / 2);
      final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
      if (radius <= 0) return;

      final trackPaint = Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(center, radius, trackPaint);

      final clamped = fraction.clamp(0.0, 1.0);
      if (clamped <= 0.0) return;

      final progressPaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      if (clamped >= 0.999) {
        canvas.drawCircle(center, radius, progressPaint);
      } else {
        final sweepAngle = clamped * 2 * math.pi;
        const startAngle = -math.pi / 2;
        final rect = Rect.fromCircle(center: center, radius: radius);
        canvas.drawArc(rect, startAngle, sweepAngle, false, progressPaint);
      }
      return;
    }

    // Rounded rectangle progress ring
    final halfStroke = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      halfStroke,
      halfStroke,
      math.max(0.0, size.width - strokeWidth),
      math.max(0.0, size.height - strokeWidth),
    );
    if (rect.width <= 0 || rect.height <= 0) return;

    final maxRadius = math.min(rect.width, rect.height) / 2;
    final r = (br.topLeft.x - halfStroke).clamp(0.0, maxRadius);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(rrect, trackPaint);

    final clamped = fraction.clamp(0.0, 1.0);
    if (clamped <= 0.0) return;

    final progressPaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    if (clamped >= 0.999) {
      canvas.drawRRect(rrect, progressPaint);
    } else {
      final top = rect.top;
      final bottom = rect.bottom;
      final left = rect.left;
      final right = rect.right;
      final cx = rect.center.dx;

      final path = Path()
        ..moveTo(cx, top)
        ..lineTo(right - r, top);
      if (r > 0) {
        path.arcToPoint(Offset(right, top + r), radius: Radius.circular(r));
      }
      path.lineTo(right, bottom - r);
      if (r > 0) {
        path.arcToPoint(Offset(right - r, bottom), radius: Radius.circular(r));
      }
      path.lineTo(left + r, bottom);
      if (r > 0) {
        path.arcToPoint(Offset(left, bottom - r), radius: Radius.circular(r));
      }
      path.lineTo(left, top + r);
      if (r > 0) {
        path.arcToPoint(Offset(left + r, top), radius: Radius.circular(r));
      }
      path.lineTo(cx, top);
      path.close();

      final metrics = path.computeMetrics().toList();
      if (metrics.isNotEmpty) {
        final metric = metrics.first;
        final extract = metric.extractPath(0.0, metric.length * clamped);
        canvas.drawPath(extract, progressPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CoverProgressRingPainter oldDelegate) {
    return oldDelegate.positionGate != positionGate ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.borderRadius != borderRadius;
  }
}
