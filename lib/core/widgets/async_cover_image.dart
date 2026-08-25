import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/music_track.dart' show MusicTrack;
import '../media/cover_image_resolution.dart';
import '../../app/presentation/app_presentation_providers.dart';
import '../ui/ui_interaction_coordinator.dart';
import 'app_transitions.dart';
import 'scroll_activity_gate.dart';

const Duration kCoverImageFadeDuration = kPlaceholderContentTransitionDuration;
const double kStandardCoverAspectRatio = 4 / 3;

int? coverCacheWidthForResolution(CoverImageResolution resolution) {
  switch (resolution) {
    case CoverImageResolution.memorySaver:
      return 300;
    case CoverImageResolution.balanced:
      return 600;
    case CoverImageResolution.high:
      return 900;
    case CoverImageResolution.ultraHigh:
      return 1200;
    case CoverImageResolution.original:
      return null;
  }
}

int coverCacheWidthForLogicalSize({
  required double logicalWidth,
  required double devicePixelRatio,
  required CoverImageResolution resolution,
}) {
  final requestedWidth = (logicalWidth * devicePixelRatio).ceil().clamp(
    1,
    1 << 20,
  );
  final resolutionLimit = coverCacheWidthForResolution(resolution);
  return resolutionLimit == null
      ? requestedWidth
      : requestedWidth.clamp(1, resolutionLimit);
}

int? coverCacheWidth({
  CoverImageResolution resolution = CoverImageResolution.balanced,
  int? cacheWidth,
  bool useDefaultCacheWidth = true,
}) {
  if (cacheWidth != null) return cacheWidth;
  if (!useDefaultCacheWidth) return null;
  return coverCacheWidthForResolution(resolution);
}

bool hasDisplayableCoverArtwork(MusicTrack? track, String? resolvedCoverPath) {
  if (resolvedCoverPath?.trim().isNotEmpty == true) return true;
  if (track?.manualCoverPath?.trim().isNotEmpty == true) return true;
  if (track?.coverCachePath?.trim().isNotEmpty == true) return true;
  if (track?.remoteCoverUrl?.trim().isNotEmpty == true) return true;
  return track?.isVideo == true;
}

bool shouldShowPlaylistCoverArtwork(
  MusicTrack? track,
  String? resolvedCoverPath,
) {
  if (track?.isSingle == true && track?.isVideo != true) {
    return hasDisplayableCoverArtwork(track, resolvedCoverPath);
  }
  return track != null;
}

class PulsingPlaceholder extends StatelessWidget {
  const PulsingPlaceholder({super.key, required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    final radius = borderRadius;
    if (radius != null) {
      result = ClipRRect(borderRadius: radius, child: result);
    }
    return result;
  }
}

class AsyncCoverImage extends StatefulWidget {
  const AsyncCoverImage({
    super.key,
    required this.future,
    this.requestKey,
    this.initialPath,
    required this.imageBuilder,
    required this.fallbackBuilder,
    this.retryFutureBuilder,
    this.loadingBuilder,
    this.duration = kCoverImageFadeDuration,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
    this.deferCommitDuringInteraction = false,
  });

  final Future<String?> future;
  final Object? requestKey;
  final String? initialPath;
  final Widget Function(BuildContext context, String path) imageBuilder;
  final WidgetBuilder fallbackBuilder;
  final Future<String?> Function()? retryFutureBuilder;
  final WidgetBuilder? loadingBuilder;
  final Duration duration;
  final Duration retryDelay;
  final int maxRetryAttempts;
  final bool deferCommitDuringInteraction;

  @override
  State<AsyncCoverImage> createState() => _AsyncCoverImageState();
}

class _AsyncCoverImageState extends State<AsyncCoverImage> {
  String? _resolvedPath;
  bool _isResolved = false;
  int _token = 0;
  int _retryAttempt = 0;
  Timer? _retryTimer;

  String get _commitKey => 'async_cover_${identityHashCode(this)}';
  String get _retryCommitKey => '${_commitKey}_retry';

  @override
  void initState() {
    super.initState();
    bool hasInitial = false;
    if (widget.initialPath != null && widget.initialPath!.isNotEmpty) {
      _resolvedPath = widget.initialPath;
      _isResolved = true;
      hasInitial = true;
    }
    _bindFuture(widget.future, keepState: hasInitial);
  }

