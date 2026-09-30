import 'package:flutter/material.dart';
import '../../../app/localization/app_language_provider.dart';

class WorkDetailActions extends StatelessWidget {
  const WorkDetailActions({
    super.key,
    required this.i18n,
    required this.isLocal,
    required this.isFavorite,
    required this.accentColor,
    required this.onFetchInfo,
    required this.onDownload,
    required this.onToggleFavorite,
  });
  final AppLanguageProvider i18n;
  final bool isLocal;
  final bool isFavorite;
  final Color accentColor;
  final VoidCallback onFetchInfo;
  final VoidCallback onDownload;
  final VoidCallback onToggleFavorite;

  Widget _button({
    required String keyName,
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    bool favorite = false,
  }) {
    return Expanded(
      child: FilledButton.tonalIcon(
        key: ValueKey<String>(keyName),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: const StadiumBorder(),
          visualDensity: VisualDensity.standard,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          backgroundColor: favorite ? accentColor.withValues(alpha: 0.2) : null,
          foregroundColor: favorite ? accentColor : null,
        ),
        icon: Icon(icon, size: 18, color: favorite ? accentColor : null),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (isLocal)
        _button(
          keyName: 'work_detail_fetch_info',
          onPressed: onFetchInfo,
          icon: Icons.cloud_download_rounded,
          label: i18n.tr('audio_detail_fetch_info'),
        ),
      if (isLocal) const SizedBox(width: 8),
      _button(
        keyName: isLocal ? 'work_detail_download' : 'asmr_work_detail_download',
        onPressed: onDownload,
        icon: Icons.download_rounded,
        label: i18n.tr('download'),
      ),
      if (!isLocal) ...[
        const SizedBox(width: 8),
        _button(
          keyName: 'asmr_work_detail_favorite',
          onPressed: onToggleFavorite,
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: i18n.tr(
            isFavorite ? 'asmr_unfavorite_action' : 'asmr_favorite_action',
          ),
          favorite: isFavorite,
        ),
      ],
    ],
  );
}
