import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';

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
  });

  final DlsiteMetadataBatchScope scope;
  final int allCount;
  final int noMetadataCount;
  final int anyMissingCount;
  final int hasRjCodeCount;
  final int specificCount;
  final ValueChanged<DlsiteMetadataBatchScope> onScopeChanged;
  final VoidCallback onPickSpecific;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        AppPageHeaderMetrics.contentTopInset(context),
        16,
        88 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Text(
          i18n.tr('batch_metadata_hint'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: RadioGroup<DlsiteMetadataBatchScope>(
            key: const ValueKey('batch_metadata_scope_group'),
            groupValue: scope,
            onChanged: (value) {
              if (value != null) onScopeChanged(value);
            },
            child: Column(
              children: [
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.anyMissing,
                  title: Text(
                    '${i18n.tr('batch_metadata_any_missing')} ($anyMissingCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.noMetadata,
                  title: Text(
                    '${i18n.tr('batch_metadata_no_metadata')} ($noMetadataCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.hasRjCode,
                  title: Text(
                    '${i18n.tr('batch_metadata_has_rj_code')} ($hasRjCodeCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.specific,
                  title: Text(
                    '${i18n.tr('batch_metadata_specific')} ($specificCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
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
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
