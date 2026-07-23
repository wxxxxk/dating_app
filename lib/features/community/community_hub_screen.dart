import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../shared/widgets/app_components.dart';
import '../../services/auth/auth_service.dart';
import '../../services/community/community_media_service.dart';
import '../../services/community/community_service.dart';
import '../../services/community/party_service.dart';
import '../../services/privacy/contact_avoidance_service.dart';
import '../../services/safety/safety_service.dart';
import 'feed/feed_screen.dart';
import 'group_chat/party_group_chat_list_screen.dart';
import 'lounge/lounge_screen.dart';
import 'party/party_square_screen.dart';

/// 커뮤니티 홈(Phase 4-2) — 목적지 선택 화면.
///
/// 네 목적지를 모두 실제 화면으로 연결한다(Phase 4-5에서 그룹 채팅까지 열림).
/// 목록은 여기서 구독하지 않는다 — 각 목적지 화면이 단독으로 구독한다.
class CommunityHubScreen extends StatelessWidget {
  final AuthService authService;
  final CommunityService communityService;
  final CommunityMediaService mediaService;
  final PartyService partyService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const CommunityHubScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.mediaService,
    required this.partyService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

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

  void _openPartySquare(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartySquareScreen(
          authService: authService,
          partyService: partyService,
          safetyService: safetyService,
          contactAvoidanceService: contactAvoidanceService,
        ),
      ),
    );
  }

  void _openGroupChatList(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartyGroupChatListScreen(
          authService: authService,
          partyService: partyService,
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
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('커뮤니티', style: AppTextStyles.cardTitle),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth < 360
                ? AppSpacing.screenHCompact
                : AppSpacing.screenH;
            // 2열 타일은 여유 폭이 있을 때만. 좁은 기기에서는 세로로 쌓아
            // 터치 영역과 문구를 우선한다.
            final twoColumn = constraints.maxWidth - horizontal * 2 >= 320;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontal,
                AppSpacing.xs,
                horizontal,
                28,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── A. Community hero ─────────────────────────────────
                  const _CommunityHero(),
                  const SizedBox(height: AppSpacing.xxl),

                  // ── B. 가볍게 이야기해요 ───────────────────────────────
                  const _CommunitySectionLabel('가볍게 이야기해요'),
                  const SizedBox(height: AppSpacing.lg),
                  _LoungeDestinationCard(onTap: () => _openLounge(context)),
                  const SizedBox(height: AppSpacing.md),
                  _FeedDestinationCard(onTap: () => _openFeed(context)),
                  const SizedBox(height: AppSpacing.xxl),

                  // ── C. 함께 모여요 ─────────────────────────────────────
                  const _CommunitySectionLabel('함께 모여요'),
                  const SizedBox(height: AppSpacing.lg),
                  if (twoColumn)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _PartyDestinationTile(
                              onTap: () => _openPartySquare(context),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: _GroupChatDestinationTile(
                              onTap: () => _openGroupChatList(context),
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    _PartyDestinationTile(
                      onTap: () => _openPartySquare(context),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _GroupChatDestinationTile(
                      onTap: () => _openGroupChatList(context),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xxl),

                  // ── D. 안전 고지 ───────────────────────────────────────
                  const _CommunitySafetyNotice(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ═══ A. Hero ═════════════════════════════════════════════════════════════════

class _CommunityHero extends StatelessWidget {
  const _CommunityHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.heroPadding),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfacePrimary,
            AppColors.expressiveAccentSoft,
            AppColors.surfaceMintSoft,
          ],
          stops: [0.1, 0.62, 1],
        ),
        borderRadius: BorderRadius.circular(AppRadius.heroSoft),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Stack(
        children: [
          // 장식이므로 스크린리더에서 제외한다.
          const Positioned(
            top: -8,
            right: -8,
            width: 96,
            height: 56,
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: ConnectionMotif(strokeWidth: 1.6, opacity: 0.65),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '함께 연결되는 공간',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.brandPrimaryStrong,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 252),
                child: const Text(
                  '어떤 이야기를 나눠볼까요?',
                  style: AppTextStyles.screenTitle,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // 기존 문구 유지.
              const Text(
                '취향과 일상을 나누며 새로운 사람들과 가볍게 연결해보세요.',
                style: AppTextStyles.bodySecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommunitySectionLabel extends StatelessWidget {
  final String text;

  const _CommunitySectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 2,
          decoration: BoxDecoration(
            color: AppColors.brandPrimary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            text,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.brandPrimaryStrong,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══ B. 주요 목적지 (라운지 · 피드) ═══════════════════════════════════════════

/// 목적지 카드의 공통 뼈대.
///
/// [cardKey]는 기존 테스트/라우팅 계약이라 그대로 유지한다. preview는 실제
/// 데이터를 조회하지 않는 추상 도형이고, 상태는 색이 아니라 `이용 가능`
/// 텍스트로 전달한다.
class _DestinationShell extends StatelessWidget {
  final Key cardKey;
  final Widget preview;
  final String title;
  final String description;
  final bool compact;
  final VoidCallback onTap;

  const _DestinationShell({
    required this.cardKey,
    required this.preview,
    required this.title,
    required this.description,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: preview),
                const SizedBox(height: AppSpacing.lg),
                Text(title, style: AppTextStyles.cardTitle),
                const SizedBox(height: 4),
                Text(description, style: AppTextStyles.caption),
                const SizedBox(height: AppSpacing.md),
                const _AvailableChip(),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ExcludeSemantics(child: preview),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.cardTitle,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          const _AvailableChip(),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(description, style: AppTextStyles.caption),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: AppColors.textMuted,
                ),
              ],
            ),
    );

    // 카드 전체가 하나의 버튼이다. key는 Material에 그대로 둬서 기존
    // find.byKey(...) + tap 계약이 유지된다.
    return Material(
      key: cardKey,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.surface),
      child: AppPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        child: content,
      ),
    );
  }
}

/// 상태 표시. 색만이 아니라 `이용 가능` 텍스트로 읽힌다.
class _AvailableChip extends StatelessWidget {
  const _AvailableChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.brandPrimarySoft,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        '이용 가능',
        style: AppTextStyles.caption.copyWith(
          fontSize: 11,
          color: AppColors.brandPrimaryStrong,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 라운지 — 텍스트 중심의 가벼운 대화. 겹치는 말풍선으로 표현한다.
class _LoungeDestinationCard extends StatelessWidget {
  final VoidCallback onTap;

  const _LoungeDestinationCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _DestinationShell(
      cardKey: const ValueKey('community-destination-lounge'),
      title: '라운지',
      description: '가벼운 주제로 편하게 이야기해요',
      onTap: onTap,
      preview: const _LoungePreview(),
    );
  }
}

class _LoungePreview extends StatelessWidget {
  const _LoungePreview();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      height: 54,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 2,
            child: _Bubble(
              width: 38,
              height: 22,
              color: AppColors.surfaceMintSoft,
              borderColor: AppColors.brandPrimary.withValues(alpha: 0.35),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 2,
            child: _Bubble(
              width: 42,
              height: 24,
              color: AppColors.surfaceSecondary,
              borderColor: AppColors.borderSubtle,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final Color borderColor;

  const _Bubble({
    required this.width,
    required this.height,
    required this.color,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: borderColor),
      ),
    );
  }
}

/// 피드 — 사진과 일상. 실제 사진처럼 보이는 가짜 이미지를 쓰지 않고
/// 빈 프레임만 겹쳐 놓는다.
class _FeedDestinationCard extends StatelessWidget {
  final VoidCallback onTap;

  const _FeedDestinationCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _DestinationShell(
      cardKey: const ValueKey('community-destination-feed'),
      title: '피드',
      description: '일상과 취향을 사진과 함께 나눠요',
      onTap: onTap,
      preview: const _FeedPreview(),
    );
  }
}

class _FeedPreview extends StatelessWidget {
  const _FeedPreview();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      height: 54,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            bottom: 0,
            child: _Frame(
              size: 34,
              color: AppColors.surfaceSecondary,
              borderColor: AppColors.borderSubtle,
            ),
          ),
          Positioned(
            left: 12,
            top: 8,
            child: _Frame(
              size: 32,
              color: AppColors.expressiveAccentSoft,
              borderColor: AppColors.expressiveAccent.withValues(alpha: 0.35),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: _Frame(
              size: 26,
              color: AppColors.surfaceMintSoft,
              borderColor: AppColors.brandPrimary.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  final double size;
  final Color color;
  final Color borderColor;

  const _Frame({
    required this.size,
    required this.color,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: borderColor),
      ),
    );
  }
}

// ═══ C. 모임 목적지 (파티·스퀘어 · 그룹 채팅) ═════════════════════════════════

/// 파티·스퀘어 — 관심사 모임. 겹치는 원으로 "여럿이 모인다"를 표현한다.
class _PartyDestinationTile extends StatelessWidget {
  final VoidCallback onTap;

  const _PartyDestinationTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _DestinationShell(
      cardKey: const ValueKey('community-destination-party-square'),
      title: '파티·스퀘어',
      description: '관심사 모임과 공개 이벤트를 찾아봐요',
      compact: true,
      onTap: onTap,
      preview: const _CirclePreview(
        accent: AppColors.brandPrimary,
        icon: Icons.event_outlined,
      ),
    );
  }
}

/// 그룹 채팅 — 참여 중인 파티의 대화.
class _GroupChatDestinationTile extends StatelessWidget {
  final VoidCallback onTap;

  const _GroupChatDestinationTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _DestinationShell(
      cardKey: const ValueKey('community-destination-group-chat'),
      title: '그룹 채팅',
      description: '참여 중인 파티에서 함께 대화해요',
      compact: true,
      onTap: onTap,
      preview: const _CirclePreview(
        accent: AppColors.expressiveAccent,
        icon: Icons.forum_outlined,
      ),
    );
  }
}

/// 겹치는 빈 원 + 작은 아이콘. 실제 프로필 사진이나 참여자 수를 쓰지 않는다.
class _CirclePreview extends StatelessWidget {
  final Color accent;
  final IconData icon;

  const _CirclePreview({required this.accent, required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 66,
      height: 34,
      child: Stack(
        children: [
          Positioned(left: 0, child: _Ring(color: AppColors.borderStrong)),
          Positioned(left: 18, child: _Ring(color: AppColors.borderStrong)),
          Positioned(
            left: 36,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(color: accent.withValues(alpha: 0.4)),
              ),
              child: Icon(icon, size: 17, color: AppColors.brandPrimaryStrong),
            ),
          ),
        ],
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  final Color color;

  const _Ring({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        shape: BoxShape.circle,
        border: Border.all(color: color),
      ),
    );
  }
}

// ═══ D. 안전 고지 ════════════════════════════════════════════════════════════

/// 문구는 그대로 두고, 화면 최상단이 아니라 하단의 조용한 뉴트럴 블록으로
/// 배치한다. 경고처럼 보이지 않게 warning/danger 색을 쓰지 않는다.
class _CommunitySafetyNotice extends StatelessWidget {
  const _CommunitySafetyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 18, color: AppColors.textMuted),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              '개인정보·연락처·인증번호·금전 정보는 공개 글에 올리지 마세요.',
              style: AppTextStyles.caption,
            ),
          ),
        ],
      ),
    );
  }
}
