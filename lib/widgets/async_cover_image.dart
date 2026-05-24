import 'dart:io';

import 'package:flutter/material.dart';

class PulsingPlaceholder extends StatelessWidget {
  const PulsingPlaceholder({super.key, required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    final radius = borderRadius;
    if (radius != null) {
      result = ClipRRect(borderRadius: radius, child: result);
    }
    return result;
  }
}

class AsyncCoverImage extends StatefulWidget {
  const AsyncCoverImage({
    super.key,
    required this.future,
    required this.imageBuilder,
    required this.fallbackBuilder,
    this.loadingBuilder,
    this.duration = const Duration(milliseconds: 600),
  });

  final Future<String?> future;
  final Widget Function(BuildContext context, String path) imageBuilder;
  final WidgetBuilder fallbackBuilder;
  final WidgetBuilder? loadingBuilder;
  final Duration duration;

  @override
  State<AsyncCoverImage> createState() => _AsyncCoverImageState();
}

class _AsyncCoverImageState extends State<AsyncCoverImage> {
  String? _resolvedPath;
  bool _isResolved = false;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _bindFuture(widget.future);
  }

  @override
  void didUpdateWidget(covariant AsyncCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.future, widget.future)) {
      _bindFuture(widget.future);
    }
  }

  void _bindFuture(Future<String?> future) {
    final token = ++_token;
    if (mounted) {
      setState(() {
        _resolvedPath = null;
        _isResolved = false;
      });
    } else {
      _resolvedPath = null;
      _isResolved = false;
    }
    future
        .then((path) {
          if (!mounted || token != _token) return;
          setState(() {
            _resolvedPath = path;
            _isResolved = true;
          });
        })
        .catchError((_) {
          if (!mounted || token != _token) return;
          setState(() {
            _resolvedPath = null;
            _isResolved = true;
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_resolvedPath != null && _resolvedPath!.isNotEmpty) {
      content = widget.imageBuilder(context, _resolvedPath!);
    } else if (!_isResolved) {
      final loadingBuilder = widget.loadingBuilder;
      content = loadingBuilder != null
          ? loadingBuilder(context)
          : const CoverLoadingIndicator();
    } else {
      content = widget.fallbackBuilder(context);
    }

    if (widget.duration == Duration.zero) {
      return SizedBox.expand(
        key: ValueKey('$_resolvedPath$_isResolved'),
        child: content,
      );
    }

    return AnimatedSwitcher(
      duration: widget.duration,
      switchInCurve: Curves.easeInOutSine,
      switchOutCurve: Curves.easeInOutSine,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: SizedBox.expand(
        key: ValueKey('$_resolvedPath$_isResolved'),
        child: content,
      ),
    );
  }
}

class CoverLoadingIndicator extends StatelessWidget {
  const CoverLoadingIndicator({
    super.key,
    this.size = 32,
    this.strokeWidth = 2.8,
    this.color,
  });

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          strokeWidth: strokeWidth,
          color: color ?? cs.primary,
        ),
      ),
    );
  }
}

ImageProvider<Object> resizeFileImageIfNeeded({
  required String path,
  int? cacheWidth,
  int? cacheHeight,
}) {
  final provider = FileImage(File(path));
  return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, provider);
}
