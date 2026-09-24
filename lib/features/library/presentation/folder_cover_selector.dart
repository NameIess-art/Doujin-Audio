import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/async_cover_image.dart';
import 'library_providers.dart';

class FolderCoverSelector extends ConsumerStatefulWidget {
  const FolderCoverSelector({
    super.key,
    required this.folderPath,
    this.initialCoverPath,
    this.onCoverSelected,
    this.compactNavigation = false,
    this.showLabel = true,
  });

  final String folderPath;
  final String? initialCoverPath;
  final ValueChanged<String>? onCoverSelected;
  final bool compactNavigation;
  final bool showLabel;

  @override
  ConsumerState<FolderCoverSelector> createState() =>
      _FolderCoverSelectorState();
}

class _FolderCoverSelectorState extends ConsumerState<FolderCoverSelector> {
  PageController? _pageController;
  List<String> _images = const <String>[];
  String? _currentCoverPath;
  bool _loading = true;
  bool _saving = false;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    final initialCoverPath = widget.initialCoverPath;
    if (initialCoverPath != null && initialCoverPath.isNotEmpty) {
      _images = <String>[initialCoverPath];
      _currentCoverPath = initialCoverPath;
      _loading = false;
      _pageController = PageController();
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final library = ref.read(libraryFacadeProvider);
      final currentCover = await library.coverPathFutureForFolder(
        widget.folderPath,
      );
      if (!mounted) return;
      if (_images.isEmpty && currentCover != null && currentCover.isNotEmpty) {
        setState(() {
          _images = <String>[currentCover];
          _currentCoverPath = currentCover;
          _pageController = PageController();
          _loading = false;
        });
      }
      final images = await library.discoverCoverCandidatesInFolder(
        widget.folderPath,
        selectedCoverPath: currentCover ?? widget.initialCoverPath,
      );
      if (!mounted) return;
      if (images.isEmpty) {
        setState(() {
          _images = const <String>[];
          _loading = false;
        });
        return;
      }
      var initialIndex = 0;
      if (currentCover != null) {
        final foundIndex = images.indexOf(currentCover);
        if (foundIndex >= 0) initialIndex = foundIndex;
      }
      final controller = PageController(initialPage: initialIndex);
      _pageController?.dispose();
      setState(() {
        _images = images;
        _currentCoverPath = currentCover ?? widget.initialCoverPath;
        _currentIndex = initialIndex;
        _pageController = controller;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  void _handlePageChanged(int index) {
    if (index < 0 || index >= _images.length || _currentIndex == index) return;
    setState(() => _currentIndex = index);
  }

  void _goToPrevious() => _goToPage(_currentIndex - 1);

  void _goToNext() => _goToPage(_currentIndex + 1);

  void _goToPage(int targetIndex) {
    if (_saving || targetIndex < 0 || targetIndex >= _images.length) return;
    setState(() => _currentIndex = targetIndex);
    final controller = _pageController;
    if (controller != null && controller.hasClients) {
      controller.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _handleWindowsWheel(PointerSignalEvent signal) {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        signal is! PointerScrollEvent ||
        signal.scrollDelta.dy == 0) {
      return;
    }
    final target = _currentIndex + (signal.scrollDelta.dy > 0 ? 1 : -1);
    if (_saving || target < 0 || target >= _images.length) return;
    GestureBinding.instance.pointerSignalResolver.register(
      signal,
      (_) => _goToPage(target),
    );
  }

  Widget _buildNavButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
    bool transparent = false,
  }) {
    return AnimatedOpacity(
      duration: kAppMotionFast,
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: transparent
            ? Colors.transparent
            : Colors.black.withValues(alpha: enabled ? 0.58 : 0.28),
        shape: const CircleBorder(),
        child: IconButton(
          key: key,
          tooltip: enabled ? tooltip : null,
          onPressed: enabled ? onPressed : null,
          color: Colors.white,
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          icon: Icon(icon),
        ),
      ),
    );
  }

  Future<void> _commitSelection() async {
    final index = _currentIndex;
    if (!mounted || index < 0 || index >= _images.length) return;
    setState(() => _saving = true);
    try {
      final selectedPath = _images[index];
      final storedCoverPath = await ref
          .read(libraryFacadeProvider)
          .setFolderManualCover(widget.folderPath, selectedPath);
      if (!mounted) return;
      setState(() => _currentCoverPath = selectedPath);
      widget.onCoverSelected?.call(storedCoverPath ?? selectedPath);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        ProviderScope.containerOf(context, listen: false)
            .read(appLanguageProviderInstanceProvider)
            .tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildCoverReveal(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      reverseDuration: kPlaceholderContentTransitionDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => buildAppScaleFadeTransition(
        context: context,
        animation: animation,
        child: child,
        beginScale: 0.96,
      ),
      child: child,
    );
  }

  Widget _buildCompactNavigation(AppLanguageProvider i18n) {
    return DecoratedBox(
      key: const ValueKey<String>('audio_detail_cover_navigation_capsule'),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNavButton(
            key: const ValueKey<String>('audio_detail_cover_prev_button'),
            icon: Icons.chevron_left_rounded,
            tooltip: i18n.tr('previous'),
            enabled: _currentIndex > 0 && !_saving,
            onPressed: _goToPrevious,
            transparent: true,
          ),
          Text(
            '${_currentIndex + 1}/${_images.length}',
            key: const ValueKey<String>('audio_detail_cover_position'),
            style: const TextStyle(
              color: Color(0xFFF8F5F7),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          _buildNavButton(
            key: const ValueKey<String>('audio_detail_cover_next_button'),
            icon: Icons.chevron_right_rounded,
            tooltip: i18n.tr('next'),
            enabled: _currentIndex < _images.length - 1 && !_saving,
            onPressed: _goToNext,
            transparent: true,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactCoverAction(AppLanguageProvider i18n) {
    final isCurrent = _currentCoverPath == _images[_currentIndex];
    return Material(
      key: const ValueKey<String>('audio_detail_cover_action_capsule'),
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: isCurrent || _saving ? null : _commitSelection,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_saving)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else
                  Icon(
                    isCurrent
                        ? Icons.check_circle_rounded
                        : Icons.image_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                const SizedBox(width: 6),
                Text(
                  i18n.tr(
                    isCurrent
                        ? 'audio_detail_current_cover'
                        : 'audio_detail_set_cover',
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    if (_loading) {
      return _buildCoverReveal(
        Column(
          key: const ValueKey('audio_detail_cover_loading'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showLabel) ...[
              Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
              const SizedBox(height: 10),
            ],
            Card(
              key: const ValueKey('audio_detail_cover_placeholder'),
              margin: EdgeInsets.zero,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: const AspectRatio(
                aspectRatio: kStandardCoverAspectRatio,
                child: SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
    }
    if (_images.isEmpty || _pageController == null) {
      return const SizedBox.shrink();
    }
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(coverImageResolutionProvider),
    );

    final content = Column(
      key: const ValueKey('audio_detail_cover_loaded'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showLabel) ...[
          Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
          const SizedBox(height: 10),
        ],
        ClipRRect(
          key: const ValueKey('audio_detail_cover_content'),
          borderRadius: BorderRadius.circular(16),
          child: Listener(
            onPointerSignal: _handleWindowsWheel,
            child: AspectRatio(
            aspectRatio: kStandardCoverAspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _images.length,
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (context, index) => RetryingFileImage(
                      path: _images[index],
                      fit: BoxFit.cover,
                      cacheWidth: coverCacheWidth,
                      useDefaultCacheWidth: coverCacheWidth != null,
                      fallbackBuilder: (_) =>
                          CoverFallbackArtwork(seed: _images[index]),
                    ),
                  ),
                ),
                if (widget.compactNavigation) ...[
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: _buildCompactCoverAction(i18n),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _buildCompactNavigation(i18n),
                  ),
                ] else ...[
                  if (defaultTargetPlatform == TargetPlatform.windows &&
                      _images.length > 1) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _buildNavButton(
                          key: const ValueKey<String>(
                            'audio_detail_cover_prev_button',
                          ),
                          icon: Icons.chevron_left_rounded,
                          tooltip: i18n.tr('previous'),
                          enabled: _currentIndex > 0 && !_saving,
                          onPressed: _goToPrevious,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _buildNavButton(
                          key: const ValueKey<String>(
                            'audio_detail_cover_next_button',
                          ),
                          icon: Icons.chevron_right_rounded,
                          tooltip: i18n.tr('next'),
                          enabled:
                              _currentIndex < _images.length - 1 && !_saving,
                          onPressed: _goToNext,
                        ),
                      ),
                    ),
                  ],
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _CoverCaption(
                          text: '${_currentIndex + 1} / ${_images.length}',
                        ),
                        _CoverCaption(
                          text: i18n.tr('audio_detail_cover_swipe_hint'),
                        ),
                      ],
                    ),
                  ),
                ],
                Positioned(
                  right: 12,
                  top: 12,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: _saving ? 1 : 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
        if (!widget.compactNavigation) ...[
          const SizedBox(height: 12),
          Center(
            child: _currentCoverPath == _images[_currentIndex]
                ? TextButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.check_circle_rounded),
                    label: Text(i18n.tr('audio_detail_current_cover')),
                  )
                : FilledButton.icon(
                    onPressed: _saving ? null : _commitSelection,
                    icon: const Icon(Icons.image_rounded),
                    label: Text(i18n.tr('audio_detail_set_cover')),
                  ),
          ),
        ],
      ],
    );
    return _buildCoverReveal(content);
  }
}

class _CoverCaption extends StatelessWidget {
  const _CoverCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xFFF8F5F7),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
