import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';

enum DlsiteMetadataBatchScope {
  anyMissing,
  noMetadata,
  hasRjCode,
  all,
  specific,
}

class BatchMetadataSetupView extends StatelessWidget {
  const BatchMetadataSetupView({
    super.key,
    required this.scope,
    required this.allCount,
    required this.noMetadataCount,
    required this.anyMissingCount,
    required this.hasRjCodeCount,
    required this.specificCount,
    required this.onScopeChanged,
    required this.onPickSpecific,
    this.topInset,
  });

  final DlsiteMetadataBatchScope scope;
  final int allCount;
  final int noMetadataCount;
  final int anyMissingCount;
  final int hasRjCodeCount;
  final int specificCount;
  final ValueChanged<DlsiteMetadataBatchScope> onScopeChanged;
  final VoidCallback onPickSpecific;
  final double? topInset;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final optionTextStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        topInset ?? AppPageHeaderMetrics.firstContentSpacing,
        16,
        88 +
            MediaQuery.paddingOf(context).bottom +
            MobileOverlayInset.of(context),
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: tokens.readableContentMaxWidth,
            ),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              color: cs.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(tokens.radiusSection),
                side: BorderSide(
                  color: cs.outlineVariant.withValues(
                    alpha: tokens.standardBorderAlpha,
                  ),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: RadioGroup<DlsiteMetadataBatchScope>(
                key: const ValueKey('batch_metadata_scope_group'),
                groupValue: scope,
                onChanged: (value) {
                  if (value != null && value != scope) {
                    unawaited(
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.selection,
                      ),
                    );
                    onScopeChanged(value);
                  }
                },
                child: Theme(
                  data: AppEntryInkWell.entryTheme(context),
                  child: Column(
                    children: [
                      RadioListTile<DlsiteMetadataBatchScope>(
                        value: DlsiteMetadataBatchScope.anyMissing,
                        title: Text(
                          '${i18n.tr('batch_metadata_any_missing')} ($anyMissingCount)',
                          style: optionTextStyle,
                        ),
                      ),
                      RadioListTile<DlsiteMetadataBatchScope>(
                        value: DlsiteMetadataBatchScope.noMetadata,
                        title: Text(
                          '${i18n.tr('batch_metadata_no_metadata')} ($noMetadataCount)',
                          style: optionTextStyle,
                        ),
                      ),
                      RadioListTile<DlsiteMetadataBatchScope>(
                        value: DlsiteMetadataBatchScope.hasRjCode,
                        title: Text(
                          '${i18n.tr('batch_metadata_has_rj_code')} ($hasRjCodeCount)',
                          style: optionTextStyle,
                        ),
                      ),
                      RadioListTile<DlsiteMetadataBatchScope>(
                        value: DlsiteMetadataBatchScope.specific,
                        title: Text(
                          '${i18n.tr('batch_metadata_specific')} ($specificCount)',
                          style: optionTextStyle,
                        ),
                        secondary: scope == DlsiteMetadataBatchScope.specific
                            ? IconButton(
                                icon: const Icon(Icons.edit_rounded),
                                onPressed: onPickSpecific,
                              )
                            : null,
                      ),
                      RadioListTile<DlsiteMetadataBatchScope>(
                        value: DlsiteMetadataBatchScope.all,
                        title: Text(
                          '${i18n.tr('batch_metadata_all')} ($allCount)',
                          style: optionTextStyle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ).withWindowsSmoothScroll();
  }
}
