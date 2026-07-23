import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log_service.dart';

enum AppBootstrapPhase { initializing, ready, failure }

@immutable
class AppBootstrapState {
  const AppBootstrapState._({required this.phase, this.error, this.stackTrace});

  const AppBootstrapState.initializing()
    : this._(phase: AppBootstrapPhase.initializing);

  const AppBootstrapState.ready() : this._(phase: AppBootstrapPhase.ready);

  const AppBootstrapState.failure(Object error, StackTrace stackTrace)
    : this._(
        phase: AppBootstrapPhase.failure,
        error: error,
        stackTrace: stackTrace,
      );

  final AppBootstrapPhase phase;
  final Object? error;
  final StackTrace? stackTrace;
}

class AppBootstrapController extends ChangeNotifier {
  AppBootstrapController({required Future<void> Function() initializer})
    : _initializer = initializer;

  final Future<void> Function() _initializer;
  AppBootstrapState _state = const AppBootstrapState.initializing();
  Future<void>? _activeAttempt;
  bool _disposed = false;

  AppBootstrapState get state => _state;

  Future<void> initialize() => _runAttempt();

  Future<void> retry() => _runAttempt();

  Future<void> _runAttempt() {
    final activeAttempt = _activeAttempt;
    if (activeAttempt != null) return activeAttempt;

    final attempt = _performAttempt();
    _activeAttempt = attempt;
    return attempt.whenComplete(() {
      if (identical(_activeAttempt, attempt)) {
        _activeAttempt = null;
      }
    });
  }

  Future<void> _performAttempt() async {
    _setState(const AppBootstrapState.initializing());
    try {
      await _initializer();
      _setState(const AppBootstrapState.ready());
    } catch (error, stackTrace) {
      AppLogService.error(
        'app_bootstrap_failed',
        error: error,
        stackTrace: stackTrace,
      );
      _setState(AppBootstrapState.failure(error, stackTrace));
    }
  }

  void _setState(AppBootstrapState nextState) {
    if (_disposed) return;
    _state = nextState;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
