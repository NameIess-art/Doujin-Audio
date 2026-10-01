import '../../../app/presentation/app_presentation_providers.dart';
import 'settings_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../asmr/domain/asmr_download.dart';

class AsmrDownloadFolderNameSettingsSheet extends ConsumerStatefulWidget {
  const AsmrDownloadFolderNameSettingsSheet({super.key});

  @override
  ConsumerState<AsmrDownloadFolderNameSettingsSheet> createState() =>
      _AsmrDownloadFolderNameSettingsSheetState();
}

class _AsmrDownloadFolderNameSettingsSheetState
    extends ConsumerState<AsmrDownloadFolderNameSettingsSheet> {
  late final List<AsmrDownloadFolderNameField> _selected;

  @override
  void initState() {
    super.initState();
    _selected = ref
        .read(settingsRepositoryProvider)
        .asmrDownloadFolderNameFields
        .toList(growable: true);
  }

  Future<void> _persistSelection() async {
    final snapshot = List<AsmrDownloadFolderNameField>.unmodifiable(_selected);
    final saved = await saveSettingsWithFeedback(
      context,
      () => ref
          .read(settingsRepositoryProvider)
          .setAsmrDownloadFolderNameFields(snapshot),
    );
    if (!saved && mounted) {
      setState(() {
        _selected
          ..clear()
          ..addAll(
            ref.read(settingsRepositoryProvider).asmrDownloadFolderNameFields,
          );
      });
    }
  }

  void _remove(AsmrDownloadFolderNameField field) {
    if (_selected.length == 1) return;
    setState(() => _selected.remove(field));
    unawaited(_persistSelection());
  }

  void _add(AsmrDownloadFolderNameField field) {
    if (_selected.contains(field)) return;
    setState(() => _selected.add(field));
    unawaited(_persistSelection());
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final field = _selected.removeAt(oldIndex);
      _selected.insert(newIndex, field);
    });
    unawaited(_persistSelection());
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final unselected = AsmrDownloadFolderNameField.values
        .where((field) => !_selected.contains(field))
        .toList(growable: false);

    return SafeArea(
      child: SizedBox(
        width: double.infinity,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            Text(
              i18n.tr('asmr_download_folder_name_setting'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              i18n.tr('asmr_download_folder_name_hint'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _selected.length,
              onReorder: _reorder,
              itemBuilder: (context, index) {
                final field = _selected[index];
                return CheckboxListTile(
                  key: ValueKey(('selected', field)),
                  value: true,
                  onChanged: _selected.length > 1
                      ? (_) => _remove(field)
                      : null,
                  title: Text(
                    softWrap: true,
                    overflow: TextOverflow.visible,
                    asmrDownloadFolderNameFieldLabel(i18n, field),
                  ),
                  secondary: ReorderableDragStartListener(
                    index: index,
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                );
              },
            ),
            for (final field in unselected)
              CheckboxListTile(
                key: ValueKey(('unselected', field)),
                value: false,
                onChanged: (_) => _add(field),
                title: Text(
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  asmrDownloadFolderNameFieldLabel(i18n, field),
                ),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(i18n.tr('done')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String asmrDownloadFolderNameFieldLabel(
  AppLanguageProvider i18n,
  AsmrDownloadFolderNameField field,
) {
  return switch (field) {
    AsmrDownloadFolderNameField.rjCode => i18n.tr(
      'asmr_download_folder_field_rj_code',
    ),
    AsmrDownloadFolderNameField.voiceActors => i18n.tr(
      'asmr_download_folder_field_voice_actors',
    ),
    AsmrDownloadFolderNameField.circleName => i18n.tr(
      'asmr_download_folder_field_circle_name',
    ),
    AsmrDownloadFolderNameField.workTitle => i18n.tr(
      'asmr_download_folder_field_work_title',
    ),
  };
}
