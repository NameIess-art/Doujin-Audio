import 'package:flutter/material.dart';

import 'app_feedback.dart';

class BreadcrumbItem {
  const BreadcrumbItem({
    required this.title,
    this.icon,
    this.onTap,
    this.isCurrent = false,
  });

  final String title;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool isCurrent;
}

class BreadcrumbsBar extends StatelessWidget {
  const BreadcrumbsBar({
    super.key,
    required this.items,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  final List<BreadcrumbItem> items;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    final chips = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isLast = i == items.length - 1;

      chips.add(
        _BreadcrumbChip(
          item: item,
          onTap: item.isCurrent || item.onTap == null
              ? null
              : () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                    context: context,
                  );
                  item.onTap?.call();
                },
        ),
      );

      if (!isLast) {
        chips.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        );
      }
    }

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: false,
              physics: const BouncingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: chips,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _BreadcrumbChip extends StatelessWidget {
  const _BreadcrumbChip({
    required this.item,
    this.onTap,
  });

  final BreadcrumbItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isClickable = onTap != null;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.icon != null) ...[
          Icon(
            item.icon,
            size: 14,
            color: item.isCurrent
                ? cs.primary
                : cs.onSurfaceVariant.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: item.isCurrent ? FontWeight.w700 : FontWeight.w500,
              color: item.isCurrent
                  ? cs.onSurface
                  : (isClickable ? cs.primary : cs.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );

    if (!isClickable) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: content,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: cs.primary.withValues(alpha: 0.08),
        splashColor: cs.primary.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: content,
        ),
      ),
    );
  }
}
