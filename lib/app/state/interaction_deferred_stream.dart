import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/ui/ui_interaction_coordinator.dart';

int _interactionDeferredStreamSeed = 0;
const Object _noPendingValue = Object();

Stream<T> interactionDeferredListenableStream<T>({
  required Listenable source,
  required T Function() read,
  UiInteractionCoordinator? coordinator,
}) {
  late StreamController<T> controller;
  final interaction = coordinator ?? UiInteractionCoordinator.instance;
  final commitKey =
      'interaction_deferred_listenable_${_interactionDeferredStreamSeed++}';
  Object? pendingValue = _noPendingValue;

  void flushPending() {
    final value = pendingValue;
    pendingValue = _noPendingValue;
    if (!controller.isClosed && !identical(value, _noPendingValue)) {
      controller.add(value as T);
    }
  }

  void emit() {
    final value = read();
    if (!interaction.isInteracting) {
      interaction.cancelCommit(commitKey);
      pendingValue = _noPendingValue;
      controller.add(value);
      return;
    }
    pendingValue = value;
    interaction.scheduleCommit(
      key: commitKey,
      priority: 10,
      commit: flushPending,
    );
  }

  controller = StreamController<T>.broadcast(
    sync: true,
    onListen: () {
      controller.add(read());
      source.addListener(emit);
    },
    onCancel: () {
      source.removeListener(emit);
      interaction.cancelCommit(commitKey);
      pendingValue = _noPendingValue;
    },
  );
  return controller.stream;
}

Stream<T> interactionDeferredValueStream<T>(
  Stream<T> source, {
  UiInteractionCoordinator? coordinator,
}) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  final interaction = coordinator ?? UiInteractionCoordinator.instance;
  final commitKey =
      'interaction_deferred_value_${_interactionDeferredStreamSeed++}';
  Object? pendingValue = _noPendingValue;
  var hasEmitted = false;

  void flushPending() {
    final value = pendingValue;
    pendingValue = _noPendingValue;
    if (!controller.isClosed && !identical(value, _noPendingValue)) {
      controller.add(value as T);
    }
  }

  void emit(T value) {
    if (!hasEmitted || !interaction.isInteracting) {
      hasEmitted = true;
      interaction.cancelCommit(commitKey);
      pendingValue = _noPendingValue;
      controller.add(value);
      return;
    }
    pendingValue = value;
    interaction.scheduleCommit(
      key: commitKey,
      priority: 10,
      commit: flushPending,
    );
  }

  controller = StreamController<T>.broadcast(
    sync: true,
    onListen: () {
      subscription = source.listen(
        emit,
        onError: controller.addError,
        onDone: controller.close,
      );
    },
    onCancel: () async {
      interaction.cancelCommit(commitKey);
      pendingValue = _noPendingValue;
      await subscription?.cancel();
    },
  );
  return controller.stream;
}
