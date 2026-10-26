import 'package:flutter/material.dart';
import '../../features/settings/application/settings_state.dart';

enum MainDestinationType { library, asmrOne, playlist, settings }

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

  String get navigationKey =>
      type == MainDestinationType.settings ? 'nav_settings' : labelKey;
}

List<MainDestination> resolveMainDestinations({
  required bool showLocalLibrary,
  required bool showAsmrOne,
  MySettingsPageMode mySettingsPageMode = MySettingsPageMode.settings,
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
    MainDestination(
      type: MainDestinationType.settings,
      icon: mySettingsPageMode == MySettingsPageMode.my
          ? Icons.person_outline_rounded
          : Icons.settings_outlined,
      selectedIcon: mySettingsPageMode == MySettingsPageMode.my
          ? Icons.person_rounded
          : Icons.settings_rounded,
      labelKey: mySettingsPageMode == MySettingsPageMode.my
          ? 'nav_my'
          : 'nav_settings',
    ),
  ];
}
