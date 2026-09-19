import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';

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
              return InteractiveViewer(
                maxScale: 4.0,
                child: Center(
                  child: LocalCoverImage(
                    path: img.path,
                    seed: img.path,
                    fit: BoxFit.contain,
                    useDefaultCacheWidth: false,
                    showIcon: true,
                    icon: Icons.broken_image_rounded,
                  ),
                ),
              );
            },
          ),
          // Top bar overlay
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            currentImage.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${_currentIndex + 1} / ${widget.images.length}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onSetAsCover != null)
                      TextButton.icon(
                        key: const ValueKey<String>('viewer_set_as_cover_button'),
                        onPressed: _isSettingCover ? null : _handleSetAsCover,
                        icon: _isSettingCover
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.photo_size_select_actual_outlined,
                                color: Colors.white,
                                size: 18,
                              ),
                        label: Text(
                          ref
                              .watch(appLanguageProviderInstanceProvider)
                              .tr('audio_detail_set_cover'),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white12,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Left navigation button
          if (hasPrevious)
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    key: const ValueKey<String>('image_viewer_prev_button'),
                    icon: const Icon(
                      Icons.chevron_left_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                    onPressed: _goToPrevious,
                    tooltip: 'Previous',
                  ),
                ),
              ),
            ),
          // Right navigation button
          if (hasNext)
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    key: const ValueKey<String>('image_viewer_next_button'),
                    icon: const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                    onPressed: _goToNext,
                    tooltip: 'Next',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
