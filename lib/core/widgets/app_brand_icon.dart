import 'package:flutter/material.dart';

import '../ui/app_icon_color_group.dart';

const appBrandIconLightAsset = 'assets/icons/app_mark_light.png';
const appBrandIconDarkAsset = 'assets/icons/app_mark_dark.png';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asset = theme.brightness == Brightness.dark
        ? appBrandIconDarkAsset
        : appBrandIconLightAsset;
    final gradient =
        theme.extension<AppBrandIconTheme>()?.gradient ??
        AppIconColorGroup.warm.gradient(theme.brightness);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: gradient.createShader,
      child: Image.asset(asset, width: size, height: size, fit: BoxFit.contain),
    );
  }
}
