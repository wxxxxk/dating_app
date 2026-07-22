import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/widgets/primary_button.dart';

/// 프로필을 불러오지 못했을 때 보여주는 복구 화면.
///
/// 이 화면이 존재하는 이유: 조회 실패를 "프로필 없음"으로 처리하면 기존 유저가
/// 온보딩 첫 단계(사진 등록)로 떨어지고 돌아올 길이 없어진다. 실패는 실패로
/// 표시하고, 재시도와 로그아웃이라는 두 개의 출구를 항상 남긴다.
class AuthGateErrorView extends StatelessWidget {
  const AuthGateErrorView({
    super.key,
    required this.onRetry,
    required this.onSignOut,
    this.busy = false,
  });

  final VoidCallback onRetry;
  final VoidCallback onSignOut;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('auth-gate-error'),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  size: 48,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '프로필을 불러오지 못했어요.',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '인터넷 연결을 확인하고 다시 시도해 주세요.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xl),
                PrimaryButton(
                  key: const Key('auth-gate-retry-button'),
                  label: '다시 시도',
                  onPressed: busy ? null : onRetry,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  key: const Key('auth-gate-sign-out-button'),
                  onPressed: busy ? null : onSignOut,
                  child: const Text('로그아웃하고 로그인 화면으로 이동'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
