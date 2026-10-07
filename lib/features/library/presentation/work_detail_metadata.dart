import 'package:flutter/material.dart';
import '../../../core/widgets/windows_horizontal_wheel_scroll.dart';
import 'page_translation_scope.dart';

const double _workMetadataCapsuleRadius = 14;
const EdgeInsets _workMetadataCapsulePadding = EdgeInsets.symmetric(
  horizontal: 10,
  vertical: 4,
);

class WorkDetailMetadata extends StatelessWidget {
  const WorkDetailMetadata({
    super.key,
    required this.voiceActors,
    required this.tags,
    required this.onCopy,
  });
  final List<String> voiceActors;
  final List<String> tags;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Voice Actors row
        if (voiceActors.isNotEmpty) ...[
          Row(
            children: [
              Icon(Icons.badge_outlined, size: 17, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: _buildVoiceActorScroller(context, cs, voiceActors),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],

        // Tags row
        if (tags.isNotEmpty) ...[
          Row(
            children: [
              Icon(
                Icons.local_offer_outlined,
                size: 17,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(child: _buildTagScroller(context, cs, tags)),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildVoiceActorCapsule(
    BuildContext context,
    ColorScheme cs,
    String voiceActor,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: voiceActor,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('work_detail_voice_actor_$voiceActor'),
          onTap: () => onCopy(voiceActor),
          borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
          child: Container(
            padding: _workMetadataCapsulePadding,
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(
                alpha: isDark ? 0.34 : 0.56,
              ),
              borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
              border: Border.all(
                color: cs.primary.withValues(alpha: isDark ? 0.28 : 0.20),
              ),
            ),
            child: Text(
              voiceActor,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagCapsule(BuildContext context, ColorScheme cs, String tag) {
    final displayLabel = tag.startsWith('#') ? tag : '#$tag';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('work_detail_tag_$displayLabel'),
        onTap: () => onCopy(tag.startsWith('#') ? tag.substring(1) : tag),
        borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
        child: Container(
          padding: _workMetadataCapsulePadding,
          decoration: BoxDecoration(
            color: isDark
                ? cs.surfaceContainerHighest.withValues(alpha: 0.5)
                : cs.surfaceContainerHigh.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.3 : 0.45),
            ),
          ),
          child: WorkPageTranslationText(
            tag.startsWith('#') ? tag.substring(1) : tag,
            prefix: '#',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagScroller(
    BuildContext context,
    ColorScheme cs,
    List<String> tags,
  ) {
    return _buildMetadataScroller(
      context,
      keyPrefix: 'tag',
      items: tags,
      gap: 6,
      itemBuilder: (tag) => _buildTagCapsule(context, cs, tag),
    );
  }

  Widget _buildVoiceActorScroller(
    BuildContext context,
    ColorScheme cs,
    List<String> voiceActors,
  ) {
    return _buildMetadataScroller(
      context,
      keyPrefix: 'voice_actor',
      items: voiceActors,
      gap: 8,
      itemBuilder: (voiceActor) =>
          _buildVoiceActorCapsule(context, cs, voiceActor),
    );
  }

  Widget _buildMetadataScroller(
    BuildContext context, {
    required String keyPrefix,
    required List<String> items,
    required double gap,
    required Widget Function(String) itemBuilder,
  }) {
    final lineHeight = Theme.of(context).textTheme.bodyMedium?.height ?? 1.5;
    final height =
        MediaQuery.textScalerOf(context).scale(12) * lineHeight +
        _workMetadataCapsulePadding.vertical +
        2;
    return ShaderMask(
      key: ValueKey<String>('work_detail_${keyPrefix}_edge_fade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0, 0.06, 0.94, 1],
      ).createShader(bounds),
      child: WindowsHorizontalWheelScroll(
        builder: (scrollController) => SizedBox(
          height: height,
          child: ListView.builder(
            key: ValueKey<String>('work_detail_${keyPrefix}_scroller'),
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: items.length,
            itemBuilder: (context, index) => Padding(
              padding: EdgeInsets.only(right: gap),
              child: itemBuilder(items[index]),
            ),
          ),
        ),
      ),
    );
  }
}
