part of 'asmr_tab.dart';

class _AsmrPanelOverlay extends StatelessWidget {
  const _AsmrPanelOverlay({required this.animation, required this.builder});

  final Animation<double> animation;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);
    final isDesktop = mediaSize.width >= 760;
    final maxWidth = isDesktop ? 472.0 : 404.0;
    final outerPadding = EdgeInsets.fromLTRB(
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 176,
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 132,
    );
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) {
          final progress = curved.value.clamp(0.0, 1.0);
          final showBackdrop = animation.status != AnimationStatus.reverse;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: showBackdrop
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: kSecondaryOverlayConfig.scrimColor(
                              context,
                              progress,
                            ),
                          ),
                        )
                      : const SizedBox.expand(),
                ),
              ),
              SafeArea(
                child: FadeTransition(
                  opacity: curved,
                  child: Padding(
                    padding: outerPadding,
                    child: Align(
                      alignment: isDesktop
                          ? Alignment.center
                          : Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxWidth),
                        child: Theme(
                          data: _asmrPanelTheme(context),
                          child: Builder(builder: builder),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

ThemeData _asmrPanelTheme(BuildContext context) {
  final base = Theme.of(context);
  final tokens = AppDesignTokens.of(context);
  final blue = tokens.asmrAccent;
  final scheme = base.colorScheme.copyWith(
    primary: blue,
    onPrimary: tokens.onAsmrAccent,
    primaryContainer: tokens.asmrContainer,
    onPrimaryContainer: tokens.onAsmrContainer,
    secondary: blue,
    onSecondary: tokens.onAsmrAccent,
    secondaryContainer: tokens.asmrContainer,
    onSecondaryContainer: tokens.onAsmrContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return blue;
        }
        return null;
      }),
      checkColor: WidgetStateProperty.all(tokens.onAsmrAccent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: blue,
        foregroundColor: tokens.onAsmrAccent,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: blue),
    ),
    iconTheme: base.iconTheme.copyWith(color: blue),
    textSelectionTheme: base.textSelectionTheme.copyWith(
      cursorColor: blue,
      selectionColor: blue.withValues(alpha: 0.3),
      selectionHandleColor: blue,
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: blue, width: 1.5),
      ),
    ),
  );
}

class _AsmrPanelCard extends StatelessWidget {
  const _AsmrPanelCard({
    required this.icon,
    required this.title,
    required this.child,
    this.actions = const <_AsmrPanelAction>[],
  });

