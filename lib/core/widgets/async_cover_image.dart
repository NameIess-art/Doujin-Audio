import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/music_track.dart' show MusicTrack;
import '../media/cover_image_resolution.dart';
import '../ui/visual_settings_providers.dart';
import '../ui/cover_image_retention.dart';
import '../ui/ui_interaction_coordinator.dart';
import '../ui/warmup_scheduler.dart';
import 'app_brand_icon.dart';
import 'app_transitions.dart';
import 'scroll_activity_gate.dart';

// Path resolution swaps immediately; the decoded frame owns the visible fade.
const Duration kCoverImageTransitionDuration = Duration.zero;
const double kStandardCoverAspectRatio = 4 / 3;

final _browseDecodes = WarmupScheduler(maxQueueSize: 64);
final _browseLoads = <ImageProvider<Object>, _BrowseThumbnailLoad>{};
int _browseLoadId = 0;

/// Visible thumbnails and idle prefetch share one first-frame decode budget.
Future<void> warmBrowseThumbnail(
  ImageProvider<Object> provider,
  ImageConfiguration configuration, {
  required bool Function() isActive,
  int priority = 1000,
}) {
  final existing = _browseLoads[provider];
  if (existing != null) {
    existing.requesters[isActive] = priority;
    return existing.result.future;
  }
  final load = _BrowseThumbnailLoad(provider, configuration, ++_browseLoadId);
  load.requesters[isActive] = priority;
  _browseLoads[provider] = load;
  unawaited(load.enqueue());
  return load.result.future;
}

class _BrowseThumbnailLoad {
  _BrowseThumbnailLoad(this.provider, this.configuration, this.id);

  final ImageProvider<Object> provider;
  final ImageConfiguration configuration;
  final int id;
  final result = Completer<void>();
  final requesters = <bool Function(), int>{};

  bool get active => requesters.keys.any((requester) => requester());
  int get priority => requesters.entries
      .where((entry) => entry.key())
      .fold(1 << 30, (value, entry) => math.min(value, entry.value));

  Future<void> enqueue() async {
    while (active) {
      final admitted = _browseDecodes.schedule(
        key: 'browse_decode_$id',
        priority: priority,
        priorityResolver: () => priority,
        generation: _browseDecodes.currentGeneration,
        onDiscard: finish,
        task: decode,
      );
      if (admitted) return;
      await _browseDecodes.capacityAvailable;
    }
    finish();
  }

  void finish() {
    if (identical(_browseLoads[provider], this)) _browseLoads.remove(provider);
    if (!result.isCompleted) result.complete();
  }

