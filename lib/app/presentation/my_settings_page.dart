import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_transitions.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/settings/presentation/settings_providers.dart';
import '../../features/settings/presentation/settings_tab.dart';
import 'app_presentation_providers.dart';
import 'my_page.dart';

class MySettingsPage extends ConsumerStatefulWidget {
  const MySettingsPage({super.key, required this.tabIndex});

  final int tabIndex;

  @override
  ConsumerState<MySettingsPage> createState() => _MySettingsPageState();
}

class _MySettingsPageState extends ConsumerState<MySettingsPage> {
  late final ValueNotifier<int> _pageIndex;

  @override
  void initState() {
    super.initState();
    _pageIndex = ValueNotifier(
      ref.read(settingsRepositoryProvider).slice.state.mySettingsPageMode.index,
    );
  }

  void _switchTo(MySettingsPageMode mode) {
    unawaited(
      saveSettingsWithFeedback(
        context,
        () => ref.read(settingsRepositoryProvider).setMySettingsPageMode(mode),
      ),
    );
  }

  @override
  void dispose() {
    _pageIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      settingsStateProvider.select((state) => state.value?.mySettingsPageMode),
      (_, mode) {
        if (mode != null) _pageIndex.value = mode.index;
      },
    );
    return AppFadeThroughIndexedStack.lazy(
      indexListenable: _pageIndex,
      itemCount: MySettingsPageMode.values.length,
      contentRevision: widget.tabIndex,
      separateHeader: true,
      itemBuilder: (_, index) =>
          MySettingsPageMode.values[index] == MySettingsPageMode.settings
          ? SettingsTab(
              tabIndex: widget.tabIndex,
              onSwitchPage: () => _switchTo(MySettingsPageMode.my),
            )
          : MyPage(
              tabIndex: widget.tabIndex,
              onSwitchPage: () => _switchTo(MySettingsPageMode.settings),
            ),
    );
  }
}
