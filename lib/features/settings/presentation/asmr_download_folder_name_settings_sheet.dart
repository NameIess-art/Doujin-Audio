import '../../../app/presentation/app_presentation_providers.dart';
import 'settings_providers.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
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

  Future<bool> _persistSelection() async {
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
      return false;
    }
    return saved;
  }

  void _remove(AsmrDownloadFolderNameField field) {
    if (_selected.length == 1) return;
    setState(() => _selected.remove(field));
  }

  void _add(AsmrDownloadFolderNameField field) {
    if (_selected.contains(field)) return;
    setState(() => _selected.add(field));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final field = _selected.removeAt(oldIndex);
      _selected.insert(newIndex, field);
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final optionShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppDesignTokens.of(context).radiusCard),
    );
    final unselected = AsmrDownloadFolderNameField.values
        .where((field) => !_selected.contains(field))
        .toList(growable: false);

    return SafeArea(
      child: SizedBox(
        width: double.infinity,
        child: ListView(
          shrinkWrap: true,
          padding: AppBottomSheet.contentPadding,
          children: [
            AppBottomSheetHeader(
              icon: Icons.drive_file_rename_outline,
              iconKey: const ValueKey('asmr_download_folder_name_header_icon'),
              title: i18n.tr('asmr_download_folder_name_setting'),
            ),
            const SizedBox(height: 18),
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
                  shape: optionShape,
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
                  controlAffinity: ListTileControlAffinity.leading,
                  checkboxShape: const CircleBorder(),
                  visualDensity: const VisualDensity(vertical: -1),
                  activeColor: cs.primary,
                  contentPadding: EdgeInsets.zero,
                );
              },
            ),
            for (final field in unselected)
              CheckboxListTile(
                key: ValueKey(('unselected', field)),
                shape: optionShape,
                value: false,
                onChanged: (_) => _add(field),
                title: Text(
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  asmrDownloadFolderNameFieldLabel(i18n, field),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                checkboxShape: const CircleBorder(),
                visualDensity: const VisualDensity(vertical: -1),
                activeColor: cs.primary,
                contentPadding: EdgeInsets.zero,
              ),
            const SizedBox(height: 8),
            SizedBox(
              key: const ValueKey('asmr_download_folder_name_actions'),
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: const ValueKey('asmr_download_folder_name_cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(i18n.tr('cancel')),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const ValueKey('asmr_download_folder_name_confirm'),
                    onPressed: () async {
                      final saved = await _persistSelection();
                      if (saved && context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Text(i18n.tr('confirm')),
                  ),
                ],
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