  Future<void> decode() async {
    if (!active) {
      finish();
      return;
    }
    final started = Completer<void>();
    // A completed decode can release its slot in a microtask. Admit the next
    // image through the frame budget rather than starting a burst of decodes.
    SchedulerBinding.instance.scheduleFrameCallback((_) => started.complete());
    SchedulerBinding.instance.scheduleFrame();
    await started.future;
    if (!active) {
      finish();
      return;
    }
    final ready = Completer<void>();
    ImageStream? stream;
    ImageStreamListener? listener;
    try {
      restoreRetainedCoverImage(provider);
      stream = provider.resolve(configuration);
      listener = ImageStreamListener(
        (info, _) {
          info.dispose();
          if (!ready.isCompleted) ready.complete();
        },
        onError: (Object error, StackTrace? stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      await ready.future;
      retainCoverImage(provider, configuration);
    } catch (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    } finally {
      if (stream != null && listener != null) stream.removeListener(listener);
      finish();
    }
  }
}

/// Keeps the cover's shadow outside its rounded image clip.
class CoverArtworkFrame extends StatelessWidget {
  const CoverArtworkFrame({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.clipBehavior = Clip.antiAlias,
    this.showShadow = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Clip clipBehavior;
  final bool showShadow;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: showShadow
          ? [
              BoxShadow(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0x70000000)
                    : const Color(0x3D000000),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ]
          : null,
    ),
    child: ClipRRect(
      borderRadius: borderRadius,
      clipBehavior: clipBehavior,
      child: child,
    ),
  );
}

// Full-size artwork follows the selected quality; thumbnails use display pixels.
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

int? coverCacheWidth({
  CoverImageResolution resolution = CoverImageResolution.balanced,
  int? cacheWidth,
  bool useDefaultCacheWidth = true,
}) {
  if (cacheWidth != null) return cacheWidth;
  if (!useDefaultCacheWidth) return null;
  return coverCacheWidthForResolution(resolution);
}

int coverThumbnailCacheWidth({
  required double logicalWidth,
  required double devicePixelRatio,
  required CoverImageResolution resolution,
}) {
  assert(logicalWidth.isFinite && logicalWidth > 0);
  assert(devicePixelRatio.isFinite && devicePixelRatio > 0);
  // Nearby layout sizes share a decode without undersampling the display.
  final width = math.max(
    64,
    (logicalWidth * devicePixelRatio / 64).ceil() * 64,
  );
  final maximumWidth = coverCacheWidthForResolution(resolution);
  return maximumWidth == null ? width : math.min(width, maximumWidth);
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
    this.duration = kCoverImageTransitionDuration,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
    this.browseThumbnail = false,
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
  final bool browseThumbnail;

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
      final initialPath = widget.initialPath;
      final hasInitialPath = initialPath != null && initialPath.isNotEmpty;
      if (hasInitialPath &&
          (!sameRequest ||
              oldWidget.initialPath != initialPath ||
              _resolvedPath == null)) {
        _resolvedPath = initialPath;
        _isResolved = true;
      }
      _bindFuture(
        widget.future,
        keepState:
            hasInitialPath ||
            (sameRequest && _resolvedPath != null && _resolvedPath!.isNotEmpty),
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
        keepState && _resolvedPath != null && _resolvedPath!.isNotEmpty;
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
    var bindingSynchronously = true;
    future
        .then((path) {
          if (!mounted || token != _token) return;
          void applyPath() {
            if (!mounted || token != _token) return;
            final hasResolvedPath = path != null && path.isNotEmpty;
            final nextPath = hasResolvedPath || !preserveResolvedPath
                ? path
                : _resolvedPath;
            if (!_isResolved || _resolvedPath != nextPath) {
              setState(() {
                _resolvedPath = nextPath;
                _isResolved = true;
              });
            }
            if (path == null || path.isEmpty) {
              _scheduleRetry(token);
            } else {
              _retryAttempt = 0;
            }
          }

          // A completed cache lookup must be visible on the first build, even
          // while navigation defers new artwork discovery and decoding.
          if (bindingSynchronously) {
            applyPath();
          } else {
            UiInteractionCoordinator.instance.scheduleCommit(
              key: _commitKey,
              priority: 20,
              allowDuringScroll: true,
              structural:
                  path != null && path.isNotEmpty && _resolvedPath != path,
              commit: applyPath,
            );
          }
        })
        .catchError((_) {
          if (!mounted || token != _token) return;
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _commitKey,
            priority: 20,
            allowDuringScroll: true,
            commit: () {
              if (!mounted || token != _token) return;
              if (!_isResolved ||
                  (!preserveResolvedPath && _resolvedPath != null)) {
                setState(() {
                  if (!preserveResolvedPath) _resolvedPath = null;
                  _isResolved = true;
                });
              }
              _scheduleRetry(token);
            },
          );
        });
    bindingSynchronously = false;
  }

  void _scheduleRetry(int token) {
    final retryFutureBuilder = widget.retryFutureBuilder;
    if (retryFutureBuilder == null || _retryTimer?.isActive == true) {
      return;
    }
    if (_retryAttempt >= widget.maxRetryAttempts) {
      return;
    }
    final nextAttempt = _retryAttempt + 1;
    _retryTimer = Timer(widget.retryDelay, () {
      if (!mounted || token != _token) return;
      void retry() {
        if (!mounted || token != _token) return;
        if (widget.browseThumbnail &&
            ScrollActivityGate.isFastScrollingWithoutDependencyOf(context)) {
          _retryTimer = null;
          _scheduleRetry(token);
          return;
        }
        _retryAttempt = nextAttempt;
        _bindFuture(retryFutureBuilder(), keepState: true, resetRetry: false);
      }

      UiInteractionCoordinator.instance.scheduleCommit(
        key: _retryCommitKey,
        priority: 20,
        allowDuringScroll: true,
        commit: retry,
      );
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

    final child = SizedBox.expand(
      key: ValueKey('$_resolvedPath$_isResolved'),
      child: content,
    );
    if (widget.duration == Duration.zero) return child;

    final duration =
        MediaQuery.disableAnimationsOf(context) ||
            ScrollActivityGate.isScrollingWithoutDependencyOf(context)
        ? Duration.zero
        : kAppFadeDuration;
    // Keep the image element mounted when scrolling changes the duration.
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: kAppFadeCurve,
      switchOutCurve: kAppFadeCurve,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: child,
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
    this.onImageError,
    this.path,
    this.cacheWidth,
    this.cacheHeight,
    this.useDefaultCacheWidth = true,
    this.browseThumbnail = false,
    this.deferLoadDuringInteraction = false,
    this.fit,
    this.alignment = Alignment.center,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
  });

  final String? path;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool useDefaultCacheWidth;
  final bool browseThumbnail;
  final bool deferLoadDuringInteraction;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;

  final ValueChanged<String>? onImageError;

  @override
  Widget build(BuildContext context) {
    final resolvedPath = path;
    if (resolvedPath == null || resolvedPath.isEmpty) {
      return const CoverFallbackArtwork();
    }
    return RetryingFileImage(
      path: resolvedPath,
      onImageError: onImageError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useDefaultCacheWidth: useDefaultCacheWidth,
      browseThumbnail: browseThumbnail,
      deferLoadDuringInteraction: deferLoadDuringInteraction,
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      fallbackBuilder: (_) => const CoverFallbackArtwork(),
    );
  }
}

class AsyncLocalCoverImage extends StatelessWidget {
  const AsyncLocalCoverImage({
    super.key,
    this.onImageError,
    required this.future,
    this.requestKey,
    this.initialPath,
    this.retryFutureBuilder,
    this.cacheWidth,
    this.cacheHeight,
    this.useDefaultCacheWidth = true,
    this.browseThumbnail = false,
    this.deferLoadDuringInteraction = false,
    this.fit,
    this.alignment = Alignment.center,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
    this.duration = kCoverImageTransitionDuration,
  });

  final Future<String?> future;
  final Object? requestKey;
  final String? initialPath;
  final Future<String?> Function()? retryFutureBuilder;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool useDefaultCacheWidth;
  final bool browseThumbnail;
  final bool deferLoadDuringInteraction;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;
  final Duration duration;

  Widget _cover(String? path) {
    return LocalCoverImage(
      path: path,
      onImageError: onImageError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useDefaultCacheWidth: useDefaultCacheWidth,
      browseThumbnail: browseThumbnail,
      deferLoadDuringInteraction: deferLoadDuringInteraction,
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
    );
  }

  final ValueChanged<String>? onImageError;

  @override
  Widget build(BuildContext context) {
    return AsyncCoverImage(
      future: future,
      browseThumbnail: browseThumbnail,
      requestKey: requestKey,
      initialPath: initialPath,
      retryFutureBuilder: retryFutureBuilder,
      duration: duration,
      fallbackBuilder: (_) => const CoverFallbackArtwork(),
      loadingBuilder: (_) =>
          const CoverLoadingArtwork(placeholder: CoverFallbackArtwork()),
      imageBuilder: (_, coverPath) => _cover(coverPath),
    );
  }
}

class CoverFallbackArtwork extends StatelessWidget {
  const CoverFallbackArtwork({super.key});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ColoredBox(
      color: primary.withValues(alpha: 0.08),
      child: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: AppBrandIcon(
            size: constraints.biggest.shortestSide,
            color: primary,
          ),
        ),
      ),
    );
  }
}

