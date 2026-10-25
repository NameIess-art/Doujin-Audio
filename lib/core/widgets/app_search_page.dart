import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../app/theme/app_design_tokens.dart';
import '../ui/ui_interaction_coordinator.dart';
import 'app_edge_fade_mask.dart';
import 'app_glass_surface.dart';
import 'app_transitions.dart';
import 'page_header_inset.dart';
import 'top_page_header.dart';
import 'windows_horizontal_wheel_scroll.dart';

export 'app_search_suggestions.dart';

@immutable
class AppSearchCategory<T> {
  const AppSearchCategory({required this.value, required this.label});

  final T value;
  final String label;
}

class AppSearchPageScaffold<T> extends StatefulWidget {
  const AppSearchPageScaffold({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    this.categories = const [],
    this.selectedCategory,
    this.onCategorySelected,
    required this.onChanged,
    required this.onSubmitted,
    required this.onCloseOrClear,
    required this.body,
    this.resultsBody,
    this.accentColor,
    this.controlsOverlay,
    this.showConfirmButton = false,
    this.onConfirm,
    this.confirmLabel = 'Search',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final List<AppSearchCategory<T>> categories;
  final T? selectedCategory;
  final ValueChanged<T>? onCategorySelected;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onCloseOrClear;
  final Widget body;
  final Widget? resultsBody;
  final Color? accentColor;
  final Widget? controlsOverlay;
  final bool showConfirmButton;
  final VoidCallback? onConfirm;
  final String confirmLabel;

  static double controlsTopInset(
    BuildContext context, {
    bool hasCategories = true,
  }) => MediaQuery.paddingOf(context).top + (hasCategories ? 100 : 56);

  @override
  State<AppSearchPageScaffold<T>> createState() =>
      _AppSearchPageScaffoldState<T>();
}

class _AppSearchPageScaffoldState<T> extends State<AppSearchPageScaffold<T>>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _interaction = UiInteractionCoordinator.instance;
  FlutterView? _view;
  double? _keyboardInset;
  bool _requestedInitialFocus = false;
  bool _focusScheduled = false;
  late final AnimationController _resultsController;
  late final Animation<double> _resultsOpacity;
  late final Animation<double> _suggestionsOpacity;
  Widget? _retainedResultsBody;

  bool get _skipResultsAnimation =>
      MediaQuery.disableAnimationsOf(context) ||
      !TickerMode.valuesOf(context).enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _retainedResultsBody = widget.resultsBody;
    _resultsController = AnimationController(
      vsync: this,
      duration: kAppFadeDuration,
      reverseDuration: kAppFadeDuration,
      value: widget.resultsBody == null ? 0.0 : 1.0,
    )
      ..addListener(_handleResultsAnimationTick)
      ..addStatusListener(_handleResultsAnimationStatus);
    _resultsOpacity = _resultsController.drive(CurveTween(curve: kAppFadeCurve));
    _suggestionsOpacity = ReverseAnimation(_resultsOpacity);
  }

  void _handleResultsAnimationTick() {
    if (!mounted) return;
    if (widget.resultsBody != null && _resultsController.value == 1.0) {
      setState(() {});
    } else if (widget.resultsBody == null &&
        _resultsController.value == 0.0 &&
        _retainedResultsBody != null) {
      setState(() => _retainedResultsBody = null);
    }
  }

