import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../../core/cache/app_cache_service.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';

typedef _CoverSchemeKey = ({
  String path,
  ({String scope, int epoch, int revision}) revision,
  Brightness brightness,
  double contrast,
});

final _coverSchemes = <_CoverSchemeKey, ColorScheme>{};
final _pendingCoverSchemes = <_CoverSchemeKey, Future<ColorScheme>>{};

ColorScheme? _cachedCoverScheme(_CoverSchemeKey key) {
  final scheme = _coverSchemes.remove(key);
  if (scheme != null) _coverSchemes[key] = scheme;
  return scheme;
}

Future<ColorScheme> _loadCoverScheme(_CoverSchemeKey key) {
  final cached = _cachedCoverScheme(key);
  if (cached != null) return SynchronousFuture(cached);
  return _pendingCoverSchemes.putIfAbsent(key, () async {
    final lease = AppCacheService.protectPaths([key.path]);
    try {
      final provider = ResizeImage(
        FileImage(File(key.path)),
        width: 112,
        height: 112,
        policy: ResizeImagePolicy.fit,
      );
      // Manual artwork can replace bytes at the same path. Invalidate only the
      // small extraction image, leaving the displayed cover's cache untouched.
      await provider.evict();
      final scheme = await ColorScheme.fromImageProvider(
        provider: provider,
        brightness: key.brightness,
        contrastLevel: key.contrast,
      );
      _coverSchemes[key] = scheme;
      if (_coverSchemes.length > 32) {
        _coverSchemes.remove(_coverSchemes.keys.first);
      }
      return scheme;
    } finally {
      lease.release();
      unawaited(_pendingCoverSchemes.remove(key));
    }
  });
}

/// Shares artwork colors without owning artwork discovery or playback state.
class SessionDetailTheme extends StatefulWidget {
  const SessionDetailTheme({
    super.key,
    required this.coverPathFuture,
    required this.initialCoverPath,
    required this.requestKey,
    required this.coverRevision,
    required this.queueColorValue,
    required this.child,
    this.transitionActive,
  });

  final Future<String?> coverPathFuture;
  final String? initialCoverPath;
  final Object requestKey;
  final ({String scope, int epoch, int revision}) coverRevision;
  final int? queueColorValue;
  final ValueListenable<bool>? transitionActive;
  final Widget child;

  @override
  State<SessionDetailTheme> createState() => _SessionDetailThemeState();
}

