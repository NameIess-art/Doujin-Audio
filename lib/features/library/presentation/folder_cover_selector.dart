import 'dart:async';

import '../../../core/widgets/app_buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
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

class _FolderCoverSelectorState extends ConsumerState<FolderCoverSelector>
    with AutomaticKeepAliveClientMixin {
  static const int _loopPageSeed = 100000;

  PageController? _pageController;
  List<String> _images = const <String>[];
  String? _currentCoverPath;
  bool _loading = true;
  bool _saving = false;
  int _currentIndex = 0;
  int? _targetVirtualPage;
  String get _loadCommitKey => 'folder_cover_${identityHashCode(this)}_load';

  // Recreating a missing cover while scrolling inserts a temporary placeholder
  // and changes the form's scroll extent before discovery removes it again.
  @override
  bool get wantKeepAlive => true;

  static int _pageForIndex(int index, int length) {
    if (length <= 1) return index;
    final base = (_loopPageSeed ~/ length) * length;
    return base + index;
  }

  static int _indexForPage(int page, int length) {
    if (length <= 1) return 0;
    final remainder = page % length;
    return remainder < 0 ? remainder + length : remainder;
  }

  static bool _sameOptionalPath(String? a, String? b) =>
      a == b || (a != null && b != null && PathMatcher.equalsNormalized(a, b));

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
    // Candidate discovery hashes images and extracts track artwork. Keep that
    // work out of route transitions while showing the indexed cover immediately.
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _loadCommitKey,
      commit: () {
        if (mounted) unawaited(_load());
      },
    );
  }

  @override
  void didUpdateWidget(covariant FolderCoverSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final folderChanged = !PathMatcher.equalsNormalized(
      oldWidget.folderPath,
      widget.folderPath,
    );
    final initialCoverChanged = !_sameOptionalPath(
      oldWidget.initialCoverPath,
      widget.initialCoverPath,
    );
    if (folderChanged) {
      UiInteractionCoordinator.instance.cancelCommit(_loadCommitKey);
      _pageController?.dispose();
      _pageController = null;
      _targetVirtualPage = null;
      _currentIndex = 0;
      _saving = false;
      final initialCoverPath = widget.initialCoverPath;
      if (initialCoverPath != null && initialCoverPath.isNotEmpty) {
        _images = <String>[initialCoverPath];
        _currentCoverPath = initialCoverPath;
        _loading = false;
        _pageController = PageController();
      } else {
        _images = const <String>[];
        _currentCoverPath = null;
        _loading = true;
      }
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _loadCommitKey,
        commit: () {
          if (mounted) unawaited(_load());
        },
      );
      return;
    }
    if (initialCoverChanged) {
      final initialCoverPath = widget.initialCoverPath;
      if (initialCoverPath != null &&
          initialCoverPath.isNotEmpty &&
          !_sameOptionalPath(_currentCoverPath, initialCoverPath)) {
        _currentCoverPath = initialCoverPath;
        final foundIndex = _images.indexWhere(
          (path) => PathMatcher.equalsNormalized(path, initialCoverPath),
        );
        if (foundIndex >= 0 && foundIndex != _currentIndex) {
          _currentIndex = foundIndex;
          _targetVirtualPage = null;
          final controller = _pageController;
          if (controller != null && controller.hasClients) {
            controller.jumpToPage(_pageForIndex(foundIndex, _images.length));
          }
        } else if (foundIndex < 0) {
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _loadCommitKey,
            commit: () {
              if (mounted) unawaited(_load());
            },
          );
        }
      }
    }
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_loadCommitKey);
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final requestedFolderPath = widget.folderPath;
    try {
      final library = ref.read(libraryFacadeProvider);
      final currentCover = await library.coverPathFutureForFolder(
        requestedFolderPath,
      );
      if (!mounted ||
          !PathMatcher.equalsNormalized(
            widget.folderPath,
            requestedFolderPath,
          )) {
        return;
      }
      if (_images.isEmpty && currentCover != null && currentCover.isNotEmpty) {
        setState(() {
          _images = <String>[currentCover];
          _currentCoverPath = currentCover;
          _pageController = PageController();
          _loading = false;
        });
      }
      final images = await library.discoverCoverCandidatesInFolder(
        requestedFolderPath,
        selectedCoverPath: currentCover ?? widget.initialCoverPath,
        isCancelled: () =>
            !mounted ||
            !PathMatcher.equalsNormalized(
              widget.folderPath,
              requestedFolderPath,
            ),
      );
      if (!mounted ||
          !PathMatcher.equalsNormalized(
            widget.folderPath,
            requestedFolderPath,
          )) {
        return;
      }
      if (images.isEmpty) {
        setState(() {
          _images = const <String>[];
          _loading = false;
        });
        return;
      }
      var initialIndex = 0;
      if (currentCover != null) {
        final foundIndex = images.indexWhere(
          (path) => PathMatcher.equalsNormalized(path, currentCover),
        );
        if (foundIndex >= 0) initialIndex = foundIndex;
      }
      final initialPage = _pageForIndex(initialIndex, images.length);
      final controller = PageController(initialPage: initialPage);
      _pageController?.dispose();
      setState(() {
        _images = images;
        _currentCoverPath = currentCover ?? widget.initialCoverPath;
        _currentIndex = initialIndex;
        _targetVirtualPage = null;
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

  void _handlePageChanged(int page) {
    if (_images.isEmpty) return;
    // Intermediate pages must not replace the target of rapid button/wheel input.
    if (_targetVirtualPage != null && page != _targetVirtualPage) return;
    final index = _indexForPage(page, _images.length);
    if (_currentIndex == index) return;
    setState(() => _currentIndex = index);
  }

  void _goToPrevious() => _goToDelta(-1);

  void _goToNext() => _goToDelta(1);

  void _goToDelta(int delta) {
    if (_saving || _images.length <= 1) return;
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    final current =
        controller.page ??
        _pageForIndex(_currentIndex, _images.length).toDouble();
    final basePage = _targetVirtualPage ?? current.round();
    final targetPage = basePage + delta;
    _targetVirtualPage = targetPage;
    setState(() => _currentIndex = _indexForPage(targetPage, _images.length));
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    if (duration == Duration.zero) {
      controller.jumpToPage(targetPage);
    } else {
      controller.animateToPage(
        targetPage,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  bool _handlePageScroll(ScrollNotification notification) {
    final controller = _pageController;
    if (notification.depth != 0 ||
        controller == null ||
        !controller.hasClients) {
      return false;
    }
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        notification is ScrollEndNotification) {
      final page = controller.page;
      if (page == null) return false;
      _targetVirtualPage = null;
      _handlePageChanged(page.round());
    }
    return false;
  }

  void _handleWindowsWheel(PointerSignalEvent signal) {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        signal is! PointerScrollEvent ||
        _saving ||
        _images.length <= 1) {
      return;
    }
    final horizontalDelta = signal.scrollDelta.dx;
    final shiftVerticalDelta = HardwareKeyboard.instance.isShiftPressed
        ? signal.scrollDelta.dy
        : 0.0;
    final delta = horizontalDelta != 0 ? horizontalDelta : shiftVerticalDelta;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      if (delta > 0) {
        _goToNext();
      } else {
        _goToPrevious();
      }
    });
  }

  Widget _buildNavButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
    bool transparent = false,
  }) {
    final button = AppOverlayIconButton(
      buttonKey: key,
      icon: Icon(icon, size: 22),
      tooltip: enabled ? tooltip : '',
      onPressed: enabled ? onPressed : null,
      buttonSize: 40,
    );
    return AnimatedOpacity(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : kAppFadeDuration,
      curve: kAppFadeCurve,
      opacity: enabled ? 1 : 0.35,
      child: transparent
          ? button
          : DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: enabled ? 0.58 : 0.28),
                shape: BoxShape.circle,
              ),
              child: button,
            ),
    );
  }

  void _showSaveFailedSnackBar() {
    showAppSnackBar(
      context,
      ProviderScope.containerOf(context, listen: false)
          .read(appLanguageProviderInstanceProvider)
          .tr('audio_detail_save_failed'),
      tone: AppFeedbackTone.warning,
    );
  }

  Future<void> _commitSelection() async {
    final index = _currentIndex;
    if (!mounted || index < 0 || index >= _images.length) return;
    final requestedFolderPath = widget.folderPath;
    setState(() => _saving = true);
    try {
      final selectedPath = _images[index];
      final storedCoverPath = await ref
          .read(libraryFacadeProvider)
          .setFolderManualCover(requestedFolderPath, selectedPath);
      if (!mounted ||
          !PathMatcher.equalsNormalized(
            widget.folderPath,
            requestedFolderPath,
          )) {
        return;
      }
      if (storedCoverPath == null) {
        _showSaveFailedSnackBar();
        return;
      }
      setState(() => _currentCoverPath = selectedPath);
      widget.onCoverSelected?.call(storedCoverPath);
    } catch (_) {
      if (!mounted ||
          !PathMatcher.equalsNormalized(
            widget.folderPath,
            requestedFolderPath,
          )) {
        return;
      }
      _showSaveFailedSnackBar();
    } finally {
      if (mounted &&
          PathMatcher.equalsNormalized(
            widget.folderPath,
            requestedFolderPath,
          )) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _buildCompactNavigation(AppLanguageProvider i18n) {
    final tokens = AppDesignTokens.of(context);
    return DecoratedBox(
      key: const ValueKey<String>('audio_detail_cover_navigation_capsule'),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(tokens.radiusCapsule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNavButton(
            key: const ValueKey<String>('audio_detail_cover_prev_button'),
            icon: Icons.chevron_left_rounded,
            tooltip: i18n.tr('previous'),
            enabled: _images.length > 1 && !_saving,
            onPressed: _goToPrevious,
            transparent: true,
          ),
          Text(
            '${_currentIndex + 1}/${_images.length}',
            key: const ValueKey<String>('audio_detail_cover_position'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          _buildNavButton(
            key: const ValueKey<String>('audio_detail_cover_next_button'),
            icon: Icons.chevron_right_rounded,
            tooltip: i18n.tr('next'),
            enabled: _images.length > 1 && !_saving,
            onPressed: _goToNext,
            transparent: true,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactCoverAction(AppLanguageProvider i18n) {
    final tokens = AppDesignTokens.of(context);
    final isCurrent = _sameOptionalPath(
      _currentCoverPath,
      _images[_currentIndex],
    );
    final enabled = !isCurrent && !_saving;
    final foregroundColor = isCurrent
        ? Colors.white.withValues(alpha: 0.65)
        : Colors.white;
    final borderRadius = BorderRadius.circular(tokens.radiusCapsule);
    return AppSurfaceButtonShell(
      enabled: enabled,
      builder: (context, _) => Material(
        key: const ValueKey<String>('audio_detail_cover_action_capsule'),
        color: Colors.black.withValues(alpha: isCurrent ? 0.42 : 0.62),
        borderRadius: borderRadius,
        child: AppEntryInkWell(
          borderRadius: borderRadius,
          hoverColor: Colors.white.withValues(alpha: 0.14),
          splashColor: Colors.white.withValues(alpha: 0.22),
          onTap: enabled ? _commitSelection : null,
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
                      color: foregroundColor,
                    ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      i18n.tr(
                        isCurrent
                            ? 'audio_detail_current_cover'
                            : 'audio_detail_set_cover',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: foregroundColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.watch(appLanguageStateProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    if (_loading) {
      return Column(
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
            clipBehavior: Clip.antiAlias,
            color: cs.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant),
            ),
            child: const AspectRatio(
              aspectRatio: kStandardCoverAspectRatio,
              child: CoverFallbackArtwork(),
            ),
          ),
        ],
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
        CoverArtworkFrame(
          key: const ValueKey('audio_detail_cover_content'),
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
              aspectRatio: kStandardCoverAspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                    ),
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: {
                          PointerDeviceKind.touch,
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.trackpad,
                          PointerDeviceKind.stylus,
                        },
                      ),
                      child: _CoverWheelInterceptor(
                        onPointerSignal: _handleWindowsWheel,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _handlePageScroll,
                          child: PageView.builder(
                            // Candidate discovery replaces the preview controller;
                            // recreate its viewport so it uses the loop's initial page.
                            key: ObjectKey(_pageController),
                            controller: _pageController,
                            itemCount: _images.length > 1
                                ? null
                                : _images.length,
                            physics: _images.length > 1
                                ? const PageScrollPhysics()
                                : const NeverScrollableScrollPhysics(),
                            onPageChanged: _handlePageChanged,
                            itemBuilder: (context, page) {
                              final index = _indexForPage(page, _images.length);
                              return RetryingFileImage(
                                key: ValueKey<String>(
                                  'cover_item_${_images[index]}_$page',
                                ),
                                path: _images[index],
                                fit: BoxFit.cover,
                                cacheWidth: coverCacheWidth,
                                useDefaultCacheWidth: coverCacheWidth != null,
                                deferLoadDuringInteraction: true,
                                fallbackBuilder: (_) =>
                                    const CoverFallbackArtwork(),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.compactNavigation) ...[
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(child: _buildCompactCoverAction(i18n)),
                          const SizedBox(width: 8),
                          _buildCompactNavigation(i18n),
                        ],
                      ),
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
                            enabled: _images.length > 1 && !_saving,
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
                            enabled: _images.length > 1 && !_saving,
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
                          if (_images.length > 1)
                            Flexible(
                              child: _CoverCaption(
                                text: i18n.tr('audio_detail_cover_swipe_hint'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (!widget.compactNavigation)
                    Positioned(
                      right: 12,
                      top: 12,
                      child: AnimatedOpacity(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : kAppFadeDuration,
                        curve: kAppFadeCurve,
                        opacity: _saving ? 1 : 0,
                        child: TickerMode(
                          enabled: _saving,
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
                    ),
                ],
              ),
            ),
          ),
        if (!widget.compactNavigation) ...[
          const SizedBox(height: 12),
          Center(
            child: _sameOptionalPath(
                  _currentCoverPath,
                  _images[_currentIndex],
                )
                ? AppLabelledButton(
                    TextButton.icon,
                    onPressed: null,
                    icon: const Icon(Icons.check_circle_rounded),
                    label: Text(i18n.tr('audio_detail_current_cover')),
                  )
                : AppLabelledButton(
                    FilledButton.icon,
                    onPressed: _saving ? null : _commitSelection,
                    icon: const Icon(Icons.image_rounded),
                    label: Text(i18n.tr('audio_detail_set_cover')),
                  ),
          ),
        ],
      ],
    );
    return content;
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CoverWheelInterceptor extends SingleChildRenderObjectWidget {
  const _CoverWheelInterceptor({
    required this.onPointerSignal,
    required super.child,
  });

  final PointerSignalEventListener onPointerSignal;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCoverWheelInterceptor(onPointerSignal);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCoverWheelInterceptor renderObject,
  ) {
    renderObject.onPointerSignal = onPointerSignal;
  }
}

class _RenderCoverWheelInterceptor extends RenderProxyBox {
  _RenderCoverWheelInterceptor(this.onPointerSignal);

  PointerSignalEventListener onPointerSignal;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    // Register ahead of PageView's internal Scrollable so horizontal and
    // Shift+wheel events stay on our page controller even during animations
    // when Scrollable ignores hits on its viewport.
    result.add(BoxHitTestEntry(this, position));
    hitTestChildren(result, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerSignalEvent) {
      onPointerSignal(event);
    }
  }
}
