import 'dart:async';

import '../../features/asmr/application/asmr_api_service.dart';
import '../../features/asmr/application/asmr_library_controller.dart';
import '../../features/asmr/application/asmr_remote_catalog_service.dart';
import '../../features/settings/application/settings_repository.dart';
import 'runtime_binding.dart';

/// Applies source preferences without restarting playback or in-flight downloads.
class AsmrNetworkRuntimeBinding implements RuntimeBinding {
  AsmrNetworkRuntimeBinding({
    required SettingsRepository settings,
    required AsmrApiService api,
    required AsmrRemoteCatalogService catalog,
    required AsmrLibraryController library,
  }) {
    var domain = settings.asmrApiDomain;
    var source = settings.preferredAsmrSource;
    api.setPreferredDomain(domain);
    catalog.preferredSource = () => settings.preferredAsmrSource;
    _subscription = settings.slice.stream.listen((state) {
      if (domain != state.asmrApiDomain) {
        domain = state.asmrApiDomain;
        api.setPreferredDomain(domain);
      }
      if (source != state.preferredAsmrSource) {
        source = state.preferredAsmrSource;
        library.invalidateResourceSource();
      }
    });
  }

  late final StreamSubscription<Object?> _subscription;

  @override
  Future<void> dispose() => _subscription.cancel();
}
