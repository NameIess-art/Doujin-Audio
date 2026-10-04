import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ui_interaction_coordinator.dart';

int _interactionDeferredStreamSeed = 0;
const Object _noPendingValue = Object();

Stream<T> interactionDeferredListenableStream<T>({
  required Listenable source,
  required T Function() read,
  UiInteractionCoordinator? coordinator,
  bool deferInitialRead = false,
}) {
  final interaction = coordinator ?? UiInteractionCoordinator.instance;
  return Stream<T>.multi((events) {
    final commitKey =
        'interaction_deferred_listenable_${_interactionDeferredStreamSeed++}';
    var dirty = false;

    void flushPending() {
      if (!events.isClosed && dirty) {
        dirty = false;
        events.addSync(read());
      }
    }

    void emit() {
      if (!interaction.isInteracting) {
        interaction.cancelCommit(commitKey);
        dirty = false;
        events.addSync(read());
        return;
      }
      // Snapshot construction can filter entire catalogs. Read once after the
      // animation, rather than constructing values that will be discarded.
      dirty = true;
      interaction.scheduleCommit(
        key: commitKey,
        priority: 10,
        commit: flushPending,
      );
    }

    source.addListener(emit);
    events.onCancel = () {
      source.removeListener(emit);
      interaction.cancelCommit(commitKey);
      dirty = false;
    };
    if (deferInitialRead) {
      emit();
    } else {
      events.addSync(read());
    }
  }, isBroadcast: true);
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
  var sourceDone = false;

  void flushPending() {
    final value = pendingValue;
    pendingValue = _noPendingValue;
    if (!controller.isClosed && !identical(value, _noPendingValue)) {
      controller.add(value as T);
    }
    if (sourceDone) unawaited(controller.close());
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
      hasEmitted = false;
      sourceDone = false;
      subscription = source.listen(
        emit,
        onError: controller.addError,
        onDone: () {
          sourceDone = true;
          if (identical(pendingValue, _noPendingValue)) {
            unawaited(controller.close());
          } else if (!interaction.isInteracting) {
            interaction.cancelCommit(commitKey);
            flushPending();
          }
        },
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
