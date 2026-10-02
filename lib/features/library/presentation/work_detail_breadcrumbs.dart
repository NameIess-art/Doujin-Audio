import 'dart:async';

import 'package:flutter/material.dart';
import '../../../app/localization/app_language_provider.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/windows_horizontal_wheel_scroll.dart';

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
  final _scrollController = ScrollController();
  @override
  void didUpdateWidget(covariant WorkDetailBreadcrumbs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.segments.length <= oldWidget.segments.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
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
    final cs = Theme.of(context).colorScheme;
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
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        unawaited(
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.tap,
                            context: context,
                          ),
                        );
                        widget.onNavigate(-1);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.home_rounded, size: 18, color: cs.primary),
                            const SizedBox(width: 4),
                            Text(
                              widget.i18n.tr('root_directory'),
                              style: TextStyle(
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
                      const Text(' > ', style: TextStyle(color: Colors.grey)),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          unawaited(
                            AppInteractionFeedback.trigger(
                              AppInteractionFeedbackType.tap,
                              context: context,
                            ),
                          );
                          widget.onNavigate(i);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: Text(
                            widget.segments[i],
                            style: TextStyle(
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
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