  @override
  void didUpdateWidget(covariant AsyncCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.future, widget.future)) {
      _retryAttempt = 0;
      final sameRequest =
          widget.requestKey != null &&
          oldWidget.requestKey == widget.requestKey;
      _bindFuture(
        widget.future,
        keepState:
            sameRequest && _resolvedPath != null && _resolvedPath!.isNotEmpty,
      );
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    UiInteractionCoordinator.instance.cancelCommit(_retryCommitKey);
    super.dispose();
  }

  void _bindFuture(
    Future<String?> future, {
    bool keepState = false,
    bool resetRetry = true,
  }) {
    final token = ++_token;
    final preserveResolvedPath =
        keepState &&
        widget.retryFutureBuilder != null &&
        _resolvedPath != null &&
        _resolvedPath!.isNotEmpty;
    _retryTimer?.cancel();
    if (resetRetry) {
      _retryAttempt = 0;
    }
    if (!keepState) {
      if (mounted) {
        setState(() {
          _resolvedPath = null;
          _isResolved = false;
        });
      } else {
        _resolvedPath = null;
        _isResolved = false;
      }
    }
    future
        .then((path) {
          if (!mounted || token != _token) return;
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _commitKey,
            priority: 20,
            allowDuringInteraction: !widget.deferCommitDuringInteraction,
            commit: () {
              if (!mounted || token != _token) return;
              final hasResolvedPath = path != null && path.isNotEmpty;
              setState(() {
                if (hasResolvedPath || !preserveResolvedPath) {
                  _resolvedPath = path;
                }
                _isResolved = true;
              });
              if (path == null || path.isEmpty) {
                _scheduleRetry(token);
              } else {
                _retryAttempt = 0;
              }
            },
          );
        })
        .catchError((_) {
          if (!mounted || token != _token) return;
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _commitKey,
            priority: 20,
            allowDuringInteraction: !widget.deferCommitDuringInteraction,
            commit: () {
              if (!mounted || token != _token) return;
              setState(() {
                if (!preserveResolvedPath) _resolvedPath = null;
                _isResolved = true;
              });
              _scheduleRetry(token);
            },
          );
        });
  }

  void _scheduleRetry(int token) {
    final retryFutureBuilder = widget.retryFutureBuilder;
    if (retryFutureBuilder == null || _retryTimer?.isActive == true) {
      return;
    }
    if (_retryAttempt >= widget.maxRetryAttempts) {
      if (_resolvedPath != null && _resolvedPath!.isNotEmpty) {
        setState(() => _resolvedPath = null);
      }
      return;
    }
    final nextAttempt = _retryAttempt + 1;
    _retryTimer = Timer(widget.retryDelay, () {
      if (!mounted || token != _token) return;
      void retry() {
        if (!mounted || token != _token) return;
        _retryAttempt = nextAttempt;
        _bindFuture(retryFutureBuilder(), keepState: true, resetRetry: false);
      }

      if (widget.deferCommitDuringInteraction) {
        UiInteractionCoordinator.instance.scheduleCommit(
          key: _retryCommitKey,
          priority: 20,
          commit: retry,
        );
      } else {
        retry();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_resolvedPath != null && _resolvedPath!.isNotEmpty) {
      content = widget.imageBuilder(context, _resolvedPath!);
    } else if (!_isResolved) {
      final loadingBuilder = widget.loadingBuilder;
      content = loadingBuilder != null
          ? loadingBuilder(context)
          : CoverLoadingArtwork(placeholder: widget.fallbackBuilder(context));
    } else {
      content = widget.fallbackBuilder(context);
    }

    final duration = ScrollActivityGate.isScrollingWithoutDependencyOf(context)
        ? Duration.zero
        : widget.duration;
    if (duration == Duration.zero) {
      return SizedBox.expand(
        key: ValueKey('$_resolvedPath$_isResolved'),
        child: content,
      );
    }

    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeInOutSine,
      switchOutCurve: Curves.easeInOutSine,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: SizedBox.expand(
        key: ValueKey('$_resolvedPath$_isResolved'),
        child: content,
      ),
    );
  }
}

