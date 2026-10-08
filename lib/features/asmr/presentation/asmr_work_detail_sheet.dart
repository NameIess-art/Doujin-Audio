import 'package:flutter/material.dart';

import '../../../app/presentation/work_detail_navigation.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../library/presentation/work_detail_page.dart';
import '../domain/asmr_models.dart';

Future<void> showAsmrWorkDetailSheet(
  BuildContext context,
  AsmrWork work, {
  bool returnToMain = false,
}) async {
  final navigator = Navigator.of(context);
  final origin = ModalRoute.of(context);
  PageRoute<void> buildRoute(BuildContext routeContext) =>
      buildAppPageRoute<void>(
        context: routeContext,
        settings: const RouteSettings(name: workDetailRouteName),
        workDetailTransition: true,
        child: WorkDetailPage.forAsmr(work: work),
      );
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted || !navigator.mounted || origin?.isCurrent == false) {
    return;
  }
  final detailNavigation = WorkDetailNavigationScope.maybeOf(context);
  if (detailNavigation != null &&
      (returnToMain || detailNavigation.canOpenInPane(context))) {
    await detailNavigation.open(
      ('asmr', work.id),
      buildRoute,
      returnToMain: returnToMain,
    );
    return;
  }
  final route = buildRoute(context);
  if (returnToMain) {
    await navigator.pushAndRemoveUntil<void>(route, (route) => route.isFirst);
    return;
  }
  await navigator.push<void>(route);
}
