import 'package:flutter/material.dart';

import '../../core/widgets/playlist_icon.dart';
import '../theme/app_design_tokens.dart';

enum MainDestinationType { library, asmrOne, playlist, my, settings }

class MainDestination {
  const MainDestination({
    required this.type,
    this.icon,
    this.selectedIcon,
    required this.labelKey,
  });

  final MainDestinationType type;
  final IconData? icon;
  final IconData? selectedIcon;
  final String labelKey;

  Widget buildIcon({
    Key? key,
    required bool selected,
    required double size,
    Color? color,
  }) {
    if (type == MainDestinationType.playlist) {
      return PlaylistIcon(
        key: key,
        filled: selected,
        size: size,
        color: color,
      );
    }
    final glyph = selected ? selectedIcon! : icon!;
    return Icon(
      glyph,
      key: key,
      size: AppDesignTokens.opticalIconSize(glyph, size),
      color: color,
    );
  }
}

List<MainDestination> resolveMainDestinations({
  required bool showLocalLibrary,
  required bool showAsmrOne,
  bool showMyPage = true,
}) {
  return [
    if (showAsmrOne)
      const MainDestination(
        type: MainDestinationType.asmrOne,
        icon: Icons.cloud_outlined,
        selectedIcon: Icons.cloud_rounded,
        labelKey: 'show_asmr_one',
      ),
    if (showLocalLibrary)
      const MainDestination(
        type: MainDestinationType.library,
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music_rounded,
        labelKey: 'music_library',
      ),
    const MainDestination(
      type: MainDestinationType.playlist,
      labelKey: 'nav_sessions',
    ),
    if (showMyPage)
      const MainDestination(
        type: MainDestinationType.my,
        icon: Icons.person_outline_rounded,
        selectedIcon: Icons.person_rounded,
        labelKey: 'nav_my',
      ),
    const MainDestination(
      type: MainDestinationType.settings,
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      labelKey: 'nav_settings',
    ),
  ];
}
