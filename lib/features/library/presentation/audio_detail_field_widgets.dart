part of 'audio_detail_sheet.dart';

class _AudioDetailRow extends StatelessWidget {
  const _AudioDetailRow({
    required this.label,
    required this.values,
    required this.labelStyle,
    required this.busy,
    this.onTap,
    this.isCapsule = false,
    this.onCopy,
    this.onDeleteValue,
  });

  final String label;
  final List<String> values;
  final TextStyle? labelStyle;
  final bool busy;
  final VoidCallback? onTap;
  final bool isCapsule;
  final void Function(String)? onCopy;
  final void Function(String)? onDeleteValue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final emptyText = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider).tr('audio_detail_empty');
    final displayValues =
        values.isEmpty || (values.length == 1 && values.first.isEmpty)
        ? [emptyText]
        : values;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: labelStyle),
              const Spacer(),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (onTap != null)
                IconButton(
                  onPressed: onTap,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size.zero,
                  ),
                  icon: Icon(Icons.edit_rounded, color: cs.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (isCapsule)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: displayValues
                  .map(
                    (v) => _DetailCapsule(
                      text: v,
                      onCopy: onCopy != null && v != emptyText
                          ? () => onCopy!(v)
                          : null,
                      onDelete: onDeleteValue != null && v != emptyText && !busy
                          ? () => onDeleteValue!(v)
                          : null,
                    ),
                  )
                  .toList(),
            )
          else
            Text(
              displayValues.join('\uFF0C'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: displayValues.first == emptyText
                    ? cs.onSurfaceVariant
                    : cs.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailCapsule extends StatelessWidget {
  const _DetailCapsule({required this.text, this.onCopy, this.onDelete});

  final String text;
  final VoidCallback? onCopy;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onSecondaryTap: defaultTargetPlatform == TargetPlatform.windows
            ? onCopy
            : null,
        onLongPress: defaultTargetPlatform == TargetPlatform.android
            ? onCopy
            : null,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: EdgeInsets.only(
            left: 12,
            top: onDelete != null ? 3 : 6,
            bottom: onDelete != null ? 3 : 6,
            right: onDelete != null ? 4 : 12,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: cs.onSurface),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 20,
                    height: 20,
                  ),
                  tooltip:
                      MaterialLocalizations.of(context).deleteButtonTooltip,
                  icon: Icon(
                    Icons.close_rounded,
                    color: cs.onSurfaceVariant,
                  ),
                  onPressed: onDelete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _copyText(BuildContext context, String value) async {
  final text = value.trim();
  if (text.isEmpty) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) {
    return;
  }
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  showAppSnackBar(
    context,
    i18n.tr('copied_to_clipboard', {'value': text}),
    tone: AppFeedbackTone.success,
    icon: Icons.copy_rounded,
  );
}
