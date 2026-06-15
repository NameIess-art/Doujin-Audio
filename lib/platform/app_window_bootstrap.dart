import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:window_manager/window_manager.dart';

import 'app_platform.dart';

class _MainWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    await windowManager.destroy();
    exit(0);
  }
}

abstract final class AppWindowBootstrap {
  static Future<void> initializeMainWindow() async {
    if (!AppPlatform.isWindows && !Platform.isMacOS) return;

    await windowManager.ensureInitialized();
    await Window.initialize();

    if (AppPlatform.isWindows) {
      await Window.setEffect(effect: WindowEffect.mica);
    } else if (Platform.isMacOS) {
      await Window.setEffect(effect: WindowEffect.sidebar);
    }

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
