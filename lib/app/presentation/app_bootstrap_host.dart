import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../core/widgets/drag_only_scrollbar.dart';
import '../application/app_bootstrap_controller.dart';
import '../localization/app_language_provider.dart';
import '../theme/theme_provider.dart';
import 'app_error_view.dart';

class AppBootstrapHost extends StatelessWidget {
  const AppBootstrapHost({
    required this.controller,
    required this.themeProvider,
    required this.appBuilder,
    this.exportDiagnostics,
    this.disposeController = true,
    this.locale,
    this.onBootstrapSettled,
    super.key,
  });

  final AppBootstrapController controller;
  final ThemeProvider themeProvider;
  final Widget Function() appBuilder;
  final Future<void> Function()? exportDiagnostics;
  final bool disposeController;
  final Locale? locale;
  final VoidCallback? onBootstrapSettled;

  @override
  Widget build(BuildContext context) {
    Widget shell(Widget child, {required bool loading}) => ListenableBuilder(
      listenable: themeProvider,
      child: child,
      builder: (context, child) {
        final dispatcher = WidgetsBinding.instance.platformDispatcher;
        final theme = themeProvider.themeFor(
          MediaQuery.maybePlatformBrightnessOf(context) ??
              dispatcher.platformBrightness,
          highContrast: MediaQuery.maybeHighContrastOf(context) ?? false,
        );
        if (loading) return Theme(data: theme, child: child!);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          scrollBehavior: const AppScrollBehavior(),
          color: theme.colorScheme.surface,
          theme: theme,
          locale: locale ?? dispatcher.locale,
          supportedLocales: AppLanguageProvider.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) {
            final app = child ?? const SizedBox();
            if (defaultTargetPlatform == TargetPlatform.windows) {
              return TooltipVisibility(
                visible: false,
                child: app,
              );
            }
            return app;
          },
          home: child,
        );
      },
    );
    return AppBootstrapGate(
      controller: controller,
      disposeController: disposeController,
      onBootstrapSettled: onBootstrapSettled,
      readyBuilder: (_) => appBuilder(),
      loadingBuilder: (_) => shell(const AppBootstrapLoadingView(), loading: true),
      failureBuilder: (_, state) => shell(
        AppErrorView(
          error: state.error ?? StateError('Unknown bootstrap failure'),
          stackTrace: state.stackTrace,
          onRetry: () => unawaited(controller.retry()),
          exportDiagnostics: exportDiagnostics,
        ),
        loading: false,
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
    this.showReadyWhileInitializing = false,
    this.initializeAfterFirstFrame = false,
    super.key,
  });

  final AppBootstrapController controller;
  final WidgetBuilder readyBuilder;
  final WidgetBuilder loadingBuilder;
  final AppBootstrapFailureBuilder failureBuilder;
  final bool disposeController;
  final VoidCallback? onBootstrapSettled;
  final bool showReadyWhileInitializing;
  final bool initializeAfterFirstFrame;

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
      if (widget.initializeAfterFirstFrame) {
        final controller = widget.controller;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(widget.controller, controller)) return;
          // The presentation gate releases the native splash after this frame.
          // Start hydration after the following rendered framework frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(widget.controller, controller)) {
              unawaited(controller.initialize());
            }
          });
          WidgetsBinding.instance.scheduleFrame();
        });
      } else {
        unawaited(widget.controller.initialize());
      }
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
    if (widget.showReadyWhileInitializing) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _readyApp ??= widget.readyBuilder(context),
          if (state.phase == AppBootstrapPhase.failure)
            Positioned.fill(child: widget.failureBuilder(context, state)),
        ],
      );
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
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('app_bootstrap_loading'),
    color: Theme.of(context).scaffoldBackgroundColor,
    child: const SizedBox.expand(),
  );
}
