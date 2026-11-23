import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_buttons.dart';
import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/theme/theme_provider.dart';
import '../../../core/widgets/app_feedback.dart';
import 'library_providers.dart';

Future<void> openLocalContainingFolder(
  BuildContext context,
  WidgetRef ref,
  String targetPath,
) async {
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  final opened = await ref
      .read(libraryFacadeProvider)
      .openContainingFolder(targetPath);
  if (!opened && context.mounted) {
    showAppSnackBar(
      context,
      i18n.tr('operation_failed_retry'),
      tone: AppFeedbackTone.destructive,
    );
  }
}

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
  final VoidCallback? onFetchInfo;
  final VoidCallback? onDownload;
  final VoidCallback onToggleFavorite;

  Widget _button(
    BuildContext context, {
    required String keyName,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    bool isPrimary = false,
    bool favorite = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final onAccentColor = accentColor == cs.primary
        ? cs.onPrimary
        : appReadableOnColor(accentColor);

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
      borderSide = BorderSide(color: accentColor.withValues(alpha: 0.40));
    } else {
      backgroundColor = isDark
          ? cs.surfaceContainerHighest.withValues(alpha: 0.45)
          : cs.surfaceContainerHigh.withValues(alpha: 0.65);
      foregroundColor = cs.onSurface;
      borderSide = BorderSide(
        color: appOverlayBorderColor(cs, tokens),
        width: 0.8,
      );
    }

    final buttonStyle = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shape: const StadiumBorder(),
      side: borderSide,
      elevation: 0,
      shadowColor: Colors.transparent,
      visualDensity: VisualDensity.standard,
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
    );
    return Expanded(
      child: AppLabelledButton(
        FilledButton.tonalIcon,
        key: ValueKey<String>(keyName),
        onPressed: onPressed,
        style: buttonStyle,
        icon: Icon(icon, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (isLocal) ...[
        _button(
          context,
          keyName: 'work_detail_fetch_info',
          onPressed: onFetchInfo,
          icon: Icons.cloud_download_rounded,
          label: i18n.tr('audio_detail_fetch_info'),
        ),
        const SizedBox(width: 8),
      ],
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
