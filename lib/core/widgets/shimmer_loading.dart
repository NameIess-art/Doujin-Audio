import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import 'scroll_activity_gate.dart';

class ShimmerLoader extends StatefulWidget {
  const ShimmerLoader({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<ShimmerLoader> createState() => _ShimmerLoaderState();
}

class _ShimmerLoaderState extends State<ShimmerLoader>
    with SingleTickerProviderStateMixin {
  static const _highlightHalfWidth = 0.15;

  late AnimationController _controller;
  ValueListenable<bool>? _scrollActivity;
  bool _animationAllowed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final activity = ScrollActivityGate.scrollingListenableOf(context);
    if (!identical(activity, _scrollActivity)) {
      _scrollActivity?.removeListener(_syncAnimation);
      _scrollActivity = activity;
      _scrollActivity?.addListener(_syncAnimation);
    }
    _animationAllowed =
        widget.enabled &&
        TickerMode.valuesOf(context).enabled &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ShimmerLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _animationAllowed =
          widget.enabled &&
          TickerMode.valuesOf(context).enabled &&
          !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final shouldRun = _animationAllowed && !(_scrollActivity?.value ?? false);
    if (shouldRun && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldRun && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _scrollActivity?.removeListener(_syncAnimation);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animationAllowed) {
      return widget.child;
    }

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pureBlack = AppDesignTokens.of(context).pureBlack;

    final baseColor = isDark
        ? cs.surfaceContainerHigh
        : cs.surfaceContainerHighest;
    final highlightColor = isDark
        ? Color.lerp(baseColor, cs.onSurface, pureBlack ? 0.14 : 0.08)!
        : cs.surfaceContainer;
    // Keep the placeholder colors when the route enables the shader.
    final clear = highlightColor.withValues(alpha: 0);
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [clear, highlightColor, clear],
      stops: const [0.5 - _highlightHalfWidth, 0.5, 0.5 + _highlightHalfWidth],
    );

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) {
              // Clear both corners at the loop boundary for any aspect ratio.
              const travel = 0.5 + _highlightHalfWidth;
              final offset = (_controller.value * 2 - 1) * travel;
              return gradient.createShader(
                bounds.shift(Offset(bounds.width, bounds.height) * offset),
              );
            },
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

class ShimmerContainer extends StatelessWidget {
  const ShimmerContainer({
    super.key,
    this.width,
    this.height,
    this.borderRadius = 6.0,
    this.color,
  });

  final double? width;
  final double? height;
  final double borderRadius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final baseColor = isDark
        ? cs.surfaceContainerHigh
        : cs.surfaceContainerHighest;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color ?? baseColor,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}