class _SessionDetailThemeState extends State<SessionDetailTheme>
    with SingleTickerProviderStateMixin {
  ColorScheme? _scheme;
  (Brightness, double)? _appearance;
  (ThemeData, ColorScheme?, int?)? _themeInputs;
  ThemeDataTween? _themeTween;
  (ThemeDataTween, double, ThemeData)? _displayedTheme;
  late final AnimationController _themeController;
  late final CurvedAnimation _themeProgress;
  int _request = 0;
  bool _snap = true;
  late final _commitKey = 'detail_palette_${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _themeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1,
    );
    _themeProgress = CurvedAnimation(
      parent: _themeController,
      curve: Curves.easeInOut,
    );
    widget.transitionActive?.addListener(_handleTransition);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appearance = (
      Theme.of(context).brightness,
      MediaQuery.highContrastOf(context) ? 1.0 : 0.0,
    );
    if (_appearance != appearance) {
      _appearance = appearance;
      _scheme = null;
      _updateRequest();
    }
  }

  @override
  void didUpdateWidget(SessionDetailTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionActive != widget.transitionActive) {
      oldWidget.transitionActive?.removeListener(_handleTransition);
      widget.transitionActive?.addListener(_handleTransition);
    }
    if (oldWidget.requestKey != widget.requestKey ||
        oldWidget.coverRevision != widget.coverRevision ||
        oldWidget.initialCoverPath != widget.initialCoverPath ||
        oldWidget.coverPathFuture != widget.coverPathFuture) {
      _updateRequest();
    }
    _handleTransition();
  }

  void _handleTransition() {
    // A full-page theme tick rebuilds its dependents and invalidates the moving
    // content's repaint boundary. Resume from this color after motion settles.
    if (widget.transitionActive?.value == true) {
      _themeController.stop(canceled: false);
    } else if (!_themeController.isCompleted && !_themeController.isAnimating) {
      _themeController.forward();
    }
    UiInteractionCoordinator.instance.scheduleCommitFrame();
  }

  ThemeData _currentTheme() {
    final tween = _themeTween!;
    final progress = _themeProgress.value;
    final displayed = _displayedTheme;
    if (displayed != null &&
        displayed.$1 == tween &&
        displayed.$2 == progress) {
      return displayed.$3;
    }
    final theme = tween.evaluate(_themeProgress);
    _displayedTheme = (tween, progress, theme);
    return theme;
  }

  _CoverSchemeKey _keyFor(String path) => (
    path: path,
    revision: widget.coverRevision,
    brightness: _appearance!.$1,
    contrast: _appearance!.$2,
  );

  void _updateRequest() {
    final request = ++_request;
    final path = widget.initialCoverPath;
    final cached = path == null ? null : _cachedCoverScheme(_keyFor(path));
    if (cached != null) {
      _scheme = cached;
      _snap = true;
    }
    final future = widget.coverPathFuture;
    final revision = widget.coverRevision;
    final appearance = _appearance!;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _commitKey,
      canRun: () => widget.transitionActive?.value != true,
      commit: () => unawaited(_resolve(request, future, revision, appearance)),
    );
  }

  Future<void> _resolve(
    int request,
    Future<String?> future,
    ({String scope, int epoch, int revision}) revision,
    (Brightness, double) appearance,
  ) async {
    ColorScheme? scheme;
    try {
      final path = await future;
      if (!mounted || request != _request) return;
      if (path != null && path.isNotEmpty) {
        scheme = await _loadCoverScheme((
          path: path,
          revision: revision,
          brightness: appearance.$1,
          contrast: appearance.$2,
        ));
      }
    } on Exception {
      // Artwork is optional; unreadable artwork restores this track's fallback.
      scheme = null;
    }
    if (!mounted || request != _request) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _commitKey,
      canRun: () => widget.transitionActive?.value != true,
      commit: () {
        if (!mounted || request != _request || scheme == _scheme) return;
        setState(() {
          _scheme = scheme;
          _snap = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _request++;
    widget.transitionActive?.removeListener(_handleTransition);
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    _themeProgress.dispose();
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final queueColor = widget.queueColorValue;
    final inputs = (base, _scheme, queueColor);
    final snap = _snap || MediaQuery.disableAnimationsOf(context);
    if (_themeInputs != inputs) {
      _themeInputs = inputs;
      // Reuse the complete theme: state-property callbacks use identity
      // equality, so recreating them would animate unchanged colors again.
      final target = _scheme != null
          ? _applyDetailColorScheme(base, _scheme!)
          : queueColor != null
          ? createPlaybackQueueSessionDetailTheme(base, Color(queueColor))
          : base;
      final current = _themeTween == null ? target : _currentTheme();
      _themeTween = ThemeDataTween(begin: current, end: target);
      if (snap) {
        _themeController.value = 1;
      } else {
        _themeController.value = 0;
        if (widget.transitionActive?.value != true) _themeController.forward();
      }
    } else if (snap && !_themeController.isCompleted) {
      _themeController.value = 1;
    }
    return AnimatedBuilder(
      animation: _themeProgress,
      builder: (context, child) => Theme(data: _currentTheme(), child: child!),
      child: widget.child,
    );
  }
}

ThemeData _applyDetailColorScheme(ThemeData base, ColorScheme scheme) {
  InputBorder? inputBorder(InputBorder? border, Color color) =>
      border?.copyWith(borderSide: border.borderSide.copyWith(color: color));
  ShapeBorder? surfaceBorder(ShapeBorder? shape) => shape is OutlinedBorder
      ? shape.copyWith(
          side: shape.side.copyWith(
            color: scheme.outlineVariant.withValues(alpha: shape.side.color.a),
          ),
        )
      : shape;
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    hoverColor: scheme.primary.withValues(alpha: 0.08),
    focusColor: scheme.primary.withValues(alpha: 0.12),
    highlightColor: scheme.primary.withValues(alpha: 0.12),
    textTheme: base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    iconTheme: base.iconTheme.copyWith(color: scheme.onSurface),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
    ),
    cardTheme: base.cardTheme.copyWith(
      color: scheme.surfaceContainerLow,
      shape: surfaceBorder(base.cardTheme.shape),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.42),
      shape: surfaceBorder(base.bottomSheetTheme.shape),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: surfaceBorder(base.dialogTheme.shape),
      titleTextStyle: base.textTheme.headlineSmall?.copyWith(
        color: scheme.onSurface,
      ),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurface,
      ),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: scheme.surfaceContainerHigh,
      shape: surfaceBorder(base.popupMenuTheme.shape),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: scheme.surfaceContainerLow,
      contentTextStyle: base.snackBarTheme.contentTextStyle?.copyWith(
        color: scheme.onSurface,
      ),
    ),
    scrollbarTheme: base.scrollbarTheme.copyWith(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.dragged)) return scheme.primary;
        if (states.contains(WidgetState.hovered)) {
          return scheme.primary.withValues(alpha: 0.7);
        }
        return scheme.outlineVariant.withValues(alpha: 0.5);
      }),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.primary.withValues(alpha: 0.22),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.15),
    ),
    textButtonTheme: TextButtonThemeData(
      style: (base.textButtonTheme.style ?? const ButtonStyle()).merge(
        TextButton.styleFrom(
          foregroundColor: scheme.primary,
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: (base.filledButtonTheme.style ?? const ButtonStyle()).merge(
        FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
          disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: (base.outlinedButtonTheme.style ?? const ButtonStyle()).merge(
        OutlinedButton.styleFrom(
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      textColor: scheme.onSurface,
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        color: scheme.onSurface,
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: scheme.surfaceContainer,
      border: inputBorder(
        base.inputDecorationTheme.border,
        scheme.outlineVariant,
      ),
      enabledBorder: inputBorder(
        base.inputDecorationTheme.enabledBorder,
        scheme.outlineVariant,
      ),
      disabledBorder: inputBorder(
        base.inputDecorationTheme.disabledBorder,
        scheme.outlineVariant,
      ),
      focusedBorder: inputBorder(
        base.inputDecorationTheme.focusedBorder,
        scheme.primary,
      ),
      labelStyle: base.inputDecorationTheme.labelStyle?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      hintStyle: base.inputDecorationTheme.hintStyle?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      helperStyle: base.inputDecorationTheme.helperStyle?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
  );
}

SliderThemeData sessionDetailProgressSliderTheme(
  BuildContext context,
  Color primaryColor,
) => SliderTheme.of(context).copyWith(
  trackHeight: 3,
  thumbShape: const RoundSliderThumbShape(
    enabledThumbRadius: 6,
    elevation: 2,
    pressedElevation: 5,
  ),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
  activeTrackColor: primaryColor,
  inactiveTrackColor: primaryColor.withValues(alpha: 0.22),
  thumbColor: primaryColor,
  overlayColor: primaryColor.withValues(alpha: 0.15),
);

SliderThemeData sessionDetailVolumeSliderTheme(
  BuildContext context, {
  required bool isBoosted,
}) => SliderTheme.of(context).copyWith(
  trackHeight: 6,
  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
  activeTrackColor: isBoosted ? Theme.of(context).colorScheme.primary : null,
);

BoxDecoration sessionDetailPlayButtonDecoration(
  BuildContext context,
  Color primaryColor, {
  required bool enabled,
}) {
  final theme = Theme.of(context);
  return BoxDecoration(
    shape: BoxShape.circle,
    color: enabled ? primaryColor : theme.colorScheme.surfaceContainerHighest,
    boxShadow: enabled
        ? [
            BoxShadow(
              color: primaryColor.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.38 : 0.24,
              ),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ]
        : null,
  );
}

ThemeData createPlaybackQueueSessionDetailTheme(
  ThemeData base,
  Color queueColor,
) {
  final generated = ColorScheme.fromSeed(
    seedColor: queueColor,
    brightness: base.brightness,
  );
  final onQueueColor =
      ThemeData.estimateBrightnessForColor(queueColor) == Brightness.dark
      ? Colors.white
      : const Color(0xFF1B1B1F);
  final scheme = base.colorScheme.copyWith(
    primary: queueColor,
    onPrimary: onQueueColor,
    primaryContainer: generated.primaryContainer,
    onPrimaryContainer: generated.onPrimaryContainer,
    secondary: queueColor,
    onSecondary: onQueueColor,
    secondaryContainer: generated.primaryContainer,
    onSecondaryContainer: generated.onPrimaryContainer,
    surfaceTint: queueColor,
  );
  return _applyDetailColorScheme(base, scheme);
}
