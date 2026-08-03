import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_transitions.dart';
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

  final ValueListenable<int> sectionIndex;
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
    return AppFadeThroughIndexedStack(
      key: const ValueKey<String>('audio_library_section_stack'),
      indexListenable: sectionIndex,
      style: AppIndexedStackTransitionStyle.crossFade,
      children: [
        LibraryTab(
          key: const ValueKey<String>('audio_library_local_page'),
          activeTabIndexListenable: activePageIndex,
          activeSectionListenable: sectionIndex,
          onTitleSwipeLeft: () => _switchSection(asmrSection),
          onTitleSwipeRight: () => _switchSection(asmrSection),
        ),
        AsmrTab(
          key: const ValueKey<String>('audio_library_asmr_page'),
          activeTabIndexListenable: activePageIndex,
          activeSectionListenable: sectionIndex,
          sectionIndex: asmrSection,
          onTitleSwipeLeft: () => _switchSection(localSection),
          onTitleSwipeRight: () => _switchSection(localSection),
        ),
      ],
    );
  }
}
