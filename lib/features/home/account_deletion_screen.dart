import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/auth/account_deletion_service.dart';

class AccountDeletionScreen extends StatefulWidget {
  final AccountDeletionService service;
  final VoidCallback? onDeleted;

  AccountDeletionScreen({
    super.key,
    AccountDeletionService? service,
    this.onDeleted,
  }) : service = service ?? AccountDeletionService();

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  AccountDeletionReauthProvider? _selectedProvider;
  bool _riskConfirmed = false;
  bool _loading = false;
  bool _sendingCode = false;
  String? _verificationId;

  final _passwordController = TextEditingController();
  final _smsCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final providers = widget.service.supportedProviders();
    if (providers.length == 1) _selectedProvider = providers.first;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _smsCodeController.dispose();
    super.dispose();
  }

  Future<void> _confirmRisk() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('회원 탈퇴를 진행할까요?'),
        content: const Text(
          '프로필, 사진, 개인 설정, 젤리 잔액과 사용 권한이 삭제됩니다. '
          '채팅, 신고, 결제 감사 기록은 비식별 처리되어 보존될 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('계속'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final providers = widget.service.supportedProviders();
    setState(() {
      _riskConfirmed = true;
      _selectedProvider ??= providers.isNotEmpty ? providers.first : null;
    });
  }

  Future<void> _sendPhoneCode() async {
    if (_loading || _sendingCode) return;
    setState(() => _sendingCode = true);
    try {
      final verificationId = await widget.service
          .sendPhoneReauthenticationCode();
      if (!mounted) return;
      setState(() => _verificationId = verificationId);
      _showSnack('인증번호를 보냈습니다.');
    } on AccountDeletionFailure catch (e) {
      if (mounted) _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _reauthenticateAndDelete() async {
    if (_loading) return;
    final provider = _selectedProvider;
    if (provider == null) {
      _showSnack('지원되는 재인증 수단이 없습니다.');
      return;
    }

    final expectedUid = widget.service.currentSnapshot()?.uid;
    if (expectedUid == null) {
      _showSnack('로그인이 필요합니다.');
      return;
    }

    setState(() => _loading = true);
    try {
      await _reauthenticate(provider);
      await widget.service.refreshIdTokenAfterReauthentication(expectedUid);
    } on AccountDeletionFailure catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showSnack(e.message);
      }
      return;
    }

    if (!mounted) return;
    final finalConfirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('정말 탈퇴하시겠어요?'),
        content: const Text('이 작업은 되돌릴 수 없습니다. 삭제를 시작하면 완료 후 자동으로 로그아웃됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('회원 탈퇴'),
          ),
        ],
      ),
    );
    if (finalConfirmed != true) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      await widget.service.deleteMyAccount();
      await _finishLocalSession();
    } on AccountDeletionFailure catch (e) {
      if (!mounted) return;
      if (widget.service.currentSnapshot() == null) {
        await _finishLocalSession();
        return;
      }
      setState(() => _loading = false);
      _showSnack(e.message);
    }
  }

  Future<void> _reauthenticate(AccountDeletionReauthProvider provider) {
    switch (provider) {
      case AccountDeletionReauthProvider.password:
        return widget.service.reauthenticateWithPassword(
          _passwordController.text,
        );
      case AccountDeletionReauthProvider.google:
        return widget.service.reauthenticateWithGoogle();
      case AccountDeletionReauthProvider.phone:
        final verificationId = _verificationId;
        if (verificationId == null) {
          throw const AccountDeletionFailure('먼저 인증번호를 받아주세요.');
        }
        return widget.service.confirmPhoneReauthenticationCode(
          verificationId: verificationId,
          smsCode: _smsCodeController.text,
        );
    }
  }

  Future<void> _finishLocalSession() async {
    await widget.service.signOutAfterDeletion();
    if (!mounted) return;
    widget.onDeleted?.call();
    if (widget.onDeleted == null) {
      Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.service.currentSnapshot();
    final providers = widget.service.supportedProviders();
    final hasSupportedProvider = providers.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('회원 탈퇴'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _WarningPanel(hasSupportedProvider: hasSupportedProvider),
            const SizedBox(height: 20),
            if (!_riskConfirmed)
              FilledButton.icon(
                key: const Key('start-account-deletion'),
                onPressed: snapshot == null || _loading ? null : _confirmRisk,
                icon: const Icon(Icons.warning_amber_rounded),
                label: const Text('회원 탈퇴 진행'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.white,
                  minimumSize: const Size.fromHeight(52),
                ),
              )
            else ...[
              _ProviderSelector(
                providers: providers,
                selected: _selectedProvider,
                onChanged: _loading
                    ? null
                    : (provider) =>
                          setState(() => _selectedProvider = provider),
              ),
              const SizedBox(height: 16),
              _ReauthFields(
                provider: _selectedProvider,
                passwordController: _passwordController,
                smsCodeController: _smsCodeController,
                verificationId: _verificationId,
                sendingCode: _sendingCode,
                loading: _loading,
                onSendPhoneCode: _sendPhoneCode,
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('confirm-account-deletion'),
                onPressed: _loading || !hasSupportedProvider
                    ? null
                    : _reauthenticateAndDelete,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.white,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: Text(_loading ? '삭제 진행 중' : '재인증 후 회원 탈퇴'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WarningPanel extends StatelessWidget {
  final bool hasSupportedProvider;

  const _WarningPanel({required this.hasSupportedProvider});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '계정 관리',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '탈퇴하면 프로필, 사진, 개인 설정, 젤리 잔액과 사용 권한이 삭제됩니다. '
            '남은 사용자의 기록 보호와 운영 감사를 위해 채팅, 신고, 결제 기록은 '
            '익명화되어 보존될 수 있습니다.',
            style: TextStyle(
              fontSize: 14,
              height: 1.55,
              color: AppColors.textSecondary,
            ),
          ),
          if (!hasSupportedProvider) ...[
            const SizedBox(height: 12),
            const Text(
              '현재 계정에서 지원되는 재인증 수단을 찾을 수 없어 탈퇴를 진행할 수 없습니다.',
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: AppColors.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderSelector extends StatelessWidget {
  final List<AccountDeletionReauthProvider> providers;
  final AccountDeletionReauthProvider? selected;
  final ValueChanged<AccountDeletionReauthProvider>? onChanged;

  const _ProviderSelector({
    required this.providers,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (providers.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final provider in providers)
          ChoiceChip(
            label: Text(provider.label),
            selected: selected == provider,
            onSelected: onChanged == null
                ? null
                : (_) => onChanged?.call(provider),
          ),
      ],
    );
  }
}

class _ReauthFields extends StatelessWidget {
  final AccountDeletionReauthProvider? provider;
  final TextEditingController passwordController;
  final TextEditingController smsCodeController;
  final String? verificationId;
  final bool sendingCode;
  final bool loading;
  final VoidCallback onSendPhoneCode;

  const _ReauthFields({
    required this.provider,
    required this.passwordController,
    required this.smsCodeController,
    required this.verificationId,
    required this.sendingCode,
    required this.loading,
    required this.onSendPhoneCode,
  });

  @override
  Widget build(BuildContext context) {
    switch (provider) {
      case AccountDeletionReauthProvider.password:
        return TextField(
          key: const Key('account-deletion-password'),
          controller: passwordController,
          obscureText: true,
          enabled: !loading,
          decoration: const InputDecoration(
            labelText: '비밀번호',
            border: OutlineInputBorder(),
          ),
        );
      case AccountDeletionReauthProvider.phone:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton(
              key: const Key('send-account-deletion-phone-code'),
              onPressed: loading || sendingCode ? null : onSendPhoneCode,
              child: Text(sendingCode ? '전송 중' : '인증번호 받기'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('account-deletion-sms-code'),
              controller: smsCodeController,
              keyboardType: TextInputType.number,
              enabled: !loading && verificationId != null,
              decoration: const InputDecoration(
                labelText: '인증번호',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        );
      case AccountDeletionReauthProvider.google:
        return const Text(
          'Google 계정 선택 화면에서 현재 로그인 계정으로 다시 인증합니다.',
          style: TextStyle(color: AppColors.textSecondary, height: 1.45),
        );
      case null:
        return const SizedBox.shrink();
    }
  }
}
