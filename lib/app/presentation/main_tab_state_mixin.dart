import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/scroll_to_top_transition.dart';
import '../theme/app_styles.dart';

mixin MainTabStateMixin<T extends StatefulWidget> on State<T> {
  final GlobalKey headerKey = GlobalKey();
  late double headerHeight = defaultHeaderHeight;
  final _scrollTransitionKey = GlobalKey<ScrollToTopTransitionState>();

  ValueListenable<int?> _scrollToTopListenable = ValueNotifier<int?>(null);
  ValueListenable<int?> _stopScrollListenable = ValueNotifier<int?>(null);

  /// The tab index this state responds to for scroll-to-top events.
  int get tabIndex;

  /// Override to return the height of static controls inside the header.
  double get headerControlsFullHeight => 0.0;

  /// Override to provide the default header height before measurement.
  double get defaultHeaderHeight => AppPageHeaderMetrics.toolbarHeight;

  /// The primary scroll controller for this tab, used for scroll-to-top.
  ScrollController get mainScrollController;

  /// Whether this tab should respond to the current scroll-to-top signal.
  bool get handlesScrollToTop => true;

  /// Wrap only scrolling content so page headers stay live above the transition.
  Widget buildScrollToTopTransition(Widget child) => ScrollToTopTransition(
    key: _scrollTransitionKey,
    controller: () => mainScrollController,
    child: child,
  );

  /// Call this in `initState` after getting the listenable.
  void initTabState(
    ValueListenable<int?> scrollToTop, [
    ValueListenable<int?>? stopScroll,
  ]) {
    _scrollToTopListenable = scrollToTop;
    _scrollToTopListenable.addListener(handleScrollToTopSignal);
    if (stopScroll != null) {
      _stopScrollListenable = stopScroll;
      _stopScrollListenable.addListener(_handleStopScrollSignal);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      measureHeader();
    });
  }

  /// Call this in `dispose`.
  void disposeTabState() {
    _scrollToTopListenable.removeListener(handleScrollToTopSignal);
    _stopScrollListenable.removeListener(_handleStopScrollSignal);
  }

  void handleScrollToTopSignal() {
    if (!mounted) return;
    if (_scrollToTopListenable.value == tabIndex && handlesScrollToTop) {
      scrollToTop();
    }
  }

  void _handleStopScrollSignal() {
    if (!mounted) return;
    if (_stopScrollListenable.value == tabIndex) {
      stopScroll();
    }
  }

  void scrollToTop() {
    final controller = mainScrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    if (!position.hasContentDimensions) return;
    final top = position.minScrollExtent;
    if (position.pixels <= top) return;
    if (MediaQuery.disableAnimationsOf(context) ||
        position.viewportDimension <= 0) {
      controller.jumpTo(top);
      return;
    }

    final animationStart = top + position.viewportDimension * 2;
    if (position.pixels > animationStart) {
      unawaited(_scrollTransitionKey.currentState!.scrollToTop());
      return;
    }
    unawaited(
      controller.animateTo(
        top,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// Immediately stops any ongoing momentum/animated scroll.
  void stopScroll() {
    _scrollTransitionKey.currentState?.cancel();
    final controller = mainScrollController;
    if (!controller.hasClients) return;
    controller.jumpTo(controller.offset);
  }

  void measureHeader() {
    final box = headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final h = box.size.height - headerControlsFullHeight;
      if (h > 0 && h != headerHeight) {
        setState(() => headerHeight = h);
      }
    }
  }
}
