part of 'audio_detail_sheet.dart';

enum _AudioDetailFetchScope { all, missing }

class _AudioDetailFetchScopeDialog extends StatelessWidget {
  const _AudioDetailFetchScopeDialog();

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    return AppDialog(
      title: i18n.tr('audio_detail_fetch_scope_title'),
      icon: Icons.download_rounded,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            tileColor: cs.surfaceContainer,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: const Icon(Icons.select_all_rounded),
            title: Text(i18n.tr('batch_metadata_all')),
            onTap: () => Navigator.of(context).pop(_AudioDetailFetchScope.all),
          ),
          const SizedBox(height: 4),
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            tileColor: cs.surfaceContainer,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: const Icon(Icons.playlist_add_check_rounded),
            title: Text(i18n.tr('metadata_scope_missing')),
            onTap: () =>
                Navigator.of(context).pop(_AudioDetailFetchScope.missing),
          ),
        ],
      ),
    );
  }
}

enum _AudioDetailField {
  targetName,
  rjCode,
  workTitle,
  circleName,
  voiceActors,
  tags,
  releaseDate,
  duration,
  salesCount,
  rating;

  bool get isMulti =>
      this == _AudioDetailField.voiceActors || this == _AudioDetailField.tags;

  String label(AppLanguageProvider i18n, AudioDetail detail) {
    return switch (this) {
      _AudioDetailField.targetName =>
        detail.target.isLibraryRootFolder
            ? i18n.tr('audio_detail_folder_name')
            : i18n.tr('audio_detail_file_name'),
      _AudioDetailField.rjCode => i18n.tr('audio_detail_rj_code'),
      _AudioDetailField.workTitle => i18n.tr('audio_detail_work_title'),
      _AudioDetailField.circleName => i18n.tr('audio_detail_circle_name'),
      _AudioDetailField.voiceActors => i18n.tr('audio_detail_voice_actors'),
      _AudioDetailField.tags => i18n.tr('audio_detail_tags'),
      _AudioDetailField.releaseDate => i18n.tr('audio_detail_release_date'),
      _AudioDetailField.duration => i18n.tr('card_info_duration'),
      _AudioDetailField.salesCount => i18n.tr('audio_detail_sales_count'),
      _AudioDetailField.rating => i18n.tr('audio_detail_rating'),
    };
  }

  String readText(AudioDetail detail, {Duration? fallbackDuration}) {
    return switch (this) {
      _AudioDetailField.targetName => _targetDisplayName(detail.target),
      _AudioDetailField.rjCode => detail.rjCode,
      _AudioDetailField.workTitle => detail.workTitle,
      _AudioDetailField.circleName => detail.circleName,
      _AudioDetailField.voiceActors => detail.voiceActors.join(
        _multiValueSeparator,
      ),
      _AudioDetailField.tags => detail.tags.join(_multiValueSeparator),
      _AudioDetailField.releaseDate =>
        detail.releaseDate == null ? '' : formatDateYmd(detail.releaseDate!),
      _AudioDetailField.duration =>
        detail.duration != null
            ? formatDurationHms(detail.duration!)
            : (fallbackDuration != null
                  ? formatDurationHms(fallbackDuration)
                  : ''),
      _AudioDetailField.salesCount => detail.salesCount?.toString() ?? '',
      _AudioDetailField.rating => formatLibraryLikeRating(detail.rating),
    };
  }

  List<String> readList(AudioDetail detail) {
    return switch (this) {
      _AudioDetailField.voiceActors => detail.voiceActors,
      _AudioDetailField.tags => detail.tags,
      _ => const <String>[],
    };
  }

  List<String> readValues(AudioDetail detail, {Duration? fallbackDuration}) {
    return isMulti
        ? readList(detail)
        : [readText(detail, fallbackDuration: fallbackDuration)];
  }

  AudioDetail apply(AudioDetail detail, String rawValue) {
    final trimmed = rawValue.trim();
    return switch (this) {
      _AudioDetailField.targetName => detail,
      _AudioDetailField.rjCode => detail.copyWith(
        rjCode: trimmed.toUpperCase(),
      ),
      _AudioDetailField.workTitle => detail.copyWith(workTitle: trimmed),
      _AudioDetailField.circleName => detail.copyWith(circleName: trimmed),
      _AudioDetailField.voiceActors => detail.copyWith(
        voiceActors: _splitMultiValue(rawValue),
      ),
      _AudioDetailField.tags => detail.copyWith(
        tags: _splitMultiValue(rawValue),
      ),
      _AudioDetailField.releaseDate => detail.copyWith(
        releaseDate: parseDateYmd(trimmed),
      ),
      _AudioDetailField.duration => detail.copyWith(
        duration: parseDurationCompact(trimmed),
      ),
      _AudioDetailField.salesCount => detail.copyWith(
        salesCount: trimmed.isEmpty ? null : int.tryParse(trimmed),
      ),
      _AudioDetailField.rating => detail.copyWith(
        rating: trimmed.isEmpty ? null : double.tryParse(trimmed),
      ),
    };
  }
}

String _targetDisplayName(AudioDetailTarget target) {
  return target.isLibraryRootFolder
      ? PathDisplay.folderName(target.targetPath)
      : PathDisplay.fileName(target.targetPath, withoutExtension: true);
}

List<String> _splitMultiValue(String rawValue) {
  return AudioDetail.normalizeList(rawValue.split(_multiValueSeparator));
}

bool _looksLikeRjCode(String value) {
  return value.isEmpty || RegExp(r'^RJ\d+$').hasMatch(value);
}
