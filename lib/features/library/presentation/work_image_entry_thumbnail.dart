import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/widgets/async_cover_image.dart';
import 'library_providers.dart';

class WorkImageEntryThumbnail extends StatelessWidget {
  const WorkImageEntryThumbnail({
    super.key,
    required this.path,
    required this.fallbackIcon,
  });

  static const double size = 32;
  static const double _radius = 6;

  final String path;
  final Widget fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final placeholder = Center(child: fallbackIcon);
    Widget buildPlaceholder(BuildContext _) => placeholder;
    final isRemote = PathMatcher.isRemoteUri(path);
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: isRemote
            ? _RemoteImageEntryThumbnail(
                url: path,
                placeholderBuilder: buildPlaceholder,
              )
            : _LocalImageEntryThumbnail(
                path: path,
                placeholderBuilder: buildPlaceholder,
              ),
      ),
    );
  }
}

class _LocalImageEntryThumbnail extends ConsumerWidget {
  const _LocalImageEntryThumbnail({
    required this.path,
    required this.placeholderBuilder,
  });

  final String path;
  final WidgetBuilder placeholderBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheWidth = coverThumbnailCacheWidth(
      logicalWidth: WorkImageEntryThumbnail.size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(coverImageResolutionProvider),
    );
    return RetryingFileImage(
      path: path,
      browseThumbnail: true,
      deferLoadDuringInteraction: true,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      useDefaultCacheWidth: false,
      retryDelay: const Duration(seconds: 5),
      maxRetryAttempts: 2,
      loadingBuilder: placeholderBuilder,
      fallbackBuilder: placeholderBuilder,
    );
  }
}

class _RemoteImageEntryThumbnail extends ConsumerStatefulWidget {
  const _RemoteImageEntryThumbnail({
    required this.url,
    required this.placeholderBuilder,
  });

  final String url;
  final WidgetBuilder placeholderBuilder;

  @override
  ConsumerState<_RemoteImageEntryThumbnail> createState() =>
      _RemoteImageEntryThumbnailState();
}

class _RemoteImageEntryThumbnailState
    extends ConsumerState<_RemoteImageEntryThumbnail> {
  Object? _requestKey;
  Future<String?>? _future;

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final (revision, resolved) = ref.watch(
      coverGenerationProvider.select(
        (_) => (
          library.coverArtworkCacheService.revisionForScope(widget.url),
          library.resolvedCoverPathForRemoteCover(widget.url),
        ),
      ),
    );
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final cacheWidth = coverThumbnailCacheWidth(
      logicalWidth: WorkImageEntryThumbnail.size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(coverImageResolutionProvider),
    );
    Future<String?> loadImage() =>
        coverUi.deferredRemoteCover(widget.url, context: context);
    final requestKey = (widget.url, resolved, revision);
    if (_requestKey != requestKey) {
      _requestKey = requestKey;
      _future = resolved != null
          ? SynchronousFuture<String?>(resolved)
          : loadImage();
    }
    return AsyncRemoteCoverImage(
      browseThumbnail: true,
      deferLoadDuringInteraction: true,
      onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
      url: widget.url,
      future: _future!,
      initialPath: resolved,
      retryFutureBuilder: loadImage,
      retryDelay: const Duration(seconds: 5),
      maxRetryAttempts: 2,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      useDefaultCacheWidth: false,
      loadingBuilder: widget.placeholderBuilder,
      fallbackBuilder: widget.placeholderBuilder,
    );
  }
}
