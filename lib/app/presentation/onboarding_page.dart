import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_bootstrap_controller.dart';
import '../state/app_runtime_providers.dart';
import '../../features/settings/application/app_preferences.dart';
import '../../core/widgets/app_transitions.dart';

class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child, this.initiallyVisible});

  final Widget child;
  final bool? initiallyVisible;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  late bool _showOnboarding =
      widget.initiallyVisible ?? AppPreferences.shouldShowOnboardingSync();

  Future<void> _complete() async {
    await AppPreferences.completeOnboarding();
    if (mounted) setState(() => _showOnboarding = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_showOnboarding) return widget.child;
    return OnboardingPage(onComplete: _complete);
  }
}

/// Keeps the onboarding decision stable while starting the full runtime only
/// after a fresh install has rendered its first onboarding frame.
class OnboardingRuntimeGate extends StatefulWidget {
  const OnboardingRuntimeGate({
    super.key,
    required this.showOnboarding,
    required this.runtimeController,
    required this.child,
  });

  final bool showOnboarding;
  final AppBootstrapController runtimeController;
  final Widget child;

  @override
  State<OnboardingRuntimeGate> createState() => _OnboardingRuntimeGateState();
}

class _OnboardingRuntimeGateState extends State<OnboardingRuntimeGate> {
  @override
  void initState() {
    super.initState();
    if (widget.showOnboarding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(widget.runtimeController.initialize());
        });
        WidgetsBinding.instance.scheduleFrame();
      });
    }
  }

  @override
  Widget build(BuildContext context) => OnboardingGate(
    initiallyVisible: widget.showOnboarding,
    child: widget.child,
  );
}

class OnboardingPage extends ConsumerWidget {
  const OnboardingPage({super.key, required this.onComplete});

  final Future<void> Function() onComplete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: 38,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      i18n.tr('onboarding_title'),
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    i18n.tr('onboarding_subtitle'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  _TrustPoint(
                    icon: Icons.folder_copy_outlined,
                    text: i18n.tr('onboarding_local'),
                  ),
                  _TrustPoint(
                    icon: Icons.cloud_outlined,
                    text: i18n.tr('onboarding_online_optional'),
                  ),
                  _TrustPoint(
                    icon: Icons.admin_panel_settings_outlined,
                    text: i18n.tr('onboarding_permissions'),
                  ),
                  const Spacer(flex: 2),
                  FilledButton(
                    onPressed: onComplete,
                    child: Text(i18n.tr('onboarding_start')),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      buildAppPageRoute<void>(
                        context: context,
                        child: const PrivacySummaryPage(),
                      ),
                    ),
                    child: Text(i18n.tr('privacy_summary_action')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrustPoint extends StatelessWidget {
  const _TrustPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 21, color: cs.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}

class PrivacySummaryPage extends ConsumerWidget {
  const PrivacySummaryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('privacy_summary_title'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _PrivacySection(
            icon: Icons.storage_rounded,
            title: i18n.tr('privacy_summary_local_title'),
            body: i18n.tr('privacy_summary_local_body'),
          ),
          _PrivacySection(
            icon: Icons.public_rounded,
            title: i18n.tr('privacy_summary_network_title'),
            body: i18n.tr('privacy_summary_network_body'),
          ),
          _PrivacySection(
            icon: Icons.support_agent_rounded,
            title: i18n.tr('privacy_summary_diagnostics_title'),
            body: i18n.tr('privacy_summary_diagnostics_body'),
          ),
        ],
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(body, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
