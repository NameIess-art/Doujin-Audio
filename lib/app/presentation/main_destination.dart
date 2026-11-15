import 'package:flutter/material.dart';

enum MainDestinationType { library, asmrOne, playlist, my, settings }

class MainDestination {
  const MainDestination({
    required this.type,
    required this.icon,
    required this.selectedIcon,
    required this.labelKey,
  });

  final MainDestinationType type;
  final IconData icon;
  final IconData selectedIcon;
  final String labelKey;
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
      icon: Icons.playlist_play_rounded,
      selectedIcon: Icons.playlist_play_rounded,
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
