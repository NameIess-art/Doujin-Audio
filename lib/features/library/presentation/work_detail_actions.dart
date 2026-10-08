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

  Widget _button(
    BuildContext context, {
    required String keyName,
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    bool isPrimary = false,
    bool favorite = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onAccentColor =
        ThemeData.estimateBrightnessForColor(accentColor) == Brightness.dark
            ? Colors.white
            : const Color(0xFF0F172A);

    final Color backgroundColor;
    final Color foregroundColor;
    final BorderSide borderSide;

    if (isPrimary) {
      backgroundColor = accentColor;
      foregroundColor = onAccentColor;
      borderSide = BorderSide.none;
    } else if (favorite) {
      backgroundColor = accentColor.withValues(alpha: isDark ? 0.22 : 0.16);
      foregroundColor = accentColor;
      borderSide = BorderSide(
        color: accentColor.withValues(alpha: 0.40),
      );
    } else {
      backgroundColor = isDark
          ? cs.surfaceContainerHighest.withValues(alpha: 0.45)
          : cs.surfaceContainerHigh.withValues(alpha: 0.65);
      foregroundColor = cs.onSurface;
      borderSide = BorderSide(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.30 : 0.45),
        width: 0.8,
      );
    }

    return Expanded(
      child: FilledButton.tonalIcon(
        key: ValueKey<String>(keyName),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: const StadiumBorder(),
          side: borderSide,
          elevation: isPrimary ? 1.5 : 0,
          shadowColor: isPrimary
              ? accentColor.withValues(alpha: isDark ? 0.35 : 0.25)
              : Colors.transparent,
          visualDensity: VisualDensity.standard,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
        ),
        icon: Icon(icon, size: 18, color: foregroundColor),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (isLocal)
        _button(
          context,
          keyName: 'work_detail_fetch_info',
          onPressed: onFetchInfo,
          icon: Icons.cloud_download_rounded,
          label: i18n.tr('audio_detail_fetch_info'),
        ),
      if (isLocal) const SizedBox(width: 8),
      _button(
        context,
        keyName: isLocal ? 'work_detail_download' : 'asmr_work_detail_download',
        onPressed: onDownload,
        icon: Icons.download_rounded,
        label: i18n.tr('download'),
        isPrimary: true,
      ),
      if (!isLocal) ...[
        const SizedBox(width: 8),
        _button(
          context,
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
