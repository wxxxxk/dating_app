import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/match_model.dart';

/// "It's a Match!" 전체화면 축하 오버레이.
///
/// DiscoveryScreen에서 showGeneralDialog로 띄운다.
/// [onKeepSwiping]: 닫고 스와이프 계속
/// [onChat]: M5에서 채팅 화면으로 연결 예정 — 현재는 닫기와 동일
class MatchCelebrationOverlay extends StatelessWidget {
  final MatchWithProfile match;
  final String currentUserPhotoUrl;
  final VoidCallback onKeepSwiping;
  final VoidCallback onChat;

  const MatchCelebrationOverlay({
    super.key,
    required this.match,
    required this.currentUserPhotoUrl,
    required this.onKeepSwiping,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    final other = match.otherProfile;
    final otherPhoto = other.photoUrls.isNotEmpty ? other.photoUrls[0] : null;

    return Material(
      color: AppColors.ink.withValues(alpha: 0),
      child: Container(
        color: AppColors.seal,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),

                // 아이콘 + 타이틀
                const Icon(
                  Icons.favorite_rounded,
                  color: AppColors.surface,
                  size: 52,
                ),
                const SizedBox(height: 16),
                const Text(
                  "It's a Match!",
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    color: AppColors.surface,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${other.displayName}님과 서로 좋아요를 눌렀어요',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppColors.surface,
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 56),

                // 두 프로필 사진 (현재 유저 ↔ 상대방)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PhotoCircle(
                      photoUrl: currentUserPhotoUrl.isNotEmpty
                          ? currentUserPhotoUrl
                          : null,
                    ),
                    const SizedBox(width: 16),
                    const Icon(
                      Icons.favorite_rounded,
                      color: AppColors.surface,
                      size: 36,
                    ),
                    const SizedBox(width: 16),
                    _PhotoCircle(photoUrl: otherPhoto),
                  ],
                ),

                const Spacer(flex: 2),

                // 채팅 버튼
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onChat,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: AppColors.seal,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                    ),
                    child: const Text(
                      '채팅 시작하기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // 계속 둘러보기
                TextButton(
                  onPressed: onKeepSwiping,
                  child: const Text(
                    '계속 둘러보기',
                    style: TextStyle(
                      color: AppColors.surface,
                      fontSize: 15,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.surface,
                    ),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoCircle extends StatelessWidget {
  final String? photoUrl;
  const _PhotoCircle({required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 110,
      height: 110,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.surface, width: 3),
        color: AppColors.surface.withValues(alpha: 0.24),
        image: photoUrl != null
            ? DecorationImage(image: NetworkImage(photoUrl!), fit: BoxFit.cover)
            : null,
      ),
      child: photoUrl == null
          ? const Icon(Icons.person_rounded, size: 52, color: AppColors.surface)
          : null,
    );
  }
}
