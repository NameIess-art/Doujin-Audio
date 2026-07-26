import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/app_bootstrap_controller.dart';
import '../localization/app_language_en.dart';
import '../localization/app_language_ja.dart';
import '../localization/app_language_provider.dart';
import '../localization/app_language_zh.dart';
import '../theme/theme_provider.dart';
import '../../core/ui/app_icon_color_group.dart';
import '../../core/widgets/app_brand_icon.dart';
import 'app_error_view.dart';

class AppBootstrapHost extends StatefulWidget {
  const AppBootstrapHost({
    required this.controller,
    required this.appBuilder,
    this.exportDiagnostics,
    this.disposeController = true,
    this.locale,
    this.onBootstrapSettled,
    super.key,
  });

  final AppBootstrapController controller;
  final Widget Function() appBuilder;
  final Future<void> Function()? exportDiagnostics;
  final bool disposeController;
  final Locale? locale;
  final VoidCallback? onBootstrapSettled;

  @override
  State<AppBootstrapHost> createState() => _AppBootstrapHostState();
}

class _AppBootstrapHostState extends State<AppBootstrapHost> {
  Widget? _readyApp;
  bool _bootstrapSettledScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleStateChanged);
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(covariant AppBootstrapHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleStateChanged);
    if (oldWidget.disposeController) oldWidget.controller.dispose();
    _readyApp = null;
    _bootstrapSettledScheduled = false;
    widget.controller.addListener(_handleStateChanged);
    unawaited(widget.controller.initialize());
  }

  void _handleStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleStateChanged);
    if (widget.disposeController) widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    if (state.phase != AppBootstrapPhase.initializing) {
      _scheduleBootstrapSettled();
    }
    if (state.phase == AppBootstrapPhase.ready) {
      return _readyApp ??= widget.appBuilder();
    }

    final locale =
        widget.locale ?? WidgetsBinding.instance.platformDispatcher.locale;
    final strings = switch (locale.languageCode) {
      'zh' => appLanguageZh,
      'ja' => appLanguageJa,
      _ => appLanguageEn,
    };
    String tr(String key) => strings[key] ?? appLanguageEn[key] ?? key;
    final appThemeColor = ThemeProvider.readAppThemeColorSync();
    final iconColorGroup = appThemeColor.iconColorGroup;
    final lightScheme = appThemeColor
        .colorScheme(Brightness.light)
        .copyWith(surface: iconColorGroup.splashBackground(Brightness.light));
    final darkScheme = appThemeColor
        .colorScheme(Brightness.dark)
        .copyWith(surface: iconColorGroup.splashBackground(Brightness.dark));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: lightScheme.surface,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        scaffoldBackgroundColor: lightScheme.surface,
        extensions: <ThemeExtension<dynamic>>[
          AppBrandIconTheme.forGroup(iconColorGroup, Brightness.light),
        ],
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        scaffoldBackgroundColor: darkScheme.surface,
        extensions: <ThemeExtension<dynamic>>[
          AppBrandIconTheme.forGroup(iconColorGroup, Brightness.dark),
        ],
      ),
      themeMode: ThemeProvider.readThemeModeSync(),
      locale: locale,
      supportedLocales: AppLanguageProvider.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: state.phase == AppBootstrapPhase.failure
          ? AppErrorView(
              error: state.error ?? StateError('Unknown bootstrap failure'),
              stackTrace: state.stackTrace,
              onRetry: () => unawaited(widget.controller.retry()),
              exportDiagnostics: widget.exportDiagnostics,
            )
          : Scaffold(
              key: const ValueKey<String>('app_bootstrap_loading'),
              body: Center(
                child: Semantics(
                  liveRegion: true,
                  label: tr('startup_initializing'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppBrandIcon(size: 72),
                      const SizedBox(height: 20),
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                      Text(tr('startup_initializing')),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  void _scheduleBootstrapSettled() {
    if (_bootstrapSettledScheduled) return;
    _bootstrapSettledScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onBootstrapSettled?.call();
    });
  }
}
