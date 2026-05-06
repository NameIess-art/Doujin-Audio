import 'dart:io';

import 'package:flutter/material.dart';

class PulsingPlaceholder extends StatefulWidget {
  const PulsingPlaceholder({super.key, required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  State<PulsingPlaceholder> createState() => _PulsingPlaceholderState();
}

class _PulsingPlaceholderState extends State<PulsingPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.55,
    end: 0.95,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = FadeTransition(opacity: _opacity, child: widget.child);
    final radius = widget.borderRadius;
    if (radius != null) {
      child = ClipRRect(borderRadius: radius, child: child);
    }
    return child;
  }
}

class AsyncCoverImage extends StatefulWidget {
  const AsyncCoverImage({
    super.key,
    required this.future,
    required this.imageBuilder,
    required this.fallbackBuilder,
    this.loadingBuilder,
  });

  final Future<String?> future;
  final Widget Function(BuildContext context, String path) imageBuilder;
  final WidgetBuilder fallbackBuilder;
  final WidgetBuilder? loadingBuilder;

  @override
  State<AsyncCoverImage> createState() => _AsyncCoverImageState();
}

class _AsyncCoverImageState extends State<AsyncCoverImage> {
  String? _resolvedPath;
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
    future
        .then((path) {
          if (!mounted || token != _token) return;
          if (_resolvedPath == path) return;
          setState(() {
            _resolvedPath = path;
          });
        })
        .catchError((_) {
          if (!mounted || token != _token) return;
          if (_resolvedPath == null) return;
          setState(() {
            _resolvedPath = null;
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    final path = _resolvedPath;
    if (path != null && path.isNotEmpty) {
      return widget.imageBuilder(context, path);
    }
    final loadingBuilder = widget.loadingBuilder;
    if (loadingBuilder != null) {
      return loadingBuilder(context);
    }
    return widget.fallbackBuilder(context);
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
