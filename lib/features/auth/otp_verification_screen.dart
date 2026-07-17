import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/auth/auth_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';

/// 전화번호 로그인 2단계 — SMS 인증코드 입력 화면.
///
/// [verificationId]는 PhoneLoginScreen에서 signInWithPhone의 onCodeSent로
/// 받은 값이다. 사용자가 6자리 코드를 입력하면 confirmSmsCode()로 로그인을
/// 완료한다. 재전송에는 60초 쿨다운을 둔다(email_verification_screen.dart와
/// 같은 Timer 패턴).
class OtpVerificationScreen extends StatefulWidget {
  final String phoneNumber; // E.164 형식, 예: '+821012345678'
  final String verificationId;
  final AuthService authService;
  final bool linkToCurrentUser;
  final Future<void> Function()? onVerificationCompleted;

  const OtpVerificationScreen({
    super.key,
    required this.phoneNumber,
    required this.verificationId,
    required this.authService,
    this.linkToCurrentUser = false,
    this.onVerificationCompleted,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  static const int _resendCooldownSecs = 60;

  final _codeController = TextEditingController();

  late String _verificationId; // 재전송 시 새 값으로 교체된다.
  int _cooldownRemaining = 0;
  Timer? _cooldownTimer;

  bool _loading = false;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    _verificationId = widget.verificationId;
    // 이 화면에 들어왔다는 건 코드를 방금 보냈다는 뜻이므로 바로 쿨다운을 건다.
    _startCooldown();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
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

  // ── 인증코드 확인 ─────────────────────────────────────────────────────────

  Future<void> _handleVerify() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      _showMessage('6자리 인증코드를 입력해주세요.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      await widget.authService.confirmSmsCode(
        verificationId: _verificationId,
        smsCode: code,
        linkToCurrentUser: widget.linkToCurrentUser,
      );
      await widget.onVerificationCompleted?.call();
      if (!mounted) return;
      if (widget.linkToCurrentUser) {
        Navigator.pop(context, true);
      }
      // 일반 전화 로그인 성공 시 _AuthGate가 authStateChanges로 자동 전환한다.
    } on AuthFailure catch (e) {
      if (widget.linkToCurrentUser && e.message.contains('이미 전화번호 인증')) {
        await widget.onVerificationCompleted?.call();
        if (mounted) Navigator.pop(context, true);
        return;
      }
      if (mounted) _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 인증코드 재전송 ───────────────────────────────────────────────────────

  Future<void> _handleResend() async {
    setState(() => _resending = true);
    await widget.authService.signInWithPhone(
      phoneNumber: widget.phoneNumber,
      onCodeSent: (verificationId) {
        if (!mounted) return;
        setState(() {
          _verificationId = verificationId;
          _resending = false;
        });
        _showMessage('인증코드를 다시 보냈어요.');
        _startCooldown();
      },
      onVerified: (_) {
        _finishAutoVerification();
      },
      onFailed: (message) {
        if (!mounted) return;
        setState(() => _resending = false);
        _showMessage(message);
      },
      linkToCurrentUser: widget.linkToCurrentUser,
    );
  }

  Future<void> _finishAutoVerification() async {
    try {
      await widget.onVerificationCompleted?.call();
      if (!mounted) return;
      setState(() => _resending = false);
      if (widget.linkToCurrentUser) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _resending = false);
      _showMessage('전화 인증 상태 저장에 실패했어요: $e');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  /// E.164(+821012345678) → 화면 표시용(010-1234-5678).
  String _displayPhone() {
    final digits = widget.phoneNumber.replaceFirst('+82', '0');
    if (digits.length == 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    }
    if (digits.length == 10) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    return digits;
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _cooldownRemaining == 0 && !_resending && !_loading;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.linkToCurrentUser ? '전화번호 인증' : '인증코드 확인'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _loading ? null : () => Navigator.pop(context),
        ),
        backgroundColor: AppColors.background.withValues(alpha: 0),
        elevation: 0,
      ),
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              // 소프트 키보드가 올라오면 body 높이가 줄어든다. 스크롤 뷰로 감싸
              // bottom overflow를 막고, 포커스된 입력칸이 가려지지 않게 한다.
              padding: EdgeInsets.fromLTRB(
                28,
                16,
                28,
                32 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.sms_rounded,
                    size: 56,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '인증코드를 입력해주세요',
                    style: TextStyle(
                      fontFamily: AppFonts.display,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        height: 1.6,
                      ),
                      children: [
                        TextSpan(
                          text: _displayPhone(),
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const TextSpan(text: '(으)로 보낸 6자리 코드를 입력해주세요.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: 6,
                    onSubmitted: (_) => _handleVerify(),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                    ),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: '000000',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: canResend
                        ? '인증코드 재전송'
                        : '재전송 ($_cooldownRemaining초)',
                    outlined: true,
                    onPressed: canResend ? _handleResend : null,
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: '확인',
                    onPressed: _loading ? null : _handleVerify,
                  ),
                ],
              ),
            ),
          ),
          if (_loading) const LoadingIndicator(overlay: true),
        ],
      ),
    );
  }
}
