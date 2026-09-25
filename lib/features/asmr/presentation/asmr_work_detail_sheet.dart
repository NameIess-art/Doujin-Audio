import 'package:flutter/material.dart';

import '../../../core/widgets/app_transitions.dart';
import '../../library/presentation/work_detail_page.dart';
import '../domain/asmr_models.dart';

Future<void> showAsmrWorkDetailSheet(
  BuildContext context,
  AsmrWork work, {
  bool replace = false,
}) {
  final navigator = Navigator.of(context);
  final route = buildAppPageRoute<void>(
    context: context,
    settings: const RouteSettings(name: workDetailRouteName),
    child: WorkDetailPage.forAsmr(work: work),
  );
  if (replace && navigator.canPop()) {
    return navigator.pushAndRemoveUntil(
      route,
      (candidate) => candidate.isFirst,
    );
  }
  return navigator.push(route);
}
