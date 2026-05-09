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
    setState(() {
      _isResolved = false;
    });
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
    if (_resolvedPath != null && _resolvedPath!.isNotEmpty) {
      return widget.imageBuilder(context, _resolvedPath!);
    }
    
    if (!_isResolved) {
      final loadingBuilder = widget.loadingBuilder;
      if (loadingBuilder != null) {
        return loadingBuilder(context);
      }
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
