import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/validators.dart';
import '../../services/auth/auth_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';

/// 비밀번호 재설정 화면 (M2.6).
///
/// 이메일을 입력하면 재설정 링크를 발송한다.
/// 발송 성공 후 성공 상태(UI)로 전환 → 로그인 화면으로 돌아간다.
class PasswordResetScreen extends StatefulWidget {
  final AuthService authService;
  const PasswordResetScreen({super.key, required this.authService});

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();

  bool _loading = false;
  bool _sent = false; // 발송 완료 상태

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      await widget.authService.sendPasswordResetEmail(
        email: _emailController.text,
      );
      if (mounted) setState(() => _sent = true);
    } on AuthFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(e.message),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('비밀번호 재설정'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              child: _sent ? _buildSuccess() : _buildForm(),
            ),
          ),
          if (_loading) const LoadingIndicator(overlay: true),
        ],
      ),
    );
  }

  // ── 입력 폼 ───────────────────────────────────────────────────────────────

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '비밀번호를 잊으셨나요?',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '가입한 이메일 주소를 입력하면\n비밀번호 재설정 링크를 보내드려요.',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            onFieldSubmitted: (_) => _handleSend(),
            decoration: const InputDecoration(
              labelText: '이메일',
              hintText: 'example@email.com',
              prefixIcon: Icon(Icons.email_outlined),
            ),
            validator: Validators.email,
          ),
          const SizedBox(height: 32),
          PrimaryButton(
            label: '재설정 메일 보내기',
            onPressed: _loading ? null : _handleSend,
          ),
        ],
      ),
    );
  }

  // ── 발송 완료 상태 UI ─────────────────────────────────────────────────────

  Widget _buildSuccess() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        const Icon(Icons.check_circle_outline,
            size: 72, color: AppColors.primary),
        const SizedBox(height: 24),
        const Text(
          '재설정 메일을 보냈어요',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
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
                text: _emailController.text.trim(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const TextSpan(text: '\n으로 재설정 링크를 보냈어요.\n메일을 확인해주세요.'),
            ],
          ),
        ),
        const Spacer(flex: 3),
        PrimaryButton(
          label: '로그인 화면으로',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
