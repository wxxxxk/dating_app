import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/auth/auth_service.dart';
import '../../services/community/community_media_service.dart';
import '../../services/community/community_service.dart';
import '../../services/privacy/contact_avoidance_service.dart';
import '../../services/safety/safety_service.dart';
import 'feed/feed_screen.dart';
import 'lounge/lounge_screen.dart';

/// 커뮤니티 홈(Phase 4-2) — 목적지 선택 화면.
///
/// 네 목적지를 소개하고, 그중 라운지만 실제 화면([LoungeScreen])으로 연결한다.
/// 게시물 목록은 여기서 구독하지 않는다 — 라운지 화면이 단독으로 구독한다.
class CommunityHubScreen extends StatelessWidget {
  final AuthService authService;
  final CommunityService communityService;
  final CommunityMediaService mediaService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const CommunityHubScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.mediaService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  void _showComingSoon(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openLounge(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoungeScreen(
          authService: authService,
          communityService: communityService,
          safetyService: safetyService,
          contactAvoidanceService: contactAvoidanceService,
        ),
      ),
    );
  }

  void _openFeed(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FeedScreen(
          authService: authService,
          communityService: communityService,
          mediaService: mediaService,
          safetyService: safetyService,
          contactAvoidanceService: contactAvoidanceService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('community-hub-screen'),
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('커뮤니티'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '취향과 일상을 나누며 새로운 사람들과 가볍게 연결해보세요.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.mintSoft,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 17,
                      color: AppColors.mintDeep,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '개인정보·연락처·인증번호·금전 정보는 공개 글에 올리지 마세요.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-lounge'),
                icon: Icons.chat_bubble_outline_rounded,
                title: '라운지',
                description: '가벼운 주제로 편하게 이야기해요',
                statusLabel: '이용 가능',
                available: true,
                onTap: () => _openLounge(context),
              ),
              const SizedBox(height: 10),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-feed'),
                icon: Icons.photo_library_outlined,
                title: '피드',
                description: '일상과 취향을 사진과 함께 나눠요',
                statusLabel: '이용 가능',
                available: true,
                onTap: () => _openFeed(context),
              ),
              const SizedBox(height: 10),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-party-square'),
                icon: Icons.celebration_outlined,
                title: '파티·스퀘어',
                description: '관심사 모임과 공개 이벤트를 찾아봐요',
                statusLabel: '준비 중',
                available: false,
                onTap: () =>
                    _showComingSoon(context, '파티·스퀘어는 다음 단계에서 열릴 예정이에요.'),
              ),
              const SizedBox(height: 10),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-group-chat'),
                icon: Icons.groups_outlined,
                title: '그룹 채팅',
                description: '관심사가 맞는 사람들과 소규모로 대화해요',
                statusLabel: '준비 중',
                available: false,
                onTap: () =>
                    _showComingSoon(context, '그룹 채팅은 다음 단계에서 열릴 예정이에요.'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 커뮤니티 목적지 카드. 준비 중인 목적지는 그렇게만 표시하고, 참여자 수·인기
/// 순위 같은 가짜 지표를 만들지 않는다.
class _DestinationCard extends StatelessWidget {
  final Key cardKey;
  final IconData icon;
  final String title;
  final String description;
  final String statusLabel;
  final bool available;
  final VoidCallback onTap;

  const _DestinationCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.description,
    required this.statusLabel,
    required this.available,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: cardKey,
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 20,
                color: available ? AppColors.mintDeep : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: available ? AppColors.mintSoft : AppColors.background,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  border: Border.all(
                    color: available ? AppColors.mintSoft : AppColors.border,
                  ),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: available
                        ? AppColors.mintDeep
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
