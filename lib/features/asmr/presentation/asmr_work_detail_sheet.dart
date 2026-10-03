import 'package:flutter/material.dart';

import '../../../core/widgets/app_transitions.dart';
import '../../library/presentation/work_detail_page.dart';
import '../domain/asmr_models.dart';

Future<void> showAsmrWorkDetailSheet(
  BuildContext context,
  AsmrWork work, {
  bool replace = false,
}) async {
  final navigator = Navigator.of(context);
  final origin = ModalRoute.of(context);
  final route = buildAppPageRoute<void>(
    context: context,
    settings: const RouteSettings(name: workDetailRouteName),
    wholePageTransition: true,
    child: WorkDetailPage.forAsmr(work: work),
  );
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted || !navigator.mounted || origin?.isCurrent == false) return;
  if (replace && navigator.canPop()) {
    await navigator.pushReplacement<void, void>(route);
    return;
  }
  await navigator.push<void>(route);
}
