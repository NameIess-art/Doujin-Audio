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
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    if (_disposed || !context.mounted) return false;
    clear();
    final generation = _generation;
    final granted = await isGranted();
    if (_disposed || generation != _generation || !context.mounted) {
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
      return false;
    }

    final opened = await openSettings();
    if (_disposed || generation != _generation || !context.mounted) {
      return false;
    }
    if (!opened) {
      _pendingAction = null;
      return false;
    }

    _pendingAction = _PendingPermissionAction(
      context: context,
      isGranted: isGranted,
      onGranted: onGranted,
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
        identical(_pendingAction, pendingAction) &&
        pendingAction.context.mounted;
    _resumeCheckGeneration = generation;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!isCurrent()) return;
      final granted = await pendingAction.isGranted();
      if (!isCurrent()) return;
      _pendingAction = null;
      if (granted) await pendingAction.onGranted();
    } finally {
      if (_resumeCheckGeneration == generation) _resumeCheckGeneration = null;
    }
  }

  void clear() {
    _generation++;
    _pendingAction = null;
    _resumeCheckGeneration = null;
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
  });

  final BuildContext context;
  final PermissionCheckCallback isGranted;
  final PermissionGrantedCallback onGranted;
}