class CoverLoadingArtwork extends StatelessWidget {
  const CoverLoadingArtwork({super.key, required this.placeholder});

  final Widget placeholder;

  @override
  Widget build(BuildContext context) => placeholder;
}

class LocalCoverImage extends StatelessWidget {
  const LocalCoverImage({
    super.key,
    this.path,
    required this.seed,
    this.cacheWidth,
    this.cacheHeight,
    this.useDefaultCacheWidth = true,
    this.fit,
    this.alignment = Alignment.center,
    this.icon,
    this.compact = false,
    this.iconSize,
    this.showIcon = false,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
    this.deferRetryDuringInteraction = false,
    this.displayMode,
  });

  final String? path;
  final String seed;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool useDefaultCacheWidth;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final IconData? icon;
  final bool compact;
  final double? iconSize;
  final bool showIcon;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;
  final bool deferRetryDuringInteraction;
  final CoverImageDisplayMode? displayMode;

  Widget _fallback(BuildContext context, {bool? showIconOverride}) {
    return CoverFallbackArtwork(
      seed: seed,
      icon: icon,
      showIcon: showIconOverride ?? showIcon,
      compact: compact,
      iconSize: iconSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    final resolvedPath = path;
    if (resolvedPath == null || resolvedPath.isEmpty) {
      return _fallback(context);
    }
    return RetryingFileImage(
      path: resolvedPath,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useDefaultCacheWidth: useDefaultCacheWidth,
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      deferRetryDuringInteraction: deferRetryDuringInteraction,
      displayMode: displayMode,
      fallbackBuilder: (context) => _fallback(context),
    );
  }
}

class AsyncLocalCoverImage extends StatelessWidget {
  const AsyncLocalCoverImage({
    super.key,
    required this.future,
    this.requestKey,
    this.initialPath,
    this.retryFutureBuilder,
    required this.seed,
    this.cacheWidth,
    this.cacheHeight,
    this.useDefaultCacheWidth = true,
    this.fit,
    this.alignment = Alignment.center,
    this.icon,
    this.compact = false,
    this.iconSize,
    this.showIcon = false,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
    this.hideIconWhileLoading = true,
    this.duration = kCoverImageFadeDuration,
    this.deferCommitDuringInteraction = false,
    this.displayMode,
  });

  final Future<String?> future;
  final Object? requestKey;
  final String? initialPath;
  final Future<String?> Function()? retryFutureBuilder;
  final String seed;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool useDefaultCacheWidth;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final IconData? icon;
  final bool compact;
  final double? iconSize;
  final bool showIcon;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;
  final bool hideIconWhileLoading;
  final Duration duration;
  final bool deferCommitDuringInteraction;
  final CoverImageDisplayMode? displayMode;

  Widget _cover(BuildContext context, String? path, {required bool loading}) {
    return LocalCoverImage(
      path: path,
      seed: seed,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useDefaultCacheWidth: useDefaultCacheWidth,
      fit: fit,
      alignment: alignment,
      icon: icon,
      compact: compact,
      iconSize: iconSize,
      showIcon: loading && hideIconWhileLoading ? false : showIcon,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      deferRetryDuringInteraction: deferCommitDuringInteraction,
      displayMode: displayMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AsyncCoverImage(
      future: future,
      requestKey: requestKey,
      initialPath: initialPath,
      retryFutureBuilder: retryFutureBuilder,
      duration: duration,
      deferCommitDuringInteraction: deferCommitDuringInteraction,
      fallbackBuilder: (context) => _cover(context, null, loading: false),
      loadingBuilder: (context) => CoverLoadingArtwork(
        placeholder: _cover(context, null, loading: true),
      ),
      imageBuilder: (context, coverPath) =>
          _cover(context, coverPath, loading: false),
    );
  }
}

class CoverFallbackArtwork extends StatelessWidget {
  const CoverFallbackArtwork({
    super.key,
    this.seed,
    this.icon,
    this.showIcon = false,
    this.iconSize,
    this.compact = false,
  });

