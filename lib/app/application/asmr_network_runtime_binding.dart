import 'dart:async';

import '../../features/asmr/application/asmr_api_service.dart';
import '../../features/settings/application/settings_repository.dart';
import 'runtime_binding.dart';

/// Applies mirror preferences without restarting playback or in-flight downloads.
class AsmrNetworkRuntimeBinding implements RuntimeBinding {
  AsmrNetworkRuntimeBinding({
    required SettingsRepository settings,
    required AsmrApiService api,
  }) {
    var domain = settings.asmrApiDomain;
    api.setPreferredDomain(domain);
    _subscription = settings.slice.stream.listen((state) {
      if (domain != state.asmrApiDomain) {
        domain = state.asmrApiDomain;
        api.setPreferredDomain(domain);
      }
    });
  }

  late final StreamSubscription<Object?> _subscription;

  @override
  Future<void> dispose() => _subscription.cancel();
}
