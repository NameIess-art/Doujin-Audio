import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../settings/application/app_cache_service.dart';
import '../application/storage_usage_service.dart';

class StorageUsageCard extends ConsumerStatefulWidget {
  const StorageUsageCard({super.key});

  @override
  ConsumerState<StorageUsageCard> createState() => _StorageUsageCardState();
}

class _StorageUsageCardState extends ConsumerState<StorageUsageCard> {
  late Future<StorageUsageSnapshot> _storageUsageFuture;

  @override
  void initState() {
    super.initState();
    _storageUsageFuture = _loadStorageUsage();
  }

  Future<StorageUsageSnapshot> _loadStorageUsage() {
    return ref.read(dataSupportStorageUsageServiceProvider).load();
  }

  void _reloadStorageUsage() {
    setState(() {
      _storageUsageFuture = _loadStorageUsage();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    return FutureBuilder<StorageUsageSnapshot>(
      key: const ValueKey('data-support-storage-usage'),
      future: _storageUsageFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data!.isAvailable) {
          return _StorageUsageCard(snapshot: snapshot.data!);
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _StorageUsageLoadingCard();
        }
        return _StorageUsageUnavailableCard(onRetry: _reloadStorageUsage);
      },
    );
  }
}

class _StorageUsageLoadingCard extends StatelessWidget {
  const _StorageUsageLoadingCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('data-support-storage-loading'),
      elevation: 0,
      color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
      child: const SizedBox(
        height: 132,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _StorageUsageUnavailableCard extends StatelessWidget {
  const _StorageUsageUnavailableCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('data-support-storage-unavailable'),
      elevation: 0,
      color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(Icons.sd_storage_outlined, color: cs.onSurface),
        title: Text(i18n.tr('storage_usage_title')),
        subtitle: Text(i18n.tr('storage_usage_unavailable')),
        trailing: IconButton(
          onPressed: onRetry,
          tooltip: i18n.tr('storage_usage_retry'),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ),
    );
  }
}

class _StorageUsageCard extends StatelessWidget {
  const _StorageUsageCard({required this.snapshot});

  final StorageUsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final audioLibrarySegment = (
      bytes: snapshot.audioLibraryBytes,
      color: cs.primary,
      label: i18n.tr('storage_usage_audio_library'),
      key: 'audio-library',
    );
    final applicationCacheSegment = (
      bytes: snapshot.applicationCacheBytes,
      color: tokens.warning,
      label: i18n.tr('storage_usage_app_cache'),
      key: 'app-cache',
    );
    final otherUsedSegment = (
      bytes: snapshot.otherUsedBytes,
      color: cs.secondary,
      label: i18n.tr('storage_usage_other'),
      key: 'other',
    );
    final availableSegment = (
      bytes: snapshot.availableBytes,
      color: cs.outline,
      label: i18n.tr('storage_usage_available'),
      key: 'available',
    );
    final segments = [
      audioLibrarySegment,
      applicationCacheSegment,
      otherUsedSegment,
      availableSegment,
    ];
    final barSegments = [
      otherUsedSegment,
      applicationCacheSegment,
      audioLibrarySegment,
      availableSegment,
    ];

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
      child: Padding(
        key: const ValueKey('data-support-storage-card'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sd_storage_rounded, color: cs.onSurface),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        i18n.tr('storage_usage_title'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        i18n.tr('storage_usage_total'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  AppCacheService.formatBytes(snapshot.totalBytes),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                key: const ValueKey('data-support-storage-bar'),
                height: 12,
                child: ColoredBox(
                  color: cs.surfaceContainerHighest,
                  child: SizedBox.expand(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final segment in barSegments)
                          if (segment.bytes > 0)
                            Expanded(
                              key: ValueKey(
                                'data-support-storage-segment-${segment.key}',
                              ),
                              flex: _storageSegmentFlex(
                                segment.bytes,
                                snapshot.totalBytes,
                              ),
                              child: ColoredBox(
                                color: segment.color.withValues(alpha: 1),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final segment in segments)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _StorageUsageLegendRow(
                  color: segment.color,
                  label: segment.label,
                  value: AppCacheService.formatBytes(segment.bytes),
                ),
              ),
          ],
        ),
      ),
    );
  }

  int _storageSegmentFlex(int bytes, int totalBytes) {
    return ((bytes / totalBytes) * 10000).round().clamp(1, 10000);
  }
}

class _StorageUsageLegendRow extends StatelessWidget {
  const _StorageUsageLegendRow({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return Row(
      children: [
        SizedBox.square(
          dimension: 10,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: textStyle)),
        Text(value, style: textStyle?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
