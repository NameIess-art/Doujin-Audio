part of 'audio_detail_sheet.dart';

class _SingleFileCoverPreview extends ConsumerStatefulWidget {
  const _SingleFileCoverPreview({required this.filePath});

  final String filePath;

  @override
  ConsumerState<_SingleFileCoverPreview> createState() =>
      _SingleFileCoverPreviewState();
}

class _SingleFileCoverPreviewState
    extends ConsumerState<_SingleFileCoverPreview> {
  Future<String?>? _coverFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _futureFor(
    LibraryFacade library,
    MusicTrack? track,
    int coverGeneration,
  ) {
    if (_lastTrackPath != widget.filePath ||
        _lastCoverGeneration != coverGeneration) {
      _lastTrackPath = widget.filePath;
      _lastCoverGeneration = coverGeneration;
      _coverFuture = _resolveSingleFileCover(library, track);
    }
    return _coverFuture!;
  }

  Future<String?> _resolveSingleFileCover(
    LibraryFacade library,
    MusicTrack? track,
  ) async {
    final embedded = await library.embeddedCoverPathFutureForFile(
      widget.filePath,
    );
    if (embedded != null && embedded.isNotEmpty) {
      return embedded;
    }
    return library.coverPathFutureForTrack(track, trackPath: widget.filePath);
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final track = ref.watch(libraryTrackProvider(widget.filePath));
    final coverGeneration = ref.watch(coverGenerationProvider);
    final initialPath =
        library.resolvedEmbeddedCoverPathForFile(widget.filePath) ??
        library.resolvedCoverPathForTrack(track, trackPath: widget.filePath);
    final coverFuture = _futureFor(library, track, coverGeneration);
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(coverImageResolutionProvider),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    return FutureBuilder<String?>(
      future: coverFuture,
      initialData: initialPath,
      builder: (context, snapshot) {
        final coverPath = snapshot.data;
        if (coverPath == null || coverPath.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          key: const ValueKey('audio_detail_single_cover_loaded'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: kStandardCoverAspectRatio,
                child: RetryingFileImage(
                  path: coverPath,
                  fit: BoxFit.cover,
                  cacheWidth: coverCacheWidth,
                  useDefaultCacheWidth: coverCacheWidth != null,
                  fallbackBuilder: (_) => const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
