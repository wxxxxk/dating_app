import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/validators.dart';
import '../../services/auth/auth_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';
import 'otp_verification_screen.dart';

/// 전화번호 로그인 1단계 — 전화번호 입력 화면.
///
/// Validators.phone으로 국내 휴대폰 번호 형식을 검증한 뒤 E.164(+82...)로
/// 변환해 SMS 인증코드를 요청한다. 발송에 성공하면 [OtpVerificationScreen]으로
/// 이동해 2단계(코드 입력)를 진행한다.
class PhoneLoginScreen extends StatefulWidget {
  final AuthService authService;
  final bool linkToCurrentUser;
  final Future<void> Function()? onVerificationCompleted;

  const PhoneLoginScreen({
    super.key,
    required this.authService,
    this.linkToCurrentUser = false,
    this.onVerificationCompleted,
  });

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  /// 검증된 국내 휴대폰 번호(01X-....)를 E.164(+82...)로 변환한다.
  ///
  /// Validators.phone이 이미 `01[016789]\d{7,8}` 패턴을 보장하므로,
  /// 맨 앞 '0'만 떼고 국가번호 '+82'를 붙이면 된다.
  /// 예: "010-1234-5678" → "01012345678" → "+821012345678"
  String _toE164(String rawInput) {
    final digits = rawInput.replaceAll(RegExp(r'\D'), '');
    return '+82${digits.substring(1)}';
  }

  Future<void> _requestCode() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);

    final e164 = _toE164(_phoneController.text);

    // 결과는 콜백으로 온다 — signInWithPhone 자체의 Future 완료 시점과
    // 실제 발송 성공/실패 시점이 다르므로, 로딩 해제·화면 전환은 모두
    // 콜백 안에서 처리한다(아래 onCodeSent/onVerified/onFailed 참고).
    await widget.authService.signInWithPhone(
      phoneNumber: e164,
      onCodeSent: (verificationId) {
        if (!mounted) return;
        setState(() => _loading = false);
        _openOtpScreen(e164, verificationId);
      },
      onVerified: (_) {
        _finishVerification();
      },
      onFailed: (message) {
        if (!mounted) return;
        setState(() => _loading = false);
        _showError(message);
      },
      linkToCurrentUser: widget.linkToCurrentUser,
    );
  }

  Future<void> _openOtpScreen(String phoneNumber, String verificationId) async {
    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => OtpVerificationScreen(
          phoneNumber: phoneNumber,
          verificationId: verificationId,
          authService: widget.authService,
          linkToCurrentUser: widget.linkToCurrentUser,
          onVerificationCompleted: widget.onVerificationCompleted,
        ),
      ),
    );
    if (!mounted) return;
    if (completed == true && widget.linkToCurrentUser) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _finishVerification() async {
    try {
      await widget.onVerificationCompleted?.call();
      if (!mounted) return;
      setState(() => _loading = false);
      if (widget.linkToCurrentUser) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('전화 인증 상태 저장에 실패했어요: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.linkToCurrentUser ? '전화번호 인증' : '전화번호로 로그인'),
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '전화번호를 입력해주세요',
                      style: TextStyle(
                        fontFamily: AppFonts.display,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '입력한 번호로 인증코드(SMS)를 보내드려요.',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      onFieldSubmitted: (_) => _requestCode(),
                      decoration: const InputDecoration(
                        labelText: '전화번호',
                        hintText: '010-1234-5678',
                        prefixIcon: Icon(Icons.phone_rounded),
                      ),
                      validator: Validators.phone,
                    ),
                    const SizedBox(height: 32),
                    PrimaryButton(
                      label: '인증코드 받기',
                      onPressed: _loading ? null : _requestCode,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_loading) const LoadingIndicator(overlay: true),
        ],
      ),
    );
  }
}
