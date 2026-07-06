import 'package:flutter/material.dart';

import '../../core/routes/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/validators.dart';
import '../../services/auth/auth_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';
import 'password_reset_screen.dart';

/// 인증 시작 화면 (M2.6).
///
/// 이메일/비밀번호 로그인이 메인, 구글 로그인이 하단 소셜 옵션.
/// 로그인 성공 → authStateChanges 스트림 → app.dart _AuthGate가 자동으로 다음 화면으로 전환.
class LoginScreen extends StatefulWidget {
  final AuthService authService;
  const LoginScreen({super.key, required this.authService});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ── 이메일 로그인 ────────────────────────────────────────────────────────

  Future<void> _handleEmailSignIn() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      await widget.authService.signInWithEmail(
        email: _emailController.text,
        password: _passwordController.text,
      );
      // 성공 시 _AuthGate가 authStateChanges를 받아 자동으로 화면을 전환한다.
    } on AuthFailure catch (e) {
      if (mounted) _showError(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 구글 로그인 ──────────────────────────────────────────────────────────

  Future<void> _handleGoogleSignIn() async {
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final result = await widget.authService.signInWithGoogle();
      if (result == null && mounted) {
        _showError('로그인이 취소되었습니다.');
      }
    } on AuthFailure catch (e) {
      if (mounted) _showError(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
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
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 56),

                    // ── 로고 ─────────────────────────────────────────────
                    const Icon(Icons.favorite,
                        color: AppColors.primary, size: 56),
                    const SizedBox(height: 12),
                    const Text(
                      '오늘의 인연',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 48),

                    // ── 이메일 입력 ───────────────────────────────────────
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '이메일',
                        hintText: 'example@email.com',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      validator: Validators.email,
                    ),
                    const SizedBox(height: 12),

                    // ── 비밀번호 입력 ─────────────────────────────────────
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _handleEmailSignIn(),
                      decoration: InputDecoration(
                        labelText: '비밀번호',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) =>
                          v == null || v.isEmpty ? '비밀번호를 입력해주세요.' : null,
                    ),
                    const SizedBox(height: 8),

                    // ── 비밀번호 찾기 ─────────────────────────────────────
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _loading
                            ? null
                            : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PasswordResetScreen(
                                        authService: widget.authService),
                                  ),
                                ),
                        child: const Text(
                          '비밀번호를 잊으셨나요?',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ── 로그인 버튼 ───────────────────────────────────────
                    PrimaryButton(
                      label: '로그인',
                      onPressed: _loading ? null : _handleEmailSignIn,
                    ),
                    const SizedBox(height: 20),

                    // ── 회원가입 링크 ─────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          '계정이 없으신가요?',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        TextButton(
                          onPressed: _loading
                              ? null
                              : () => Navigator.pushNamed(
                                  context, AppRoutes.signup),
                          child: const Text(
                            '회원가입',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),

                    // ── 구분선 "또는" ─────────────────────────────────────
                    Row(
                      children: [
                        const Expanded(
                          child: Divider(color: AppColors.border),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            '또는',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        const Expanded(
                          child: Divider(color: AppColors.border),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── 구글 소셜 버튼 ────────────────────────────────────
                    PrimaryButton(
                      label: 'Google로 계속하기',
                      outlined: true,
                      icon: const Icon(Icons.g_mobiledata, size: 26),
                      onPressed: _loading ? null : _handleGoogleSignIn,
                    ),
                    const SizedBox(height: 32),

                    // ── 이용약관 안내 ─────────────────────────────────────
                    const Text(
                      '계속 진행하면 이용약관 및 개인정보처리방침에\n동의하는 것으로 간주됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 24),
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
