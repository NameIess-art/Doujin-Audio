part of 'asmr_tab.dart';

class _AsmrWorkCover extends ConsumerStatefulWidget {
  const _AsmrWorkCover({
    required this.workKey,
    required this.url,
    required this.width,
    this.isSelected = false,
    this.duration,
    this.listenStatus,
  });

  final String url;
  final String workKey;
  final double width;
  final bool isSelected;
  final Duration? duration;
  final WorkListenStatus? listenStatus;

  @override
  ConsumerState<_AsmrWorkCover> createState() => _AsmrWorkCoverState();
}

class _AsmrWorkCoverState extends ConsumerState<_AsmrWorkCover> {
  Future<String?>? _coverPathFuture;
  String? _lastUrl;
  Object? _lastCoverRevision;
  LibraryCoverUiController? _lastCoverUi;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    String url,
    Object coverRevision,
  ) {
    if (_lastUrl != url ||
        _lastCoverRevision != coverRevision ||
        !identical(_lastCoverUi, coverUi)) {
      _lastUrl = url;
      _lastCoverRevision = coverRevision;
      _lastCoverUi = coverUi;
      _coverPathFuture = coverUi.deferredRemoteCover(url, context: context);
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = width / kStandardCoverAspectRatio;
    final url = widget.url.trim();
    final coverResolution = ref.watch(coverImageResolutionProvider);
    final coverCacheWidth = coverThumbnailCacheWidth(
      logicalWidth: width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: coverResolution,
    );
    final library = ref.read(libraryFacadeProvider);
    final (coverRevision, resolvedPath) = ref.watch(
      coverGenerationProvider.select(
        (_) => (
          library.coverArtworkCacheService.revisionForScope(url),
          library.resolvedCoverPathForRemoteCover(url),
        ),
      ),
    );
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverFuture = url.isEmpty
        ? null
        : _coverFutureFor(coverUi, url, (coverRevision, resolvedPath));
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: width,
            height: height,
            child: CoverArtworkFrame(
              clipBehavior: Clip.hardEdge,
              showShadow: false,
              showBorder: true,
              borderRadius: BorderRadius.circular(
                LibraryLikeCardMetrics.coverRadius,
              ),
              child: Stack(
                children: [
                  SizedBox(
                    width: width,
                    height: height,
                    child: url.isEmpty
                        ? const CoverFallbackArtwork()
                        : AsyncRemoteCoverImage(
                            browseThumbnail: true,
                            deferLoadDuringInteraction: true,
                            onImageError: library
                                .coverArtworkCacheService
                                .reportArtworkReadFailure,
                            url: url,
                            future: coverFuture!,
                            initialPath: resolvedPath,
                            retryFutureBuilder: () => coverUi
                                .deferredRemoteCover(url, context: context),
                            retryDelay: const Duration(seconds: 5),
                            maxRetryAttempts: 2,
                            fit: BoxFit.cover,
                            cacheWidth: coverCacheWidth,
                            useDefaultCacheWidth: false,
                            loadingBuilder: (_) => const CoverLoadingArtwork(
                              placeholder: CoverFallbackArtwork(),
                            ),
                            fallbackBuilder: (_) =>
                                const CoverFallbackArtwork(),
                          ),
                  ),
                  if (widget.listenStatus case final status?)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: WorkListenStatusBadge(
                        status: status,
                        label: ref
                            .read(appLanguageProviderInstanceProvider)
                            .tr(workListenStatusTranslationKey(status)),
                      ),
                    ),
                  if (widget.duration != null &&
                      widget.duration! > Duration.zero)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: DurationOverlay(duration: widget.duration!),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: SelectionCheckmark(
              indicatorKey: ValueKey<String>(
                'asmr_selection_indicator_${widget.workKey}',
              ),
              isSelected: widget.isSelected,
            ),
          ),
        ],
      ),
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  final thumbnail = work.thumbnailUrl.trim();
  return thumbnail.isNotEmpty ? thumbnail : work.preferredCoverUrl;
}