class AsyncRemoteCoverImage extends StatelessWidget {
  const AsyncRemoteCoverImage({
    super.key,
    this.onImageError,
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
    this.browseThumbnail = false,
    this.deferLoadDuringInteraction = false,
    this.filterQuality = FilterQuality.medium,
    this.duration = kCoverImageTransitionDuration,
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
  final bool browseThumbnail;
  final bool deferLoadDuringInteraction;
  final FilterQuality filterQuality;
  final Duration duration;
  final Duration retryDelay;
  final int maxRetryAttempts;

  final ValueChanged<String>? onImageError;

  @override
  Widget build(BuildContext context) {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      return fallbackBuilder(context);
    }
    return AsyncCoverImage(
      future: future,
      browseThumbnail: browseThumbnail,
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
          onImageError: onImageError,
          fit: fit,
          alignment: alignment,
          cacheWidth: cacheWidth,
          cacheHeight: cacheHeight,
          color: color,
          colorBlendMode: colorBlendMode,
          useDefaultCacheWidth: useDefaultCacheWidth,
          browseThumbnail: browseThumbnail,
          deferLoadDuringInteraction: deferLoadDuringInteraction,
          filterQuality: filterQuality,
          loadingBuilder: loadingBuilder,
          fallbackBuilder: fallbackBuilder,
        );
      },
    );
  }
}

