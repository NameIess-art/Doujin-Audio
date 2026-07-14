import 'dart:async';

import 'package:flutter/foundation.dart';

/// Owns main-screen-only scroll requests.
final class MainScreenController {
  final ValueNotifier<int?> _scrollToTopTab = ValueNotifier<int?>(null);

  ValueListenable<int?> get scrollToTopTab => _scrollToTopTab;

  void requestScrollToTop(int tabIndex) {
    _scrollToTopTab.value = tabIndex;
    scheduleMicrotask(() {
      if (_scrollToTopTab.value == tabIndex) {
        _scrollToTopTab.value = null;
      }
    });
  }

  void dispose() => _scrollToTopTab.dispose();
}

/// Owns playlist-only carousel positioning and follows session activations.
final class PlaylistUiController {
  PlaylistUiController(Stream<String> sessionActivations) {
    _activationSubscription = sessionActivations.listen(requestCarouselSnap);
  }

  final ValueNotifier<String?> _carouselSnap = ValueNotifier<String?>(null);
  late final StreamSubscription<String> _activationSubscription;

  ValueListenable<String?> get carouselSnap => _carouselSnap;

  void requestCarouselSnap(String sessionId) {
    if (sessionId.isEmpty) return;
    _carouselSnap.value = sessionId;
  }

  void dispose() {
    unawaited(_activationSubscription.cancel());
    _carouselSnap.dispose();
  }
}
