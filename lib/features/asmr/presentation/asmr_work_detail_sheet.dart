import 'package:flutter/material.dart';

import '../../../core/widgets/app_transitions.dart';
import '../../library/presentation/work_detail_page.dart';
import '../domain/asmr_models.dart';

Future<void> showAsmrWorkDetailSheet(BuildContext context, AsmrWork work) {
  return Navigator.of(context).push(
    buildAppPageRoute<void>(
      context: context,
      style: AppPageTransitionStyle.sharedAxisZ,
      child: WorkDetailPage.forAsmr(work: work),
    ),
  );
}