  final IconData icon;
  final String title;
  final Widget child;
  final List<_AsmrPanelAction> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = (MediaQuery.sizeOf(context).height - 96).clamp(
      280.0,
      560.0,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: cs.surfaceContainerLow.withValues(alpha: 0.96),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AsmrPanelTitle(icon: icon, title: title),
              const SizedBox(height: 18),
              Flexible(child: child),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AsmrPanelTitle extends StatelessWidget {
  const _AsmrPanelTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: cs.onPrimaryContainer, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _AsmrPanelAction extends StatelessWidget {
  const _AsmrPanelAction({
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      label,
      style: const TextStyle(fontWeight: FontWeight.w600),
    );
    if (filled) {
      return FilledButton(onPressed: onPressed, child: child);
    }
    return TextButton(onPressed: onPressed, child: child);
  }
}

class _AsmrAccountPanel extends ConsumerStatefulWidget {
  const _AsmrAccountPanel();

  @override
  ConsumerState<_AsmrAccountPanel> createState() => _AsmrAccountPanelState();
}

class _AsmrAccountPanelState extends ConsumerState<_AsmrAccountPanel> {
  final TextEditingController _accountController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_submitting) {
      return;
    }
    final account = _accountController.text.trim();
    final password = _passwordController.text;
    if (account.isEmpty || password.isEmpty) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final controller = ref.read(asmrLibraryControllerProvider);
      if (controller == null) return;
      await controller.loginAsmrAccount(account, password);
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('asmr_login_success'),
        tone: AppFeedbackTone.success,
        icon: Icons.verified_user_rounded,
        iconColor: _accountAccentColor(context),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('asmr_login_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
        iconColor: _accountAccentColor(context),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _sync() async {
    if (_submitting) {
      return;
    }
    setState(() => _submitting = true);
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    try {
      await controller.syncAsmrAccount(force: true);
      if (!mounted) {
        return;
      }
      final syncState = controller.syncViewState;
      final failed = syncState.phase == AsmrSyncPhase.failed;
      final authExpired = _isAuthExpired(syncState.lastError);
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr(
              authExpired
                  ? 'asmr_token_expired'
                  : failed
                  ? 'asmr_account_sync_failed'
                  : 'asmr_account_sync_done',
            ),
        tone: failed ? AppFeedbackTone.destructive : AppFeedbackTone.success,
        icon: failed ? Icons.sync_problem_rounded : Icons.sync_rounded,
        iconColor: _accountAccentColor(context),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _logout() async {
    if (_submitting) {
      return;
    }
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    setState(() => _submitting = true);
    try {
      await controller.logoutAsmrAccount();
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('asmr_logout_success'),
        icon: Icons.logout_rounded,
        iconColor: _accountAccentColor(context),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
        iconColor: _accountAccentColor(context),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final authState =
        ref.watch(asmrAuthStateProvider).value ??
        const AsmrAuthViewState(
          isLoggedIn: false,
          isRestoring: true,
          userName: '',
          revision: 0,
        );
    final syncState =
        ref.watch(asmrSyncStateProvider).value ??
        const AsmrSyncViewState(
          phase: AsmrSyncPhase.idle,
          lastSyncAt: null,
          pendingCount: 0,
          lastError: null,
          revision: 0,
        );
    final syncing = syncState.phase == AsmrSyncPhase.syncing || _submitting;

    if (authState.isRestoring) {
      return _AsmrPanelCard(
        icon: Icons.account_circle_rounded,
        title: i18n.tr('asmr_account_title'),
        actions: [
          _AsmrPanelAction(
            label: i18n.tr('close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 12),
              Flexible(child: Text(i18n.tr('asmr_account_restoring'))),
            ],
          ),
        ),
      );
    }

    if (!authState.isLoggedIn) {
      final canLogin =
          _accountController.text.trim().isNotEmpty &&
          _passwordController.text.isNotEmpty &&
          !syncing;
      return _AsmrPanelCard(
        icon: Icons.account_circle_rounded,
        title: i18n.tr('asmr_account_title'),
        actions: [
          _AsmrPanelAction(
            label: i18n.tr('close'),
            onPressed: syncing ? null : () => Navigator.of(context).pop(),
          ),
          _AsmrPanelAction(
            label: syncing
                ? i18n.tr('asmr_account_syncing')
                : i18n.tr('asmr_login_action'),
            onPressed: canLogin ? _login : null,
            filled: true,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _accountController,
              enabled: !syncing,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: i18n.tr('asmr_login_account'),
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !syncing,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (canLogin) {
                  unawaited(_login());
                }
              },
              decoration: InputDecoration(
                labelText: i18n.tr('asmr_login_password'),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      );
    }

    final lastSyncAt = syncState.lastSyncAt;
    return _AsmrPanelCard(
      icon: Icons.account_circle_rounded,
      title: i18n.tr('asmr_account_title'),
      actions: [
        _AsmrPanelAction(
          label: i18n.tr('asmr_logout_action'),
          onPressed: syncing ? null : _logout,
        ),
        _AsmrPanelAction(
          label: syncing
              ? i18n.tr('asmr_account_syncing')
              : i18n.tr('asmr_account_sync_now'),
          onPressed: syncing ? null : _sync,
          filled: true,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AsmrAccountStatusLine(
            icon: Icons.person_outline_rounded,
            text: i18n.tr('asmr_logged_in_as', {
              'name': authState.userName.isEmpty ? '-' : authState.userName,
            }),
          ),
          const SizedBox(height: 12),
          _AsmrAccountStatusLine(
            icon: Icons.schedule_rounded,
            text: lastSyncAt == null
                ? i18n.tr('asmr_account_not_synced')
                : i18n.tr('asmr_account_last_sync', {
                    'time': _formatAsmrSyncTime(lastSyncAt),
                  }),
          ),
          const SizedBox(height: 12),
          _AsmrAccountStatusLine(
            icon: syncState.phase == AsmrSyncPhase.failed
                ? Icons.sync_problem_rounded
                : Icons.sync_rounded,
            text: _syncStatusText(i18n, syncState),
          ),
        ],
      ),
    );
  }

  String _syncStatusText(
    AppLanguageProvider i18n,
    AsmrSyncViewState syncState,
  ) {
    if (syncState.phase == AsmrSyncPhase.syncing) {
      return i18n.tr('asmr_account_syncing');
    }
    if (syncState.phase == AsmrSyncPhase.failed) {
      if (_isAuthExpired(syncState.lastError)) {
        return i18n.tr('asmr_token_expired');
      }
      return i18n.tr('asmr_account_sync_failed');
    }
    if (syncState.pendingCount > 0) {
      return i18n.tr('asmr_account_pending_count', {
        'count': syncState.pendingCount.toString(),
      });
    }
    return i18n.tr('asmr_account_sync_done');
  }

  bool _isAuthExpired(Object? error) =>
      error != null && AsmrApiException.isAuthenticationError(error);

  Color _accountAccentColor(BuildContext context) {
    return AppDesignTokens.of(context).asmrAccent;
  }
}

class _AsmrAccountStatusLine extends StatelessWidget {
  const _AsmrAccountStatusLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatAsmrSyncTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