class RetryingFileImage extends ConsumerWidget {
  const RetryingFileImage({
    super.key,
    this.onImageError,
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
    this.browseThumbnail = false,
    this.deferLoadDuringInteraction = false,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryAttempts = 12,
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
  final bool browseThumbnail;
  final bool deferLoadDuringInteraction;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final Duration retryDelay;
  final int maxRetryAttempts;

  final ValueChanged<String>? onImageError;

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
    return RetryingImage(
      retryKey: (path, effectiveCacheWidth, cacheHeight),
      onImageError: () => onImageError?.call(path),
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
      browseThumbnail: browseThumbnail,
      deferLoadDuringInteraction: deferLoadDuringInteraction,
      retainInImageCache:
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android,
    );
  }
}

class RetryingImage extends StatefulWidget {
  const RetryingImage({
    super.key,
    this.onImageError,
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
    this.browseThumbnail = false,
    this.deferLoadDuringInteraction = true,
    this.retainInImageCache = false,
  });

  final Object retryKey;
  final VoidCallback? onImageError;
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
  final bool browseThumbnail;
  final bool deferLoadDuringInteraction;
  final bool retainInImageCache;

  @override
  State<RetryingImage> createState() => _RetryingImageState();
}

class _RetryingImageState extends State<RetryingImage> {
  final UiInteractionCoordinator _interaction =
      UiInteractionCoordinator.instance;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  late bool _loadEnabled;
  Object? _cacheCheckKey;
  ImageProvider<Object>? _previewProvider;
  bool _hasDisplayedFrame = false;
  ValueListenable<bool>? _fastScrolling;
  ValueListenable<TickerModeData>? _tickerMode;
  ScrollPosition? _scrollPosition;
  Object _decodeToken = Object();
  bool _decodeQueued = false;
  bool _admissionScheduled = false;
  Object? _decodeError;
  String get _retryCommitKey =>
      'retrying_image_${identityHashCode(this)}_retry';
  String get _loadCommitKey => 'retrying_image_${identityHashCode(this)}_load';

  bool get _canStartLoad =>
      (!widget.deferLoadDuringInteraction ||
          !_interaction.isVisualUpdateDeferred) &&
      (!widget.browseThumbnail ||
          (!(_fastScrolling?.value ?? false) &&
              (_tickerMode?.value.enabled ?? true)));

  // Budget cold images even before the first gesture. Otherwise the initial
  // cache extent can start every decode together just as scrolling begins.
  // Decoded covers still bypass this queue in build.
  bool get _canLoadImmediately =>
      !widget.deferLoadDuringInteraction && !widget.browseThumbnail;

  @override
  void initState() {
    super.initState();
    _loadEnabled = _canLoadImmediately;
    _interaction.addListener(_scheduleLoadWhenAllowed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fastScrolling = widget.browseThumbnail
        ? ScrollActivityGate.fastScrollingListenableOf(context)
        : null;
    if (!identical(fastScrolling, _fastScrolling)) {
      _fastScrolling?.removeListener(_scheduleLoadWhenAllowed);
      _fastScrolling = fastScrolling;
      _fastScrolling?.addListener(_scheduleLoadWhenAllowed);
    }
    final tickerMode = widget.browseThumbnail
        ? TickerMode.getValuesNotifier(context)
        : null;
    if (!identical(tickerMode, _tickerMode)) {
      _tickerMode?.removeListener(_scheduleLoadWhenAllowed);
      _tickerMode = tickerMode;
      _tickerMode?.addListener(_scheduleLoadWhenAllowed);
    }
    final position = widget.browseThumbnail
        ? Scrollable.maybeOf(context)?.position
        : null;
    if (!identical(position, _scrollPosition)) {
      _scrollPosition?.removeListener(_scheduleLoadWhenAllowed);
      _scrollPosition = position;
      _scrollPosition?.addListener(_scheduleLoadWhenAllowed);
    }
    if (!_loadEnabled) _scheduleLoadWhenAllowed();
  }

  @override
  void didUpdateWidget(covariant RetryingImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retryKey != widget.retryKey) {
      _retryTimer?.cancel();
      _interaction.cancelCommit(_retryCommitKey);
      _interaction.cancelCommit(_loadCommitKey);
      _retryAttempt = 0;
      _loadEnabled = _canLoadImmediately;
      _cacheCheckKey = null;
      _previewProvider = null;
      _hasDisplayedFrame = false;
      _decodeToken = Object();
      _decodeQueued = false;
      _decodeError = null;
    }
    if (_canLoadImmediately) _loadEnabled = true;
    if (!_loadEnabled) _scheduleLoadWhenAllowed();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _interaction.removeListener(_scheduleLoadWhenAllowed);
    _interaction.cancelCommit(_retryCommitKey);
    _interaction.cancelCommit(_loadCommitKey);
    _fastScrolling?.removeListener(_scheduleLoadWhenAllowed);
    _tickerMode?.removeListener(_scheduleLoadWhenAllowed);
    _scrollPosition?.removeListener(_scheduleLoadWhenAllowed);
    super.dispose();
  }

