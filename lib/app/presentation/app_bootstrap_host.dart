import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/app_bootstrap_controller.dart';
import '../localization/app_language_en.dart';
import '../localization/app_language_ja.dart';
import '../localization/app_language_provider.dart';
import '../localization/app_language_zh.dart';
import 'app_error_view.dart';

const _bootstrapLightBackground = Color(0xFFFFF8F8);
const _bootstrapDarkBackground = Color(0xFF211A1B);

class AppBootstrapHost extends StatefulWidget {
  const AppBootstrapHost({
    required this.controller,
    required this.appBuilder,
    this.exportDiagnostics,
    this.disposeController = true,
    this.locale,
    super.key,
  });

  final AppBootstrapController controller;
  final Widget Function() appBuilder;
  final Future<void> Function()? exportDiagnostics;
  final bool disposeController;
  final Locale? locale;

  @override
  State<AppBootstrapHost> createState() => _AppBootstrapHostState();
}

class _AppBootstrapHostState extends State<AppBootstrapHost> {
  Widget? _readyApp;

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
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFB2BD),
    ).copyWith(surface: _bootstrapLightBackground);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFB2BD),
      brightness: Brightness.dark,
    ).copyWith(surface: _bootstrapDarkBackground);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: lightScheme.surface,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        scaffoldBackgroundColor: lightScheme.surface,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        scaffoldBackgroundColor: darkScheme.surface,
      ),
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
}
