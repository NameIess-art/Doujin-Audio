import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../windows/subtitle_overlay_window.dart';
import 'app_platform.dart';

class _MainWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    await windowManager.destroy();
    exit(0);
  }
}

abstract final class AppWindowBootstrap {
  static bool isSubtitleOverlayWindowLaunch(List<String> args) {
    return AppPlatform.isWindows &&
        args.length >= 3 &&
        args.first == 'multi_window';
  }

  static Future<bool> runSubtitleOverlayWindowIfNeeded(
    List<String> args,
  ) async {
    if (!isSubtitleOverlayWindowLaunch(args)) return false;

    final windowId = args[1];
    final argument = args[2].isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;

    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(800, 200),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
    });

    runApp(
      SubtitleOverlayWindow(
        windowController: WindowController.fromWindowId(windowId),
        args: argument,
      ),
    );
    return true;
  }

  static Future<void> initializeMainWindow() async {
    if (!AppPlatform.isWindows) return;

    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1100, 750),
      minimumSize: Size(800, 600),
      center: true,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    windowManager.addListener(_MainWindowListener());
  }
}
