import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/asmr/presentation/asmr_tab.dart';
import '../../features/library/presentation/library_tab.dart';

class AudioLibraryPage extends StatelessWidget {
  const AudioLibraryPage({
    super.key,
    required this.sectionIndex,
    required this.activePageIndex,
    required this.onSectionChanged,
  });

  static const int localSection = 0;
  static const int asmrSection = 1;

  final ValueNotifier<int> sectionIndex;
  final ValueListenable<int> activePageIndex;
  final ValueChanged<int> onSectionChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: sectionIndex,
      builder: (context, selectedSection, _) {
        return IndexedStack(
          key: const ValueKey<String>('audio_library_section_stack'),
          index: selectedSection,
          children: [
            LibraryTab(
              activeTabIndexListenable: activePageIndex,
              activeSectionListenable: sectionIndex,
              onTitleSwipeLeft: () => onSectionChanged(asmrSection),
            ),
            AsmrTab(
              activeSectionListenable: sectionIndex,
              sectionIndex: asmrSection,
              onTitleSwipeRight: () => onSectionChanged(localSection),
            ),
          ],
        );
      },
    );
  }
}