  final String? seed;
  final IconData? icon;
  final bool showIcon;
  final double? iconSize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normalizedSeed = seed?.trim();
    final hash =
        (normalizedSeed == null || normalizedSeed.isEmpty
                ? 'doujin-audio'
                : normalizedSeed)
            .hashCode
            .abs();
    final colorPairs = isDark
        ? const [
            (Color(0xFF3C1825), Color(0xFF171A2D)),
            (Color(0xFF24314B), Color(0xFF171827)),
            (Color(0xFF2F2544), Color(0xFF161923)),
            (Color(0xFF203834), Color(0xFF161824)),
          ]
        : const [
            (Color(0xFFF3D9E0), Color(0xFFE5EAF4)),
            (Color(0xFFE2EAF8), Color(0xFFF3E4EA)),
            (Color(0xFFEAE2F4), Color(0xFFE8EEF2)),
            (Color(0xFFE1F0EA), Color(0xFFF1E6EA)),
          ];
    final pair = colorPairs[hash % colorPairs.length];
    final foreground = isDark
        ? Colors.white.withValues(alpha: 0.82)
        : cs.onSurface.withValues(alpha: 0.66);
    final accent = Color.lerp(cs.primary, pair.$1, isDark ? 0.3 : 0.16)!;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [pair.$1, pair.$2],
        ),
      ),
      child: CustomPaint(
        painter: _CoverFallbackTexturePainter(
          accent: accent.withValues(alpha: isDark ? 0.18 : 0.16),
          line: foreground.withValues(alpha: isDark ? 0.08 : 0.12),
          seed: hash,
        ),
        child: Center(
          child: AnimatedOpacity(
            opacity: showIcon ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Icon(
              icon ?? Icons.graphic_eq_rounded,
              size: iconSize ?? (compact ? 24 : 34),
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}

class _CoverFallbackTexturePainter extends CustomPainter {
  const _CoverFallbackTexturePainter({
    required this.accent,
    required this.line,
    required this.seed,
  });

  final Color accent;
  final Color line;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = size.shortestSide;
    if (shortest <= 0) return;

    final accentPaint = Paint()
      ..color = accent
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * (seed.isEven ? 0.22 : 0.78), size.height * 0.18),
      shortest * 0.42,
      accentPaint,
    );
    canvas.drawCircle(
      Offset(size.width * (seed.isEven ? 0.84 : 0.16), size.height * 0.92),
      shortest * 0.52,
      accentPaint..color = accent.withValues(alpha: accent.a * 0.7),
    );

    final linePaint = Paint()
      ..color = line
      ..strokeWidth = (shortest * 0.018).clamp(1.0, 2.4)
      ..strokeCap = StrokeCap.round;
    final startX = size.width * 0.18;
    final endX = size.width * 0.82;
    for (var i = 0; i < 4; i++) {
      final y = size.height * (0.36 + i * 0.1);
      final delta = ((seed >> i) & 1) == 0 ? -1.0 : 1.0;
      canvas.drawLine(
        Offset(startX + shortest * 0.03 * delta, y),
        Offset(endX - shortest * 0.04 * delta, y + shortest * 0.02 * delta),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CoverFallbackTexturePainter oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.line != line ||
        oldDelegate.seed != seed;
  }
}

class RetryingNetworkImage extends ConsumerWidget {
  const RetryingNetworkImage({
    super.key,
    required this.url,
    required this.fallbackBuilder,
    this.loadingBuilder,
    this.fit,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cacheHeight,
    this.color,
    this.colorBlendMode,
    this.useDefaultCacheWidth = true,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
  });

  final String url;
  final WidgetBuilder fallbackBuilder;
  final WidgetBuilder? loadingBuilder;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final Color? color;
  final BlendMode? colorBlendMode;
  final bool useDefaultCacheWidth;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final Duration retryDelay;
  final int maxRetryAttempts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      return fallbackBuilder(context);
    }
    final effectiveCacheWidth = coverCacheWidth(
      resolution: ref.watch(coverImageResolutionProvider),
      cacheWidth: cacheWidth,
      useDefaultCacheWidth: useDefaultCacheWidth,
    );
    final displayMode = ref.watch(coverImageDisplayModeProvider);
    return RetryingImage(
      retryKey: trimmedUrl,
      imageProviderBuilder: () => ResizeImage.resizeIfNeeded(
        effectiveCacheWidth,
        cacheHeight,
        NetworkImage(trimmedUrl),
      ),
      fallbackBuilder: fallbackBuilder,
      loadingBuilder: loadingBuilder,
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      gaplessPlayback: gaplessPlayback,
      retryDelay: retryDelay,
      maxRetryAttempts: maxRetryAttempts,
      displayMode: displayMode,
    );
  }
}

class AsyncRemoteCoverImage extends StatelessWidget {
  const AsyncRemoteCoverImage({
    super.key,
    required this.url,
    required this.future,
    this.initialPath,
    required this.fallbackBuilder,
    this.retryFutureBuilder,
    this.loadingBuilder,
    this.fit,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cacheHeight,
    this.color,
    this.colorBlendMode,
    this.useDefaultCacheWidth = true,
    this.filterQuality = FilterQuality.medium,
    this.duration = kCoverImageFadeDuration,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
  });

