import 'package:flutter/material.dart';

const appBrandIconAsset = 'assets/icons/app_mark_light.png';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({super.key, required this.size, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final cacheWidth = (size * dpr).round().clamp(1, 2048);
    return Image.asset(
      appBrandIconAsset,
      width: size,
      height: size,
      cacheWidth: cacheWidth,
      fit: BoxFit.contain,
      color: color,
      colorBlendMode: BlendMode.srcIn,
    );
  }
}
