import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_styles.dart';

mixin MainTabStateMixin<T extends StatefulWidget> on State<T> {
  final GlobalKey headerKey = GlobalKey();
  late double headerHeight = defaultHeaderHeight;

  ValueListenable<int?>? _scrollToTopListenable;

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

  /// Call this in `initState` after getting the listenable.
  void initTabState(ValueListenable<int?>? listenable) {
    _scrollToTopListenable = listenable;
    _scrollToTopListenable?.addListener(handleScrollToTopSignal);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) measureHeader();
    });
  }

  /// Call this in `dispose`.
  void disposeTabState() {
    _scrollToTopListenable?.removeListener(handleScrollToTopSignal);
  }

  void handleScrollToTopSignal() {
    if (!mounted) return;
    if (_scrollToTopListenable?.value == tabIndex && handlesScrollToTop) {
      jumpToTop();
    }
  }

  void jumpToTop() {
    final controller = mainScrollController;
    if (!controller.hasClients) return;
    const fakeAnimationStartOffset = 360.0;
    final animationStartOffset =
        controller.position.maxScrollExtent < fakeAnimationStartOffset
        ? controller.position.maxScrollExtent
        : fakeAnimationStartOffset;
    if (controller.offset > animationStartOffset) {
      controller.jumpTo(animationStartOffset);
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.jumpTo(0);
      return;
    }
    controller.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
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
