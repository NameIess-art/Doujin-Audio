import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/app_bootstrap_controller.dart';
import '../localization/app_language_provider.dart';
import '../theme/theme_provider.dart';
import 'app_error_view.dart';

class AppBootstrapHost extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final locale =
        this.locale ?? WidgetsBinding.instance.platformDispatcher.locale;
    final appThemeColor = ThemeProvider.readAppThemeColorSync();
    final lightScheme = appThemeColor
        .colorScheme(Brightness.light)
        .copyWith(
          surface: appThemeColor.bootstrapSurfaceColor(Brightness.light),
        );
    final darkScheme = appThemeColor
        .colorScheme(Brightness.dark)
        .copyWith(
          surface: appThemeColor.bootstrapSurfaceColor(Brightness.dark),
        );
    Widget shell(Widget home) => MaterialApp(
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
      themeMode: ThemeProvider.readThemeModeSync(),
      locale: locale,
      supportedLocales: AppLanguageProvider.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: home,
    );
    return AppBootstrapGate(
      controller: controller,
      disposeController: disposeController,
      onBootstrapSettled: onBootstrapSettled,
      readyBuilder: (_) => appBuilder(),
      loadingBuilder: (_) => shell(const AppBootstrapLoadingView()),
      failureBuilder: (_, state) => shell(
        AppErrorView(
          error: state.error ?? StateError('Unknown bootstrap failure'),
          stackTrace: state.stackTrace,
          onRetry: () => unawaited(controller.retry()),
          exportDiagnostics: exportDiagnostics,
        ),
      ),
    );
  }
}

typedef AppBootstrapFailureBuilder =
    Widget Function(BuildContext context, AppBootstrapState state);

class AppBootstrapGate extends StatefulWidget {
  const AppBootstrapGate({
    required this.controller,
    required this.readyBuilder,
    required this.loadingBuilder,
    required this.failureBuilder,
    this.disposeController = true,
    this.onBootstrapSettled,
    super.key,
  });

  final AppBootstrapController controller;
  final WidgetBuilder readyBuilder;
  final WidgetBuilder loadingBuilder;
  final AppBootstrapFailureBuilder failureBuilder;
  final bool disposeController;
  final VoidCallback? onBootstrapSettled;

  @override
  State<AppBootstrapGate> createState() => _AppBootstrapGateState();
}

class _AppBootstrapGateState extends State<AppBootstrapGate> {
  Widget? _readyApp;
  bool _bootstrapSettledScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleStateChanged);
    _initializeIfNeeded();
  }

  @override
  void didUpdateWidget(covariant AppBootstrapGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleStateChanged);
    if (oldWidget.disposeController) oldWidget.controller.dispose();
    _readyApp = null;
    _bootstrapSettledScheduled = false;
    widget.controller.addListener(_handleStateChanged);
    _initializeIfNeeded();
  }

  void _initializeIfNeeded() {
    if (widget.controller.state.phase == AppBootstrapPhase.initializing) {
      unawaited(widget.controller.initialize());
    }
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
    return switch (state.phase) {
      AppBootstrapPhase.ready => _readyApp ??= widget.readyBuilder(context),
      AppBootstrapPhase.failure => widget.failureBuilder(context, state),
      AppBootstrapPhase.initializing => widget.loadingBuilder(context),
    };
  }

  void _scheduleBootstrapSettled() {
    if (_bootstrapSettledScheduled) return;
    _bootstrapSettledScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onBootstrapSettled?.call();
    });
  }
}

class AppBootstrapLoadingView extends StatelessWidget {
  const AppBootstrapLoadingView({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(key: ValueKey<String>('app_bootstrap_loading'));
}
