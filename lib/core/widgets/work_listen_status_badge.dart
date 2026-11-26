import 'package:flutter/material.dart';

import '../media/audio_detail.dart';

String workListenStatusTranslationKey(WorkListenStatus status) =>
    switch (status) {
      WorkListenStatus.marked => 'work_status_marked',
      WorkListenStatus.listening => 'work_status_listening',
      WorkListenStatus.listened => 'work_status_listened',
      WorkListenStatus.replay => 'work_status_replay',
      WorkListenStatus.postponed => 'work_status_postponed',
    };

IconData workListenStatusIcon(WorkListenStatus status) => switch (status) {
  WorkListenStatus.marked => Icons.bookmark_rounded,
  WorkListenStatus.listening => Icons.headphones_rounded,
  WorkListenStatus.listened => Icons.check_circle_rounded,
  WorkListenStatus.replay => Icons.replay_rounded,
  WorkListenStatus.postponed => Icons.pause_circle_filled_rounded,
};

class WorkListenStatusBadge extends StatelessWidget {
  const WorkListenStatusBadge({
    super.key,
    required this.status,
    required this.label,
  });

  final WorkListenStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final Color dotColor = switch (status) {
      WorkListenStatus.marked => const Color(0xFFFFB74D),
      WorkListenStatus.listening => primary,
      WorkListenStatus.listened => const Color(0xFF81C784),
      WorkListenStatus.replay => const Color(0xFFBA68C8),
      WorkListenStatus.postponed => const Color(0xFFB0BEC5),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
