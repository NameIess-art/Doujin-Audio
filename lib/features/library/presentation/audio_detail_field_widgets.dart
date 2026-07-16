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
  });

  final String label;
  final List<String> values;
  final TextStyle? labelStyle;
  final bool busy;
  final VoidCallback? onTap;
  final bool isCapsule;
  final void Function(String)? onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final emptyText = ProviderScope.containerOf(
      context,
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
  const _DetailCapsule({required this.text, this.onCopy});

  final String text;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onLongPress: defaultTargetPlatform == TargetPlatform.android
            ? onCopy
            : null,
        onSecondaryTap: defaultTargetPlatform == TargetPlatform.windows
            ? onCopy
            : null,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurface),
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
  ).read(appLanguageProviderInstanceProvider);
  showAppSnackBar(
    context,
    i18n.tr('copied_to_clipboard', {'value': text}),
    tone: AppFeedbackTone.success,
    icon: Icons.copy_rounded,
  );
}