  void _handleResultsAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.dismissed &&
        widget.resultsBody == null &&
        _retainedResultsBody != null) {
      setState(() => _retainedResultsBody = null);
    } else if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AppSearchPageScaffold<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadResults = oldWidget.resultsBody != null;
    final hasResults = widget.resultsBody != null;
    if (hasResults) {
      _retainedResultsBody = widget.resultsBody;
    }
    if (hadResults != hasResults) {
      if (_skipResultsAnimation) {
        _resultsController.stop();
        _resultsController.value = hasResults ? 1.0 : 0.0;
        if (!hasResults) _retainedResultsBody = null;
      } else if (hasResults) {
        _resultsController.forward();
      } else {
        _resultsController.reverse();
      }
    }
  }

  @override
  void didChangeMetrics() {
    final inset = _view?.viewInsets.bottom;
    if (inset == null || inset == _keyboardInset) return;
    _keyboardInset = inset;
    if (!TickerMode.valuesOf(context).enabled ||
        readAppRoute(context)?.isCurrent == false) {
      return;
    }
    // IME motion outlasts route entrance protection. Reuse the idle timer so
    // result adoption and cover updates resume only after the metrics settle.
    _interaction.beginInteraction(this, deferVisualUpdates: true);
    _interaction.endInteraction(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _keyboardInset ??= _view!.viewInsets.bottom;
    if (_skipResultsAnimation && _resultsController.isAnimating) {
      _resultsController.stop();
      _resultsController.value = widget.resultsBody == null ? 0.0 : 1.0;
      if (widget.resultsBody == null) _retainedResultsBody = null;
    }
    if (!TickerMode.valuesOf(context).enabled ||
        ModalRoute.isCurrentOf(context) == false) {
      _interaction.cancelInteraction(this);
    }
    if (_requestedInitialFocus ||
        _focusScheduled ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.isCurrentOf(context) == false ||
        ModalRoute.of(context)?.animation?.status ==
            AnimationStatus.dismissed ||
        ModalRoute.of(context)?.animation?.isAnimating == true) {
      return;
    }
    _focusScheduled = true;
    // Entrance activity excludes focus until the route has finished fading.
    // Request once after that exclusion updates, without refocusing on rebuilds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusScheduled = false;
      if (!mounted ||
          _requestedInitialFocus ||
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.isCurrentOf(context) == false ||
          ModalRoute.of(context)?.animation?.status ==
              AnimationStatus.dismissed ||
          ModalRoute.of(context)?.animation?.isAnimating == true ||
          !widget.focusNode.canRequestFocus) {
        return;
      }
      _requestedInitialFocus = true;
      widget.focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction.cancelInteraction(this);
    _resultsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final accent = widget.accentColor ?? cs.primary;
    final confirmEnabled = widget.onConfirm != null;
    final confirmForeground = confirmEnabled
        ? cs.onPrimary
        : cs.onSurface.withValues(alpha: 0.38);
    final hasResults = widget.resultsBody != null;
    final resultsBody = widget.resultsBody ?? _retainedResultsBody;
    final showSuggestions = !hasResults || _resultsController.value < 1.0;
    final bodyLayerChild = PageHeaderInset(
      topInset: AppSearchPageScaffold.controlsTopInset(
        context,
        hasCategories: widget.categories.isNotEmpty,
      ),
      child: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical &&
              notification.direction != ScrollDirection.idle &&
              widget.focusNode.hasFocus) {
            widget.focusNode.unfocus();
          }
          return false;
        },
        child: AppPageContentTransition(
          backgroundColor: cs.surface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (showSuggestions)
                KeyedSubtree(
                  key: const ValueKey<String>('app_search_suggestions_slot'),
                  child: TickerMode(
                    enabled: !hasResults,
                    child: IgnorePointer(
                      ignoring: hasResults,
                      child: ExcludeFocus(
                        excluding: hasResults,
                        child: ExcludeSemantics(
                          excluding: hasResults,
                          child: FadeTransition(
                            opacity: _suggestionsOpacity,
                            child: widget.body,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (resultsBody != null)
                KeyedSubtree(
                  key: const ValueKey<String>('app_search_results_slot'),
                  child: TickerMode(
                    enabled: hasResults,
                    child: IgnorePointer(
                      ignoring: !hasResults,
                      child: ExcludeFocus(
                        excluding: !hasResults,
                        child: ExcludeSemantics(
                          excluding: !hasResults,
                          child: FadeTransition(
                            opacity: _resultsOpacity,
                            child: resultsBody,
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
    );
    final content = Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        key: const ValueKey<String>('app_search_stack'),
        fit: StackFit.expand,
        children: [
          Builder(
            key: const ValueKey<String>('app_search_body_layer'),
            builder: (context) {
              final mediaQuery = MediaQuery.of(context);
              return Positioned(
                top: 0,
                left: 0,
                right: 0,
                bottom: mediaQuery.viewInsets.bottom,
                // Keep keyboard dependencies local to the viewport so neither
                // the controls nor result cards rebuild on every IME tick.
                child: MediaQuery(
                  data: mediaQuery.copyWith(
                    viewInsets: mediaQuery.viewInsets.copyWith(bottom: 0),
                  ),
                  child: bodyLayerChild,
                ),
              );
            },
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height:
                AppSearchPageScaffold.controlsTopInset(
                  context,
                  hasCategories: widget.categories.isNotEmpty,
                ) +
                12,
            child: const AppPageHeaderTransition(
              child: AppEdgeFadeMask(
                key: ValueKey<String>('app_search_top_fade_mask'),
                direction: AppEdgeFadeDirection.towardTop,
              ),
            ),
          ),
          Builder(
            builder: (context) => Positioned(
              right: 16 + MediaQuery.paddingOf(context).right,
              bottom:
                  MediaQuery.viewInsetsOf(context).bottom +
                  MediaQuery.paddingOf(context).bottom +
                  16,
              child: AppPageContentTransition(
                child: AppDeferredFade(
                  visible: widget.showConfirmButton,
                  child: HeaderFloatingSurface(
                    key: const ValueKey<String>('app_search_confirm'),
                    height: 46,
                    radius: 23,
                    padding: EdgeInsets.zero,
                    child: Material(
                      // An empty draft cannot be submitted; show that instead
                      // of an accent button that silently ignores taps.
                      color: confirmEnabled
                          ? accent
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(23),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(23),
                        onTap: widget.onConfirm,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.search_rounded,
                                size: 18,
                                color: confirmForeground,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                widget.confirmLabel,
                                style: TextStyle(
                                  color: confirmForeground,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            key: const ValueKey<String>('app_search_controls_overlay'),
            top: 0,
            left: 0,
            right: 0,
            child: AppHeaderTransition(
              showBackground: false,
              child: widget.controlsOverlay != null
                  ? KeyedSubtree(
                      key: const ValueKey('search_selection_controls'),
                      child: widget.controlsOverlay!,
                    )
                  : Padding(
                      key: const ValueKey('search_normal_controls'),
                      padding: EdgeInsets.fromLTRB(
                        16,
                        MediaQuery.paddingOf(context).top + 6,
                        16,
                        0,
                      ),
                      // The mask paints in a separate header layer. Keep these
                      // samples independent so they respect the controls' fade.
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  key: const ValueKey<String>(
                                    'app_search_field_shell',
                                  ),
                                  height: 38,
                                  child: _SearchFloatingCapsule(
                                    radius: 19,
                                    child: TextSelectionTheme(
                                      data: TextSelectionThemeData(
                                        cursorColor: accent,
                                        selectionColor: accent.withValues(
                                          alpha: 0.24,
                                        ),
                                        selectionHandleColor: accent,
                                      ),
                                      child: TextField(
                                        key: const ValueKey<String>(
                                          'app_search_field',
                                        ),
                                        controller: widget.controller,
                                        focusNode: widget.focusNode,
                                        cursorColor: accent,
                                        textInputAction:
                                            TextInputAction.search,
                                        textAlignVertical:
                                            TextAlignVertical.center,
                                        onChanged: widget.onChanged,
                                        onSubmitted: widget.onSubmitted,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(fontSize: 14),
                                        decoration: InputDecoration(
                                          filled: false,
                                          fillColor: Colors.transparent,
                                          prefixIcon: Icon(
                                            Icons.search_rounded,
                                            color: cs.onSurfaceVariant,
                                            size: 20,
                                          ),
                                          prefixIconConstraints:
                                              const BoxConstraints.tightFor(
                                                width: 38,
                                                height: 38,
                                              ),
                                          hintText: widget.hintText,
                                          hintStyle: theme
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: cs.onSurfaceVariant,
                                                fontSize: 14,
                                              ),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          isDense: true,
                                          contentPadding:
                                              const EdgeInsets.only(
                                                right: 10,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox.square(
                                dimension: 38,
                                child: _SearchFloatingCapsule(
                                  radius: 19,
                                  child: IconButton(
                                    key: const ValueKey<String>(
                                      'app_search_close',
                                    ),
                                    onPressed: widget.onCloseOrClear,
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 20,
                                    ),
                                    color: cs.onSurfaceVariant,
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size(38, 38),
                                      maximumSize: const Size(38, 38),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (widget.categories.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SizedBox(
                              key: const ValueKey<String>(
                                'app_search_category_shell',
                              ),
                              height: 38,
                              child: _SearchFloatingCapsule(
                                radius: 19,
                                child: WindowsHorizontalWheelScroll(
                                  builder: (scrollController) => ListView.separated(
                                    key: const ValueKey<String>(
                                      'app_search_categories',
                                    ),
                                    controller: scrollController,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 3,
                                    ),
                                    scrollDirection: Axis.horizontal,
                                    physics: const ClampingScrollPhysics(),
                                    itemCount: widget.categories.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: 2),
                                    itemBuilder: (context, index) {
                                      final category =
                                          widget.categories[index];
                                      final selected =
                                          category.value ==
                                          widget.selectedCategory;
                                      return Semantics(
                                        button: true,
                                        selected: selected,
                                        child: InkWell(
                                          key: ValueKey<String>(
                                            'app_search_category_${category.value}',
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            15,
                                          ),
                                          onTap:
                                              widget.onCategorySelected ==
                                                  null
                                              ? null
                                              : () =>
                                                    widget
                                                        .onCategorySelected!(
                                                      category.value,
                                                    ),
                                          child: AnimatedContainer(
                                            duration: tokens.motionFast,
                                            alignment: Alignment.center,
                                            padding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                ),
                                            decoration: BoxDecoration(
                                              color: selected
                                                  ? accent.withValues(
                                                      alpha: 0.19,
                                                    )
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(15),
                                            ),
                                            child: Text(
                                              category.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme
                                                  .textTheme
                                                  .labelMedium
                                                  ?.copyWith(
                                                    color: selected
                                                        ? accent
                                                        : cs.onSurfaceVariant,
                                                    fontWeight: selected
                                                        ? FontWeight.w700
                                                        : FontWeight.w600,
                                                    fontSize: 12.5,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
    return content;
  }
}

class _SearchFloatingCapsule extends StatelessWidget {
  const _SearchFloatingCapsule({required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final glassEnabled = AppDesignTokens.of(context).barGlassEnabled;
    final borderRadius = BorderRadius.circular(radius);
    final capsuleSurface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
        ),
      ),
      child: child,
    );
    return AppGlassSurface(
      enabled: glassEnabled,
      backgroundColor: glassEnabled
          ? background.withValues(alpha: background.a * 0.9)
          : background,
      borderRadius: borderRadius,
      child: capsuleSurface,
    );
  }
}
