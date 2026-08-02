import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/app_feedback.dart';
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

  void _switchSection(int index) {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    onSectionChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return ValueListenableBuilder<int>(
      valueListenable: sectionIndex,
      builder: (context, selectedSection, _) {
        return Stack(
          key: const ValueKey<String>('audio_library_section_stack'),
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              key: const ValueKey<String>('audio_library_local_fade'),
              opacity: selectedSection == localSection ? 1 : 0,
              duration: duration,
              curve: Curves.easeInOutCubic,
              child: IgnorePointer(
                ignoring: selectedSection != localSection,
                child: ExcludeSemantics(
                  excluding: selectedSection != localSection,
                  child: LibraryTab(
                    activeTabIndexListenable: activePageIndex,
                    activeSectionListenable: sectionIndex,
                    onTitleSwipeLeft: () => _switchSection(asmrSection),
                    onTitleSwipeRight: () => _switchSection(asmrSection),
                  ),
                ),
              ),
            ),
            AnimatedOpacity(
              key: const ValueKey<String>('audio_library_asmr_fade'),
              opacity: selectedSection == asmrSection ? 1 : 0,
              duration: duration,
              curve: Curves.easeInOutCubic,
              child: IgnorePointer(
                ignoring: selectedSection != asmrSection,
                child: ExcludeSemantics(
                  excluding: selectedSection != asmrSection,
                  child: AsmrTab(
                    activeTabIndexListenable: activePageIndex,
                    activeSectionListenable: sectionIndex,
                    sectionIndex: asmrSection,
                    onTitleSwipeLeft: () => _switchSection(localSection),
                    onTitleSwipeRight: () => _switchSection(localSection),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
