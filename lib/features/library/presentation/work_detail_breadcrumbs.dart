import 'package:flutter/material.dart';
import '../../../app/localization/app_language_provider.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';

class WorkDetailBreadcrumbs extends StatefulWidget {
  const WorkDetailBreadcrumbs({
    super.key,
    required this.segments,
    required this.entryCount,
    required this.i18n,
    required this.onNavigate,
  });
  final List<String> segments;
  final int entryCount;
  final AppLanguageProvider i18n;
  final ValueChanged<int> onNavigate;
  @override
  State<WorkDetailBreadcrumbs> createState() => _WorkDetailBreadcrumbsState();
}

class _WorkDetailBreadcrumbsState extends State<WorkDetailBreadcrumbs> {
  final _scrollController = WindowsSmoothScrollController();
  @override
  void didUpdateWidget(covariant WorkDetailBreadcrumbs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.segments.length <= oldWidget.segments.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        final target = _scrollController.position.maxScrollExtent;
        if (MediaQuery.disableAnimationsOf(context)) {
          _scrollController.jumpTo(target);
        } else {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final itemRadius = BorderRadius.circular(tokens.radiusSmall);
    return Row(
      children: [
        Expanded(
          child: Material(
            color: Colors.transparent,
            child: WindowsHorizontalWheelScroll(
              controller: _scrollController,
              builder: (scrollController) => SingleChildScrollView(
                controller: scrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppEntryInkWell(
                      borderRadius: itemRadius,
                      onTap: () => widget.onNavigate(-1),
                      child: Ink(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: itemRadius,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.home_rounded, size: 16, color: cs.primary),
                            const SizedBox(width: 4),
                            Text(
                              widget.i18n.tr('root_directory'),
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    for (var i = 0; i < widget.segments.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      AppEntryInkWell(
                        borderRadius: itemRadius,
                        onTap: () => widget.onNavigate(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: WorkPageTranslationText(
                            widget.segments[i],
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: i == widget.segments.length - 1
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: i == widget.segments.length - 1
                                  ? cs.onSurface
                                  : cs.primary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          widget.i18n.tr('items_count', {'count': widget.entryCount}),
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
