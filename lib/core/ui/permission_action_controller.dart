import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/confirm_action_dialog.dart';

typedef PermissionCheckCallback = Future<bool> Function();
typedef PermissionOpenSettingsCallback = Future<bool> Function();
typedef PermissionGrantedCallback = Future<void> Function();

class PermissionActionController {
  _PendingPermissionAction? _pendingAction;
  bool _resumeCheckScheduled = false;

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
    if (await isGranted()) {
      await onGranted();
      return true;
    }

    if (!context.mounted) return false;
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
    if (!shouldOpenSettings) {
      return false;
    }

    final opened = await openSettings();
    if (!opened) {
      _pendingAction = null;
      return false;
    }

    _pendingAction = _PendingPermissionAction(
      isGranted: isGranted,
      onGranted: onGranted,
    );
    return false;
  }

  Future<void> handleAppResumed() async {
    final pendingAction = _pendingAction;
    if (pendingAction == null || _resumeCheckScheduled) {
      return;
    }
    _resumeCheckScheduled = true;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    _resumeCheckScheduled = false;

    final latestPendingAction = _pendingAction;
    if (latestPendingAction == null) {
      return;
    }

    final granted = await latestPendingAction.isGranted();
    if (!granted) {
      _pendingAction = null;
      return;
    }

    _pendingAction = null;
    await latestPendingAction.onGranted();
  }

  void clear() {
    _pendingAction = null;
    _resumeCheckScheduled = false;
  }

  void dispose() {
    clear();
  }
}

class _PendingPermissionAction {
  const _PendingPermissionAction({
    required this.isGranted,
    required this.onGranted,
  });

  final PermissionCheckCallback isGranted;
  final PermissionGrantedCallback onGranted;
}
