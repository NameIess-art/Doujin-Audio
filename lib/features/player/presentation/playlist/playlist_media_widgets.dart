import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../../../core/widgets/duration_overlay.dart';
import '../../../../core/widgets/library_like_cards.dart';
import '../../../library/application/library_facade.dart';
import '../../../settings/application/settings_state.dart';
import '../../application/playback_session_snapshot.dart';
import '../session_video_surface.dart';
import '../session_video_viewport.dart';
import 'playlist_shared_helpers.dart';
import 'playlist_video_widgets.dart';

class SessionHeroArtwork extends ConsumerWidget {
  const SessionHeroArtwork({
    super.key,
    required this.session,
    required this.height,
    required this.track,
    required this.coverPathFuture,
  });

  final PlaybackSessionSnapshot session;
  final double height;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final sessionId = session.id;
    final cs = Theme.of(context).colorScheme;
    final allowVideoPlayback = ref.watch(
      settingsStateProvider.select((s) => s.value?.allowVideoPlayback ?? true),
    );
    final coverResolution = ref.watch(
      settingsStateProvider.select(
        (s) => s.value?.coverImageResolution ?? CoverImageResolution.balanced,
      ),
    );
    final initialCoverPath = library.resolvedPlaybackCoverPathForTrack(track);

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth;
        final coverCacheWidth = coverCacheWidthForLogicalSize(
          logicalWidth: displayWidth,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          resolution: coverResolution,
        );
        final coverPoster = Stack(
          fit: StackFit.expand,
          children: [
            TickerMode(
              // Do not freeze a cover image's loading fade mid-frame while the
              // detail route is being dragged.
              enabled: true,
              child: AsyncLocalCoverImage(
                future: coverPathFuture,
                requestKey: sessionId,
                initialPath: initialCoverPath,
                seed: track?.displayName ?? track?.path ?? sessionId,
                cacheWidth: coverCacheWidth,
                fit: BoxFit.cover,
                iconSize: 56,
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
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 56,
                  spreadRadius: 4,
                  offset: const Offset(0, 28),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: RepaintBoundary(
                child: SessionVideoViewport(
                  videoReady:
                      allowVideoPlayback &&
                      isSessionVideoReady(session, track),
                  surfaceBuilder: (_) =>
                      NativeSessionVideoSurface(sessionId: sessionId),
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
    this.duration,
    this.detailDuration,
  });

  final String sessionId;
  final MusicTrack? track;
  final String? coverPath;
  final int coverGeneration;
  final int? coverCacheWidth;
  final Duration? duration;
  final Duration? detailDuration;

  @override
  ConsumerState<SessionCoverThumbnail> createState() =>
      _SessionCoverThumbnailState();
}

class _SessionCoverThumbnailState
    extends ConsumerState<SessionCoverThumbnail> {
  Future<String?>? _coverFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _futureFor(LibraryFacade library) {
    final trackPath = widget.track?.path;
    if (_coverFuture == null ||
        _lastTrackPath != trackPath ||
        _lastCoverGeneration != widget.coverGeneration) {
      _lastTrackPath = trackPath;
      _lastCoverGeneration = widget.coverGeneration;
      _coverFuture = library.playbackCoverPathFutureForTrack(widget.track);
    }
    return _coverFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref
        .read(playbackFacadeProvider)
        .sessionSnapshotById(widget.sessionId);
    final library = ref.read(libraryFacadeProvider);
    final cover = AsyncLocalCoverImage(
      future: _futureFor(library),
      initialPath: widget.coverPath,
      retryFutureBuilder: () =>
          library.playbackCoverPathFutureForTrack(widget.track),
      seed: widget.track?.displayName ?? widget.sessionId,
      cacheWidth: widget.coverCacheWidth,
      useDefaultCacheWidth: widget.coverCacheWidth != null,
      fit: BoxFit.cover,
      displayMode: CoverImageDisplayMode.fill,
      compact: true,
      iconSize: 26,
    );
    return Stack(
      children: [
        SizedBox(
          key: ValueKey<String>('playlist_cover_${widget.sessionId}'),
          width: playlistCoverSize,
          height: playlistCoverSize,
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(
              LibraryLikeCardMetrics.coverRadius,
            ),
            clipBehavior: Clip.antiAlias,
            child: cover,
          ),
        ),
        Positioned(
          right: 4,
          bottom: 4,
          child: StreamBuilder<Duration?>(
            stream: session?.durationStream,
            initialData: session?.duration ?? widget.duration,
            builder: (context, snapshot) {
              final duration = widget.detailDuration ?? snapshot.data;
              if (duration == null || duration <= Duration.zero) {
                return const SizedBox.shrink();
              }
              return DurationOverlay(duration: duration);
            },
          ),
        ),
      ],
    );
  }
}

class SessionMetaChip extends StatelessWidget {
  const SessionMetaChip({
    super.key,
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurfaceVariant.withValues(alpha: 0.65);
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 11,
            color: fg,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
                color: fg,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