  void _scheduleLoadWhenAllowed() {
    if (!mounted || !_canStartLoad || _loadEnabled) {
      return;
    }
    if (widget.browseThumbnail) {
      _scheduleBrowseDecode();
      return;
    }
    // Starting Image builds/decodes can exceed a short notification's budget.
    // Resume deferred covers one per frame, including during an active scroll.
    _interaction.scheduleCommit(
      key: _loadCommitKey,
      priority: 20,
      allowDuringScroll: true,
      structural: true,
      commit: () {
        if (mounted && !_loadEnabled && _canStartLoad) {
          setState(() => _loadEnabled = true);
        }
      },
    );
  }

  int? _visiblePriority() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final ancestor = RenderAbstractViewport.maybeOf(box);
    final viewport = ancestor is RenderBox ? ancestor as RenderBox : null;
    if (viewport == null || !viewport.hasSize) return -2000;
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(viewport),
      Offset.zero & box.size,
    );
    if (!bounds.overlaps(viewport.paintBounds)) return null;
    final distance = (bounds.center - viewport.paintBounds.center).distance;
    return -2000 +
        (distance * 1000 / viewport.paintBounds.longestSide).round().clamp(
          0,
          999,
        );
  }

  void _scheduleBrowseDecode() {
    if (_decodeQueued || _admissionScheduled || _decodeError != null) return;
    _admissionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _admissionScheduled = false;
      if (!mounted || _loadEnabled || !_canStartLoad) return;
      final priority = _visiblePriority();
      if (priority == null) return;
      final token = _decodeToken;
      final provider = widget.imageProviderBuilder();
      _decodeQueued = true;
      unawaited(
        warmBrowseThumbnail(
          provider,
          createLocalImageConfiguration(context),
          priority: priority,
          isActive: () =>
              mounted &&
              identical(token, _decodeToken) &&
              _canStartLoad &&
              _visiblePriority() != null,
        ).then(
          (_) {
            if (!mounted || !identical(token, _decodeToken)) return;
            _decodeQueued = false;
            // A request may have been discarded while its row left the view.
            _cacheCheckKey = null;
            setState(() {});
            _scheduleLoadWhenAllowed();
          },
          onError: (Object error, StackTrace stack) {
            if (!mounted || !identical(token, _decodeToken)) return;
            _decodeQueued = false;
            setState(() => _decodeError = error);
          },
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  ImageProvider<Object>? _cachedProviderForBuild(
    BuildContext context,
    ImageProvider<Object> provider,
  ) {
    final checkKey = (widget.retryKey, _retryAttempt);
    if (_cacheCheckKey == checkKey) return null;
    _cacheCheckKey = checkKey;

    restoreRetainedCoverImage(provider);
    final configuration = createLocalImageConfiguration(context);
    var callbackIsSynchronous = true;
    var cachedSynchronously = false;
    unawaited(
      provider.obtainKey(configuration).then<void>((key) {
        final status = PaintingBinding.instance.imageCache.statusForKey(key);
        // A pending decode is tracked too, but has no pixels ready to reuse.
        final hasDecodedImage = !status.pending && status.tracked;
        if (callbackIsSynchronous) {
          cachedSynchronously = hasDecodedImage;
          return;
        }
        if (!hasDecodedImage ||
            !mounted ||
            _loadEnabled ||
            _cacheCheckKey != checkKey) {
          return;
        }
        setState(() => _loadEnabled = true);
      }, onError: (Object error, StackTrace stackTrace) {}),
    );
    callbackIsSynchronous = false;
    if (!cachedSynchronously) return null;

    _loadEnabled = true;
    return provider;
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
        if (widget.browseThumbnail && !_canStartLoad) {
          _retryTimer = null;
          _scheduleRetry(provider);
          return;
        }
        if (widget.retainInImageCache) {
          releaseRetainedCoverImage(provider);
        }
        provider.evict().ignore();
        setState(() {
          _retryAttempt = nextAttempt;
          _hasDisplayedFrame = false;
          if (_previewProvider != null || widget.browseThumbnail) {
            _loadEnabled = false;
          }
          _decodeError = null;
          _decodeToken = Object();
          _decodeQueued = false;
          _cacheCheckKey = null;
        });
        if (_previewProvider != null || widget.browseThumbnail) {
          _scheduleLoadWhenAllowed();
        }
      }

      _interaction.scheduleCommit(
        key: _retryCommitKey,
        priority: 20,
        allowDuringScroll: true,
        commit: retry,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final requested = widget.imageProviderBuilder();
    if (_decodeError != null) {
      if (_retryAttempt == 0 && _retryTimer?.isActive != true) {
        widget.onImageError?.call();
      }
      _scheduleRetry(requested);
      final preview = _previewProvider;
      return preview == null
          ? widget.fallbackBuilder(context)
          : _image(
              preview,
              errorBuilder: (_, _, _) => widget.fallbackBuilder(context),
            );
    }
    ImageProvider<Object>? provider;
    if (!_loadEnabled) {
      provider = _cachedProviderForBuild(context, requested);
    }
    final retained = widget.retainInImageCache && _retryAttempt == 0
        ? retainedCoverImageFor(requested)
        : null;
    if (retained != null) {
      if (retained.isAdequate) {
        provider = retained.provider;
        if (provider != requested) _previewProvider ??= provider;
        _loadEnabled = true;
      } else if (_previewProvider == null && !_hasDisplayedFrame) {
        _previewProvider = retained.provider;
        _loadEnabled = false;
        _scheduleLoadWhenAllowed();
      }
    }
    if (_loadEnabled) _interaction.cancelCommit(_loadCommitKey);
    if (!_loadEnabled) provider ??= _previewProvider;
    if (!_loadEnabled && provider == null) {
      final loadingBuilder = widget.loadingBuilder;
      return loadingBuilder != null
          ? loadingBuilder(context)
          : CoverLoadingArtwork(placeholder: widget.fallbackBuilder(context));
    }
    final imageProvider = provider ?? requested;
    if (widget.retainInImageCache) restoreRetainedCoverImage(imageProvider);
    return _image(
      imageProvider,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          _hasDisplayedFrame = true;
          if (widget.retainInImageCache) {
            retainCoverImage(
              imageProvider,
              createLocalImageConfiguration(context),
            );
          }
        }
        // Image keeps its previous pixels during an upgrade (gaplessPlayback).
        // Do not cover those pixels with a placeholder while the new decode runs.
        if (wasSynchronouslyLoaded ||
            (_previewProvider != null && _hasDisplayedFrame)) {
          return child;
        }
        final loadingBuilder = widget.loadingBuilder;
        final placeholder = loadingBuilder != null
            ? loadingBuilder(context)
            : CoverLoadingArtwork(placeholder: widget.fallbackBuilder(context));
        return PlaceholderContentTransition(
          // A scroll-time fade would defer the next cover's load globally.
          duration: ScrollActivityGate.isScrollingWithoutDependencyOf(context)
              ? Duration.zero
              : kPlaceholderContentTransitionDuration,
          showPlaceholder: frame == null,
          placeholder: placeholder,
          content: child,
        );
      },
      errorBuilder: (context, error, stackTrace) {
        if (_retryAttempt == 0 && _retryTimer?.isActive != true) {
          widget.onImageError?.call();
        }
        _scheduleRetry(imageProvider);
        final preview = _previewProvider;
        if (preview != null && preview != imageProvider) {
          restoreRetainedCoverImage(preview);
          return _image(
            preview,
            errorBuilder: (context, error, stackTrace) =>
                widget.fallbackBuilder(context),
          );
        }
        return widget.fallbackBuilder(context);
      },
    );
  }

  Image _image(
    ImageProvider<Object> provider, {
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
  }) => Image(
    key: ValueKey('${widget.retryKey}#$_retryAttempt'),
    image: provider,
    fit: widget.fit ?? BoxFit.cover,
    alignment: widget.alignment,
    color: widget.color,
    colorBlendMode: widget.colorBlendMode,
    filterQuality: widget.filterQuality,
    gaplessPlayback: widget.gaplessPlayback,
    frameBuilder: frameBuilder,
    errorBuilder: errorBuilder,
  );
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
