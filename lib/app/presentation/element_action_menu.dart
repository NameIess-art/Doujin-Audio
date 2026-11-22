import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/widgets/app_search_page.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/unified_popup_menu.dart';
import '../../features/asmr/presentation/asmr_tab.dart';
import '../../features/library/presentation/library_search_page.dart';
import '../../features/player/presentation/playlist/session_detail_route.dart';
import '../localization/app_language_en.dart';
import '../localization/app_language_ja.dart';
import '../localization/app_language_zh.dart';
import '../theme/app_design_tokens.dart';
import 'work_detail_navigation.dart';

enum _ElementAction {
  onlineSearch('element_online_search', Icons.travel_explore_rounded),
  localSearch('element_local_search', Icons.search_rounded),
  copy('element_copy', Icons.content_copy_rounded);

  const _ElementAction(this.labelKey, this.icon);
  final String labelKey;
  final IconData icon;
}

class ElementActionMenu extends StatelessWidget {
  const ElementActionMenu({
    super.key,
    required this.value,
    required this.onCopy,
    required this.child,
    this.shape,
  });

  final String value;
  final VoidCallback onCopy;
  final Widget child;
  final ShapeBorder? shape;

  Future<void> _runAction(BuildContext context, _ElementAction action) async {
    final searchPage = switch (action) {
      _ElementAction.onlineSearch => AsmrSearchPage(initialQuery: value),
      _ElementAction.localSearch => LibrarySearchPage(initialQuery: value),
      _ElementAction.copy => null,
    };
    if (searchPage == null) {
      onCopy();
      return;
    }
    final origin = readAppRoute(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    final keepDetailPane =
        !(origin is SessionDetailRoute && origin.requiresPortraitRestore) &&
        WorkDetailNavigationScope.isLandscapeOf(context);
    // Rotating back can dispose this inline element while its route stays alive.
    if (origin is SessionDetailRoute) await origin.prepareForExit();
    if (!navigator.mounted ||
        (origin is SessionDetailRoute && !origin.isCurrent)) {
      return;
    }
    PageRoute<void> buildSearchRoute(BuildContext routeContext) =>
        buildAppSearchPageRoute(
          context: routeContext,
          child: searchPage,
        );

    if (navigation != null) {
      await navigation.openFromMain(
        buildSearchRoute,
        keepDetailPane: keepDetailPane,
      );
      return;
    }
    await navigator.pushAndRemoveUntil<void>(
      buildSearchRoute(navigator.context),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (value.trim().isEmpty) return child;
    final labels = switch (Localizations.localeOf(context).languageCode) {
      'zh' => appLanguageZh,
      'ja' => appLanguageJa,
      _ => appLanguageEn,
    };
    final resolvedShape =
        shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            AppDesignTokens.of(context).radiusSmall,
          ),
        );
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final Widget content = isWindows
        ? MouseRegion(cursor: SystemMouseCursors.contextMenu, child: child)
        : child;
    return UnifiedContextMenuRegion(
      key: ValueKey(value),
      shape: resolvedShape,
      skipTraversal: true,
      openOnAndroidLongPress: true,
      buildEntries: () => [
        for (final action in _ElementAction.values)
          UnifiedMenuEntry.action(
            value: () => unawaited(_runAction(context, action)),
            label: labels[action.labelKey]!,
            icon: action.icon,
          ),
      ],
      child: content,
    );
  }
}
