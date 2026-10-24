part of 'settings_tab.dart';

class _NetworkSettingsControls extends ConsumerStatefulWidget {
  const _NetworkSettingsControls({required this.buildSections});

  final Widget Function(List<Widget>) buildSections;
  @override
  ConsumerState<_NetworkSettingsControls> createState() =>
      _NetworkSettingsControlsState();
}

class _NetworkSettingsControlsState
    extends ConsumerState<_NetworkSettingsControls> {
  final _probe = NetworkServiceProbe();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  final _password = TextEditingController();
  late final TextEditingController _dns;
  late AppProxyMode _mode;
  late bool _authentication;
  bool _saving = false;
  bool _validateProxy = false;
  bool _validateDns = false;

  SettingsRepository get _settings => ref.read(settingsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    final route = _settings.networkRouteSettings;
    _mode = route.proxyMode;
    _authentication = route.proxyAuthenticationEnabled;
    _host = TextEditingController(text: route.proxyHost);
    _port = TextEditingController(
      text: route.proxyPort == 0 ? '' : '${route.proxyPort}',
    );
    _username = TextEditingController(text: route.proxyUsername);
    _dns = TextEditingController(text: route.customDnsServer);
    _probe.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _probe.removeListener(_refresh);
    _probe.dispose();
    for (final controller in [_host, _port, _username, _password, _dns]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<bool> _save(Future<void> Function() operation) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      final saved = await saveSettingsWithFeedback(context, operation);
      if (saved) _probe.reset();
      return saved;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _applyProxy() async {
    setState(() => _validateProxy = true);
    final value = _settings.networkRouteSettings.copyWith(
      proxyMode: _mode,
      proxyHost: _host.text.trim(),
      proxyPort: int.tryParse(_port.text.trim()) ?? 0,
      proxyAuthenticationEnabled: _authentication,
      proxyUsername: _username.text.trim(),
      proxyPasswordConfigured:
          _password.text.isNotEmpty ||
          _settings.networkRouteSettings.proxyPasswordConfigured,
    );
    try {
      value.validate();
    } on FormatException {
      return;
    }
    final saved = await _save(
      () => _settings.setNetworkRouteSettings(value, password: _password.text),
    );
    if (saved && mounted) _password.clear();
  }

  Future<void> _applyDns({bool reset = false}) async {
    setState(() => _validateDns = true);
    final value = reset ? '' : _dns.text.trim();
    if (value.isNotEmpty && NetworkRouteSettings.normalizeDns(value) == null) {
      return;
    }
    final saved = await _save(
      () => _settings.setNetworkRouteSettings(
        _settings.networkRouteSettings.copyWith(customDnsServer: value),
      ),
    );
    if (saved && mounted && reset) _dns.clear();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final state =
        ref.watch(settingsStateProvider).value ?? _settings.slice.state;
    ref.listen(settingsStateProvider, (previous, next) {
      if (previous?.value?.networkRouteSettings !=
              next.value?.networkRouteSettings ||
          previous?.value?.asmrApiDomain != next.value?.asmrApiDomain) {
        _probe.reset();
      }
    });
    final route = state.networkRouteSettings;
    final cs = Theme.of(context).colorScheme;
    final port = int.tryParse(_port.text.trim());
    final hostInvalid = NetworkRouteSettings.normalizeHost(_host.text) == null;
    final portInvalid = port == null || port < 1 || port > 65535;
    final usernameInvalid =
        _username.text.trim().isEmpty ||
        (_mode == AppProxyMode.socks5 &&
            utf8.encode(_username.text.trim()).length > 255);
    final passwordInvalid =
        (_password.text.isEmpty && !route.proxyPasswordConfigured) ||
        (_mode == AppProxyMode.socks5 &&
            utf8.encode(_password.text).length > 255);
    final credentialsInvalid =
        _authentication && (usernameInvalid || passwordInvalid);
    final dnsInvalid =
        _dns.text.trim().isNotEmpty &&
        NetworkRouteSettings.normalizeDns(_dns.text) == null;
    Widget field(
      TextEditingController controller,
      String label, {
      bool secret = false,
      bool numeric = false,
      bool invalid = false,
      String? hint,
    }) => TextField(
      controller: controller,
      enabled: !_saving,
      obscureText: secret,
      enableSuggestions: !secret,
      autocorrect: false,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: i18n.tr(label),
        hintText: hint,
        errorText: invalid ? i18n.tr('network_invalid_value') : null,
        border: const OutlineInputBorder(),
      ),
    );
    Widget inset(Widget child) =>
        Padding(padding: const EdgeInsets.all(16), child: child);
    String modeLabel(AppProxyMode mode) => switch (mode) {
      AppProxyMode.system => i18n.tr('network_system_vpn'),
      AppProxyMode.http => 'HTTP',
      AppProxyMode.socks5 => 'SOCKS5',
    };
    final currentProxy = route.proxyMode == AppProxyMode.system
        ? modeLabel(route.proxyMode)
        : '${modeLabel(route.proxyMode)} · ${route.proxyHost}:${route.proxyPort}';
    return widget.buildSections([
      _SettingsSectionCard(
        title: i18n.tr('network_site_tests'),
        children: [
          _probeRow(
            i18n,
            'dlsite',
            'DLsite',
            Uri.parse('https://www.dlsite.com/'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: UnifiedDropdownButton<String>(
                    value: state.asmrApiDomain,
                    key: ValueKey(state.asmrApiDomain),
                    isExpanded: true,
                    items: [
                      for (final domain in asmrApiDomains)
                        DropdownMenuItem(
                          value: domain,
                          child: Text(
                            Uri.parse(domain).host,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(
                                _save(() => _settings.setAsmrApiDomain(value)),
                              );
                            }
                          },
                  ),
                ),
                const SizedBox(width: 8),
                _probeAction(
                  i18n,
                  'asmr',
                  Uri.parse(
                    '${state.asmrApiDomain}/api/works?page=1&pageSize=1',
                  ),
                ),
              ],
            ),
          ),
          _probeRow(
            i18n,
            'japanese',
            'Japanese ASMR',
            Uri.parse('https://earaasmr.com/'),
          ),
        ],
      ),
      _SettingsSectionCard(
        title: i18n.tr('network_proxy'),
        children: [
          inset(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in AppProxyMode.values)
                      ChoiceChip(
                        label: Text(modeLabel(mode)),
                        selected: _mode == mode,
                        onSelected: _saving
                            ? null
                            : (_) async {
                                if (mode == AppProxyMode.system) {
                                  final saved = await _save(
                                    () => _settings.setNetworkRouteSettings(
                                      route.copyWith(proxyMode: mode),
                                    ),
                                  );
                                  if (saved && mounted) {
                                    setState(() => _mode = mode);
                                  }
                                } else {
                                  setState(() {
                                    _mode = mode;
                                    _validateProxy = false;
                                  });
                                }
                              },
                      ),
                  ],
                ),
                if (_mode != AppProxyMode.system) ...[
                  const SizedBox(height: 16),
                  field(
                    _host,
                    'network_proxy_host',
                    invalid: _validateProxy && hostInvalid,
                  ),
                  const SizedBox(height: 12),
                  field(
                    _port,
                    'network_proxy_port',
                    numeric: true,
                    invalid: _validateProxy && portInvalid,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(i18n.tr('network_proxy_authentication')),
                    value: _authentication,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _authentication = value),
                  ),
                  if (_authentication) ...[
                    field(
                      _username,
                      'network_proxy_username',
                      invalid: _validateProxy && usernameInvalid,
                    ),
                    const SizedBox(height: 12),
                    field(
                      _password,
                      'network_proxy_password',
                      secret: true,
                      hint: route.proxyPasswordConfigured
                          ? i18n.tr('network_password_keep')
                          : null,
                      invalid:
                          _validateProxy &&
                          credentialsInvalid &&
                          passwordInvalid,
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _saving ? null : _applyProxy,
                    child: Text(i18n.tr('network_apply_proxy')),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '${i18n.tr('network_current_proxy')}: $currentProxy',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Text(
                  i18n.tr('network_new_connections'),
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
      _SettingsSectionCard(
        title: i18n.tr('network_dns'),
        children: [
          inset(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field(
                  _dns,
                  'network_dns_ip',
                  invalid: _validateDns && dnsInvalid,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _saving ? null : _applyDns,
                  child: Text(i18n.tr('network_apply_dns')),
                ),
                TextButton(
                  onPressed: _saving ? null : () => _applyDns(reset: true),
                  child: Text(i18n.tr('network_reset_dns')),
                ),
                Text(
                  '${i18n.tr('network_current_dns')}: ${route.customDnsServer.isEmpty ? i18n.tr('network_system_dns') : route.customDnsServer}',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Text(
                  i18n.tr('network_dns_proxy_note'),
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    ]);
  }

  Widget _probeRow(
    AppLanguageProvider i18n,
    String key,
    String title,
    Uri uri,
  ) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(child: Text(title)),
        const SizedBox(width: 8),
        _probeAction(i18n, key, uri),
      ],
    ),
  );

  Widget _probeAction(AppLanguageProvider i18n, String key, Uri uri) {
    final result = _probe.result(key);
    final testing = result.status == NetworkProbeStatus.testing;
    final text = switch (result.status) {
      NetworkProbeStatus.untested => i18n.tr('network_untested'),
      NetworkProbeStatus.testing => i18n.tr('network_testing'),
      NetworkProbeStatus.success => '${result.milliseconds} ms',
      NetworkProbeStatus.failed => i18n.tr('network_failed'),
    };
    final cs = Theme.of(context).colorScheme;
    final color = switch (result.status) {
      NetworkProbeStatus.failed => cs.error,
      NetworkProbeStatus.success when result.milliseconds! < 300 =>
        Colors.green,
      NetworkProbeStatus.success when result.milliseconds! < 800 =>
        Colors.orange,
      NetworkProbeStatus.success => cs.error,
      _ => cs.onSurfaceVariant,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (testing)
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (testing) const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color)),
        const SizedBox(width: 8),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: testing || _saving ? null : () => _probe.test(key, uri),
          child: Text(i18n.tr('network_test')),
        ),
      ],
    );
  }
}
