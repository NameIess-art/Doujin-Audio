import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/top_page_header.dart';

@immutable
class WorkImageItem {
  const WorkImageItem({
    required this.name,
    required this.path,
    this.relativePath = '',
  });

  final String name;
  final String path;
  final String relativePath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkImageItem &&
          name == other.name &&
          path == other.path &&
          relativePath == other.relativePath;

  @override
  int get hashCode => Object.hash(name, path, relativePath);
}

class WorkImageViewerPage extends ConsumerStatefulWidget {
  const WorkImageViewerPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.onSetAsCover,
  });

  final List<WorkImageItem> images;
  final int initialIndex;
  final Future<void> Function(WorkImageItem image)? onSetAsCover;

  @override
  ConsumerState<WorkImageViewerPage> createState() =>
      _WorkImageViewerPageState();
}

class _WorkImageViewerPageState extends ConsumerState<WorkImageViewerPage> {
  late int _currentIndex = widget.initialIndex.clamp(
    0,
    widget.images.isEmpty ? 0 : widget.images.length - 1,
  );
  late final PageController _pageController = PageController(
    initialPage: _currentIndex,
  );
  bool _isSettingCover = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  void _goToPrevious() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _goToNext() {
    if (_currentIndex < widget.images.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _handleSetAsCover() async {
    final onSetAsCover = widget.onSetAsCover;
    if (onSetAsCover == null || _isSettingCover) return;
    final currentImage = widget.images[_currentIndex];
    setState(() {
      _isSettingCover = true;
    });
    try {
      await onSetAsCover(currentImage);
      if (!mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_cover_saved'),
        tone: AppFeedbackTone.success,
      );
    } catch (_) {
      if (!mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSettingCover = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Text(
            'No images',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    final currentImage = widget.images[_currentIndex];
    final hasPrevious = _currentIndex > 0;
    final hasNext = _currentIndex < widget.images.length - 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            itemCount: widget.images.length,
            itemBuilder: (context, index) {
              final img = widget.images[index];
              final imagePath = img.path.trim();
              final isRemoteImage = imagePath.startsWith('http://') ||
                  imagePath.startsWith('https://');
              return InteractiveViewer(
                maxScale: 4.0,
                child: Center(
                  child: isRemoteImage
                      ? RetryingNetworkImage(
                          url: imagePath,
                          fit: BoxFit.contain,
                          useDefaultCacheWidth: false,
                          fallbackBuilder: (_) => CoverFallbackArtwork(
                            seed: imagePath,
                            showIcon: true,
                            icon: Icons.broken_image_rounded,
                          ),
                        )
                      : LocalCoverImage(
                          path: imagePath,
                          seed: imagePath,
                          fit: BoxFit.contain,
                          useDefaultCacheWidth: false,
                          showIcon: true,
                          icon: Icons.broken_image_rounded,
                        ),
                ),
              );
            },
          ),
          // Floating Top Page Header
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              key: const ValueKey<String>('work_image_header'),
              icon: Icons.image_outlined,
              title: currentImage.name,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              trailing: widget.onSetAsCover != null
                  ? HeaderFloatingSurface(
                      padding: EdgeInsets.zero,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const ValueKey<String>(
                            'viewer_set_as_cover_button',
                          ),
                          borderRadius: BorderRadius.circular(19),
                          onTap: _isSettingCover ? null : _handleSetAsCover,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isSettingCover)
                                  const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.photo_size_select_actual_outlined,
                                    size: 18,
                                    color:
                                        Theme.of(context).colorScheme.onSurface,
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  ref
                                      .watch(appLanguageProviderInstanceProvider)
                                      .tr('audio_detail_set_cover'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          // Bottom-right switcher capsule
          if (widget.images.length > 1)
            Positioned(
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 20,
              child: HeaderFloatingSurface(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey<String>('image_viewer_prev_button'),
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      icon: const Icon(Icons.chevron_left_rounded),
                      tooltip: 'Previous',
                      onPressed: hasPrevious ? _goToPrevious : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        '${_currentIndex + 1} / ${widget.images.length}',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey<String>('image_viewer_next_button'),
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      icon: const Icon(Icons.chevron_right_rounded),
                      tooltip: 'Next',
                      onPressed: hasNext ? _goToNext : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
