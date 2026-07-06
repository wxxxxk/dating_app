import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/auth/auth_service.dart';
import '../../shared/widgets/primary_button.dart';

/// 이메일 인증 안내 화면 (M2.6).
///
/// 가입 직후 sendEmailVerification() 이 호출된 뒤에 표시된다.
/// 사용자가 인증 링크를 클릭하면 [인증 완료, 계속하기]로 확인한다.
///
/// 데모 편의 설정:
///   [_requireVerification] = true  → 인증 확인 전 진행 차단
///   [_requireVerification] = false → 인증 안 해도 경고만 하고 진행 허용 (현재 설정)
class EmailVerificationScreen extends StatefulWidget {
  final String email;
  final AuthService authService;

  const EmailVerificationScreen({
    super.key,
    required this.email,
    required this.authService,
  });

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  // 인증 강제 여부 토글 — 프로덕션에서는 true로 바꾸면 된다.
  static const bool _requireVerification = false;

  // 재발송 버튼 쿨다운 (초)
  static const int _resendCooldownSecs = 30;
  int _cooldownRemaining = 0;
  Timer? _cooldownTimer;

  bool _loading = false;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  // ── 인증 메일 재발송 ─────────────────────────────────────────────────────

  Future<void> _resendEmail() async {
    setState(() => _loading = true);
    try {
      await widget.authService.sendEmailVerification();
      if (!mounted) return;
      _showMessage('인증 메일을 다시 보냈어요.');
      _startCooldown();
    } on AuthFailure catch (e) {
      if (mounted) _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startCooldown() {
    setState(() => _cooldownRemaining = _resendCooldownSecs);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cooldownRemaining <= 1) {
        t.cancel();
        if (mounted) setState(() => _cooldownRemaining = 0);
      } else {
        if (mounted) setState(() => _cooldownRemaining--);
      }
    });
  }

  // ── 인증 확인 후 계속 ──────────────────────────────────────────────────

  Future<void> _handleContinue() async {
    setState(() => _loading = true);
    try {
      // 서버에서 최신 인증 상태를 가져온다 (캐시 갱신).
      await widget.authService.reloadUser();
    } finally {
      if (mounted) setState(() => _loading = false);
    }

    if (!mounted) return;

    if (widget.authService.isEmailVerified) {
      // 인증 완료: 루트(_AuthGate)로 돌아가 온보딩/홈으로 자동 전환.
      Navigator.pop(context);
    } else if (!_requireVerification) {
      // 데모 모드: 인증 없이도 일단 진행.
      _showMessage('아직 인증되지 않았어요. 나중에 메일을 확인해주세요.');
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.pop(context);
    } else {
      // 강제 차단 모드.
      _showMessage('아직 이메일 인증이 완료되지 않았어요.\n받은 편지함의 인증 링크를 눌러주세요.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _cooldownRemaining == 0 && !_loading;

    return Scaffold(
      // 뒤로 가기로 로그인 화면(_AuthGate 루트)으로 돌아갈 수 있게 허용
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),

              // ── 아이콘 + 안내 문구 ────────────────────────────────────
              const Icon(Icons.mark_email_unread_outlined,
                  size: 72, color: AppColors.primary),
              const SizedBox(height: 24),
              const Text(
                '인증 메일을 보냈어요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                    height: 1.6,
                  ),
                  children: [
                    TextSpan(
                      text: widget.email,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(
                        text: '\n으로 인증 메일을 보냈어요.\n메일의 링크를 눌러 인증해주세요.'),
                  ],
                ),
              ),

              const Spacer(flex: 3),

              // ── 재발송 버튼 ───────────────────────────────────────────
              PrimaryButton(
                label: canResend
                    ? '인증 메일 다시 보내기'
                    : '다시 보내기 ($_cooldownRemaining초)',
                outlined: true,
                onPressed: canResend ? _resendEmail : null,
              ),
              const SizedBox(height: 12),

              // ── 계속하기 버튼 ─────────────────────────────────────────
              PrimaryButton(
                label: '인증 완료, 계속하기',
                onPressed: _loading ? null : _handleContinue,
              ),

              const SizedBox(height: 24),
              // 인증 강제 차단 시 힌트 (데모에서는 숨겨도 되지만 UX 안내용으로 표시)
              if (!_requireVerification)
                const Text(
                  '메일 인증을 건너뛰고 바로 시작할 수도 있어요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
