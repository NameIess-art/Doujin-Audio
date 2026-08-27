import 'package:flutter/material.dart';

const appBrandIconAsset = 'assets/icons/app_mark_light.png';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      appBrandIconAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}