  final String url;
  final Future<String?> future;
  final String? initialPath;
  final WidgetBuilder fallbackBuilder;
  final Future<String?> Function()? retryFutureBuilder;
  final WidgetBuilder? loadingBuilder;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final Color? color;
  final BlendMode? colorBlendMode;
  final bool useDefaultCacheWidth;
  final FilterQuality filterQuality;
  final Duration duration;
  final Duration retryDelay;
  final int maxRetryAttempts;

  @override
  Widget build(BuildContext context) {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      return fallbackBuilder(context);
    }
    return AsyncCoverImage(
      future: future,
      requestKey: trimmedUrl,
      initialPath: initialPath,
      retryFutureBuilder: retryFutureBuilder,
      retryDelay: retryDelay,
      maxRetryAttempts: maxRetryAttempts,
      loadingBuilder: loadingBuilder,
      fallbackBuilder: fallbackBuilder,
      duration: duration,
      imageBuilder: (context, coverPath) {
        return RetryingFileImage(
          path: coverPath,
          fit: fit,
          alignment: alignment,
          cacheWidth: cacheWidth,
          cacheHeight: cacheHeight,
          color: color,
          colorBlendMode: colorBlendMode,
          useDefaultCacheWidth: useDefaultCacheWidth,
          filterQuality: filterQuality,
          fallbackBuilder: fallbackBuilder,
        );
      },
    );
  }
}

class RetryingFileImage extends ConsumerWidget {
  const RetryingFileImage({
    super.key,
    required this.path,
    required this.fallbackBuilder,
    this.loadingBuilder,
    this.fit,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cacheHeight,
    this.color,
    this.colorBlendMode,
    this.useDefaultCacheWidth = true,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
    this.deferRetryDuringInteraction = false,
    this.displayMode,
  });

  final String path;
  final WidgetBuilder fallbackBuilder;
  final WidgetBuilder? loadingBuilder;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final Color? color;
  final BlendMode? colorBlendMode;
  final bool useDefaultCacheWidth;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final Duration retryDelay;
  final int maxRetryAttempts;
  final bool deferRetryDuringInteraction;
  final CoverImageDisplayMode? displayMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (path.isEmpty) {
      return fallbackBuilder(context);
    }
    final effectiveCacheWidth = coverCacheWidth(
      resolution: ref.watch(coverImageResolutionProvider),
      cacheWidth: cacheWidth,
      useDefaultCacheWidth: useDefaultCacheWidth,
    );
    final CoverImageDisplayMode effectiveDisplayMode =
        displayMode ?? ref.watch(coverImageDisplayModeProvider);
    return RetryingImage(
      retryKey: path,
      imageProviderBuilder: () => resizeFileImageIfNeeded(
        path: path,
        cacheWidth: effectiveCacheWidth,
        cacheHeight: cacheHeight,
        useDefaultCacheWidth: false,
      ),
      fallbackBuilder: fallbackBuilder,
      loadingBuilder: loadingBuilder,
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      gaplessPlayback: gaplessPlayback,
      retryDelay: retryDelay,
      maxRetryAttempts: maxRetryAttempts,
      deferRetryDuringInteraction: deferRetryDuringInteraction,
      displayMode: effectiveDisplayMode,
    );
  }
}

