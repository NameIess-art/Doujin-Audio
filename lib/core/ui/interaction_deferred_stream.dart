import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ui_interaction_coordinator.dart';

int _interactionDeferredStreamSeed = 0;
const Object _noPendingValue = Object();
const Object _noVersion = Object();

Stream<T> interactionDeferredListenableStream<T>({
  required Listenable source,
  required T Function() read,
  UiInteractionCoordinator? coordinator,
  bool deferInitialRead = false,
  bool structural = false,
  Object? Function()? version,
}) {
  final interaction = coordinator ?? UiInteractionCoordinator.instance;
  return Stream<T>.multi((events) {
    final commitKey =
        'interaction_deferred_listenable_${_interactionDeferredStreamSeed++}';
    var dirty = false;
    var paused = false;
    Object? lastVersion = _noVersion;

    T readSnapshot() {
      // Read the version before the snapshot so a synchronous mutation during
      // read() cannot be attributed to the newer state.
      lastVersion = version == null ? _noVersion : version();
      return read();
    }

    void flushPending() {
      if (!events.isClosed && !paused && dirty) {
        dirty = false;
        if (version != null &&
            !identical(lastVersion, _noVersion) &&
            version() == lastVersion) {
          return;
        }
        events.addSync(readSnapshot());
      }
    }

    void emit() {
      if (paused) {
        dirty = true;
        return;
      }
      if (version != null &&
          !identical(lastVersion, _noVersion) &&
          version() == lastVersion) {
        dirty = false;
        interaction.cancelCommit(commitKey);
        return;
      }
      if (!structural && !interaction.isInteracting) {
        interaction.cancelCommit(commitKey);
        dirty = false;
        events.addSync(readSnapshot());
        return;
      }
      // Snapshot construction can filter entire catalogs. Read once after the
      // animation, rather than constructing values that will be discarded.
      dirty = true;
      interaction.scheduleCommit(
        key: commitKey,
        priority: 10,
        structural: structural,
        commit: flushPending,
      );
    }

    source.addListener(emit);
    events.onPause = () {
      paused = true;
      interaction.cancelCommit(commitKey);
    };
    events.onResume = () {
      paused = false;
      if (dirty) emit();
    };
    events.onCancel = () {
      source.removeListener(emit);
      interaction.cancelCommit(commitKey);
      dirty = false;
    };
    if (deferInitialRead) {
      emit();
    } else {
      events.addSync(readSnapshot());
    }
  }, isBroadcast: true);
}

Stream<T> interactionDeferredValueStream<T>(
  Stream<T> source, {
  UiInteractionCoordinator? coordinator,
  bool structural = false,
  bool Function(T previous, T next)? isStructuralUpdate,
}) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  final interaction = coordinator ?? UiInteractionCoordinator.instance;
  final commitKey =
      'interaction_deferred_value_${_interactionDeferredStreamSeed++}';
  Object? pendingValue = _noPendingValue;
  Object? publishedValue = _noPendingValue;
  var hasEmitted = false;
  var sourceDone = false;

  bool isStructural(T value) =>
      structural ||
      (hasEmitted &&
          (isStructuralUpdate?.call(publishedValue as T, value) ?? false));

  void flushPending() {
    final value = pendingValue;
    pendingValue = _noPendingValue;
    if (!controller.isClosed && !identical(value, _noPendingValue)) {
      publishedValue = value;
      controller.add(value as T);
    }
    if (sourceDone) unawaited(controller.close());
  }

  void emit(T value) {
    // Progress for a queued catalog must not publish its new structure early.
    final structuralUpdate = isStructural(value);
    final shouldDefer =
        structuralUpdate ||
        (isStructuralUpdate == null && interaction.isInteracting);
    if (!hasEmitted || !shouldDefer) {
      hasEmitted = true;
      interaction.cancelCommit(commitKey);
      pendingValue = _noPendingValue;
      publishedValue = value;
      controller.add(value);
      return;
    }
    pendingValue = value;
    interaction.scheduleCommit(
      key: commitKey,
      priority: 10,
      structural: structuralUpdate,
      commit: flushPending,
    );
  }

  controller = StreamController<T>.broadcast(
    sync: true,
    onListen: () {
      hasEmitted = false;
      publishedValue = _noPendingValue;
      sourceDone = false;
      subscription = source.listen(
        emit,
        onError: controller.addError,
        onDone: () {
          sourceDone = true;
          if (identical(pendingValue, _noPendingValue)) {
            unawaited(controller.close());
          } else if (!isStructural(pendingValue as T) &&
              !interaction.isInteracting) {
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
