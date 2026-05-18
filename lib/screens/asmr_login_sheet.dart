import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/asmr_library_controller.dart';
import '../widgets/app_feedback.dart';

Future<void> showAsmrLoginSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const _AsmrLoginSheet(),
  );
}

class _AsmrLoginSheet extends StatefulWidget {
  const _AsmrLoginSheet();

  @override
  State<_AsmrLoginSheet> createState() => _AsmrLoginSheetState();
}

class _AsmrLoginSheetState extends State<_AsmrLoginSheet> {
  final TextEditingController _userNameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _userNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final userName = _userNameController.text.trim();
    final password = _passwordController.text;
    if (userName.length < 3 || password.length < 3) {
      setState(() {
        _errorText = '请输入站点账号和密码。';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      await context.read<AsmrLibraryController>().login(
        userName: userName,
        password: password,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已登录 ASMR.ONE，并开始同步收藏。',
        tone: AppFeedbackTone.success,
        icon: Icons.verified_user_rounded,
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorText = '登录失败，请检查账号、密码或网络状态。';
      });
    }
  }

  Future<void> _logout() async {
    await context.read<AsmrLibraryController>().clearAuthSession();
    if (!mounted) return;
    showAppSnackBar(
      context,
      '已退出 ASMR.ONE 账号。',
      tone: AppFeedbackTone.warning,
      icon: Icons.logout_rounded,
    );
    Navigator.of(context).pop();
  }

  Future<void> _syncLoggedInSession() async {
    setState(() => _submitting = true);
    try {
      await context.read<AsmrLibraryController>().syncAuthSession();
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已重新同步账号收藏。',
        tone: AppFeedbackTone.success,
        icon: Icons.sync_rounded,
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AsmrLibraryController>();
    final cs = Theme.of(context).colorScheme;
    final isLoggedIn = controller.authSession.isLoggedIn;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isLoggedIn ? '账号状态' : '登录 ASMR.ONE',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            isLoggedIn
                ? '当前账号：${controller.authSession.userName ?? '未命名用户'}'
                : '使用 asmr.one/works 的账号登录，同步收藏；历史先以应用内记录为主。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          if (isLoggedIn) ...[
            FilledButton.tonalIcon(
              onPressed: _submitting ? null : _syncLoggedInSession,
              icon: const Icon(Icons.sync_rounded),
              label: Text(_submitting ? '同步中...' : '重新同步'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _submitting ? null : _logout,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('退出登录'),
            ),
          ] else ...[
            TextField(
              controller: _userNameController,
              enabled: !_submitting,
              decoration: const InputDecoration(
                labelText: '账号',
                prefixIcon: Icon(Icons.person_rounded),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !_submitting,
              decoration: const InputDecoration(
                labelText: '密码',
                prefixIcon: Icon(Icons.lock_rounded),
              ),
              obscureText: true,
              onSubmitted: (_) => _submit(),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorText!,
                style: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(_submitting ? '登录中...' : '登录'),
            ),
          ],
        ],
      ),
    );
  }
}