class RetryingImage extends StatefulWidget {
  const RetryingImage({
    super.key,
    required this.retryKey,
    required this.imageProviderBuilder,
    required this.fallbackBuilder,
    this.loadingBuilder,
    this.fit,
    this.alignment = Alignment.center,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
    this.deferRetryDuringInteraction = false,
    this.displayMode = CoverImageDisplayMode.fill,
  });

  final Object retryKey;
  final ImageProvider<Object> Function() imageProviderBuilder;
  final WidgetBuilder fallbackBuilder;
  final WidgetBuilder? loadingBuilder;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final Duration retryDelay;
  final int maxRetryAttempts;
  final bool deferRetryDuringInteraction;
  final CoverImageDisplayMode displayMode;

  @override
  State<RetryingImage> createState() => _RetryingImageState();
}

class _RetryingImageState extends State<RetryingImage> {
  int _retryAttempt = 0;
  Timer? _retryTimer;
  String get _retryCommitKey =>
      'retrying_image_${identityHashCode(this)}_retry';

  @override
  void didUpdateWidget(covariant RetryingImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retryKey != widget.retryKey) {
      _retryTimer?.cancel();
      UiInteractionCoordinator.instance.cancelCommit(_retryCommitKey);
      _retryAttempt = 0;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_retryCommitKey);
    super.dispose();
  }

  void _scheduleRetry(ImageProvider<Object> provider) {
    if (_retryAttempt >= widget.maxRetryAttempts ||
        _retryTimer?.isActive == true) {
      return;
    }
    final nextAttempt = _retryAttempt + 1;
    _retryTimer = Timer(widget.retryDelay, () {
      if (!mounted) return;
      void retry() {
        if (!mounted) return;
        provider.evict().ignore();
        setState(() {
          _retryAttempt = nextAttempt;
        });
      }

      if (widget.deferRetryDuringInteraction) {
        UiInteractionCoordinator.instance.scheduleCommit(
          key: _retryCommitKey,
          priority: 20,
          commit: retry,
        );
      } else {
        retry();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.imageProviderBuilder();
    Widget image({required BoxFit? fit, required bool primary}) {
      return Image(
        key: ValueKey(
          '${widget.retryKey}#$_retryAttempt${primary ? '' : '#backdrop'}',
        ),
        image: provider,
        fit: fit,
        alignment: widget.alignment,
        color: widget.color,
        colorBlendMode: widget.colorBlendMode,
        filterQuality: widget.filterQuality,
        gaplessPlayback: widget.gaplessPlayback,
        frameBuilder: primary
            ? (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) return child;
                final loadingBuilder = widget.loadingBuilder;
                return PlaceholderContentTransition(
                  showPlaceholder: frame == null,
                  placeholder: loadingBuilder != null
                      ? loadingBuilder(context)
                      : CoverLoadingArtwork(
                          placeholder: widget.fallbackBuilder(context),
                        ),
                  content: child,
                );
              }
            : null,
        errorBuilder: primary
            ? (context, error, stackTrace) {
                _scheduleRetry(provider);
                return widget.fallbackBuilder(context);
              }
            : (context, error, stackTrace) => const SizedBox.expand(),
      );
    }

    switch (widget.displayMode) {
      case CoverImageDisplayMode.fill:
        return image(fit: widget.fit, primary: true);
      case CoverImageDisplayMode.stretch:
        return image(fit: BoxFit.fill, primary: true);
      case CoverImageDisplayMode.tile:
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Transform.scale(
                  scale: 1.08,
                  child: image(fit: BoxFit.cover, primary: false),
                ),
              ),
            ),
            image(fit: BoxFit.contain, primary: true),
          ],
        );
    }
  }
}

ImageProvider<Object> resizeFileImageIfNeeded({
  required String path,
  int? cacheWidth,
  int? cacheHeight,
  bool useDefaultCacheWidth = true,
}) {
  final provider = FileImage(File(path));
  return ResizeImage.resizeIfNeeded(
    cacheWidth ??
        (useDefaultCacheWidth
            ? coverCacheWidthForResolution(CoverImageResolution.balanced)
            : null),
    cacheHeight,
    provider,
  );
}
