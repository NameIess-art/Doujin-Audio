import 'package:flutter/material.dart';

const appBrandIconLightAsset = 'assets/icons/app_mark_light.png';
const appBrandIconDarkAsset = 'assets/icons/app_mark_dark.png';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = Theme.of(context).brightness == Brightness.dark
        ? appBrandIconDarkAsset
        : appBrandIconLightAsset;
    return Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
  }
}
