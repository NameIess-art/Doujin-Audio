import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/confirm_action_dialog.dart';

typedef PermissionCheckCallback = Future<bool> Function();
typedef PermissionOpenSettingsCallback = Future<bool> Function();
typedef PermissionGrantedCallback = Future<void> Function();

class PermissionActionController {
  _PendingPermissionAction? _pendingAction;
  int _generation = 0;
  int? _resumeCheckGeneration;
  bool _disposed = false;

  Future<bool> ensureGrantedAndRun({
    required BuildContext context,
    required String title,
    required String message,
    required PermissionCheckCallback isGranted,
    required PermissionOpenSettingsCallback openSettings,
    required PermissionGrantedCallback onGranted,
    VoidCallback? onCancelled,
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    if (_disposed || !context.mounted) {
      onCancelled?.call();
      return false;
    }
    clear();
    final generation = _generation;
    final granted = await isGranted();
    if (_disposed || generation != _generation || !context.mounted) {
      onCancelled?.call();
      return false;
    }
    if (granted) {
      await onGranted();
      return true;
    }

    final shouldOpenSettings = await showConfirmActionDialog(
      context: context,
      title: title,
      message: message,
      cancelLabel: cancelLabel ?? 'Cancel',
      confirmLabel: confirmLabel ?? 'Open settings',
      icon: Icons.settings_outlined,
      confirmIcon: Icons.settings_rounded,
      isDestructive: false,
    );
    if (_disposed ||
        generation != _generation ||
        !context.mounted ||
        !shouldOpenSettings) {
      onCancelled?.call();
      return false;
    }

    final grantedAfterDialog = await isGranted();
    if (_disposed || generation != _generation || !context.mounted) {
      onCancelled?.call();
      return false;
    }
    if (grantedAfterDialog) {
      await onGranted();
      return true;
    }

    final opened = await openSettings();
    if (_disposed || generation != _generation || !context.mounted) {
      onCancelled?.call();
      return false;
    }
    if (!opened) {
      _pendingAction = null;
      onCancelled?.call();
      return false;
    }

    _pendingAction = _PendingPermissionAction(
      context: context,
      isGranted: isGranted,
      onGranted: onGranted,
      onCancelled: onCancelled,
    );
    return false;
  }

  Future<void> handleAppResumed() async {
    final pendingAction = _pendingAction;
    if (_disposed || pendingAction == null || _resumeCheckGeneration != null) {
      return;
    }
    final generation = _generation;
    bool isCurrent() =>
        !_disposed &&
        generation == _generation &&
        identical(_pendingAction, pendingAction);
    _resumeCheckGeneration = generation;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!isCurrent()) return;
      if (!pendingAction.context.mounted) {
        _pendingAction = null;
        pendingAction.onCancelled?.call();
        return;
      }
      final granted = await pendingAction.isGranted();
      if (!isCurrent()) return;
      _pendingAction = null;
      if (!pendingAction.context.mounted) {
        pendingAction.onCancelled?.call();
        return;
      }
      if (granted) {
        await pendingAction.onGranted();
      } else {
        pendingAction.onCancelled?.call();
      }
    } finally {
      if (_resumeCheckGeneration == generation) _resumeCheckGeneration = null;
    }
  }

  void clear() {
    _generation++;
    final pendingAction = _pendingAction;
    _pendingAction = null;
    _resumeCheckGeneration = null;
    pendingAction?.onCancelled?.call();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

class _PendingPermissionAction {
  const _PendingPermissionAction({
    required this.context,
    required this.isGranted,
    required this.onGranted,
    this.onCancelled,
  });

  final BuildContext context;
  final PermissionCheckCallback isGranted;
  final PermissionGrantedCallback onGranted;
  final VoidCallback? onCancelled;
}
