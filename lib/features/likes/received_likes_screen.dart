import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/match_model.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/chat/appointment_safety_service.dart';
import '../../services/chat/chat_presence_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/likes/likes_service.dart';
import '../../services/location/location_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/app_components.dart';
import '../../shared/widgets/premium_components.dart';
import '../chat/chat_screen.dart';
import '../jelly/jelly_shop_screen.dart';
import '../matches/widgets/match_celebration_overlay.dart';
import '../profile/user_profile_screen.dart';
import '../profile/widgets/verification_badge.dart';

/// 나를 좋아요한 사람 목록 화면.
///
/// 내가 아직 like/pass로 응답하지 않은 받은 좋아요만 보여준다.
///
/// Warm Interest Gallery — 사진 중심의 큰 세로 카드로, 나에게 관심을 표현한
/// 사람을 검토하고 바로 응답하도록 정리한다. 무료 미리보기(2명) 이후 카드는
/// 기존 젤리 게이트/블러 계약 그대로 잠긴다.
class ReceivedLikesScreen extends StatefulWidget {
  final String currentUid;
  final UserProfile? currentProfile;
  final FirestoreService firestoreService;
  final LikesService likesService;
  final DiscoveryService discoveryService;
  final MatchesService matchesService;
  final ChatService chatService;
  final ChatPresenceService presenceService;
  final AppointmentSafetyService appointmentSafetyService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final SafetyService safetyService;

  const ReceivedLikesScreen({
    super.key,
    required this.currentUid,
    required this.currentProfile,
    required this.firestoreService,
    required this.likesService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.presenceService,
    required this.appointmentSafetyService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.safetyService,
  });

  @override
  State<ReceivedLikesScreen> createState() => _ReceivedLikesScreenState();
}

class _ReceivedLikesScreenState extends State<ReceivedLikesScreen> {
  static const int _freePreviewCount = 2;
  final Set<String> _processingUids = {};
  bool _unlocking = false;

  Future<void> _respond(ReceivedLike like, String action) async {
    if (_processingUids.contains(like.uid)) return;
    setState(() => _processingUids.add(like.uid));
    try {
      await widget.discoveryService.recordSwipe(
        currentUid: widget.currentUid,
        targetUid: like.uid,
        action: action,
      );

      if (action == 'like') {
        final match = await _pollForMatch(like.uid);
        if (match != null && mounted) {
          _showMatch(match);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('응답 처리에 실패했어요. 잠시 후 다시 시도해주세요.')),
        );
      if (kDebugMode) debugPrint('[ReceivedLikes] 응답 처리 실패: $e');
    } finally {
      if (mounted) setState(() => _processingUids.remove(like.uid));
    }
  }

  /// 받은 좋아요에 응답하면 Cloud Function이 matches 문서를 만든다.
  /// 콜드 스타트 지연을 감안해 디스커버리와 같은 방식으로 짧게 폴링한다.
  Future<MatchWithProfile?> _pollForMatch(String targetUid) async {
    for (final delay in [
      const Duration(milliseconds: 700),
      const Duration(milliseconds: 1200),
      const Duration(seconds: 2),
    ]) {
      await Future.delayed(delay);
      if (!mounted) return null;
      final match = await widget.matchesService.checkForMatch(
        currentUid: widget.currentUid,
        targetUid: targetUid,
      );
      if (match != null) return match;
    }
    return null;
  }

  void _showMatch(MatchWithProfile match) {
    widget.matchesService
        .markCelebrated(matchId: match.match.matchId, uid: widget.currentUid)
        .catchError((e) {
          if (kDebugMode) debugPrint('[ReceivedLikes] 매칭 축하 기록 실패: $e');
        });
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppColors.background.withValues(alpha: 0),
      pageBuilder: (ctx, _, _) => MatchCelebrationOverlay(
        match: match,
        currentUserPhotoUrl: widget.currentProfile?.photoUrls.isNotEmpty == true
            ? widget.currentProfile!.photoUrls.first
            : '',
        onKeepSwiping: () => Navigator.pop(ctx),
        onChat: () => _openChatFromCelebration(ctx, match),
      ),
    );
  }

  void _openChatFromCelebration(
    BuildContext overlayContext,
    MatchWithProfile match,
  ) {
    Navigator.pop(overlayContext);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          matchId: match.match.matchId,
          otherProfile: match.otherProfile,
          currentUid: widget.currentUid,
          chatService: widget.chatService,
          presenceService: widget.presenceService,
          appointmentSafetyService: widget.appointmentSafetyService,
          fortuneService: widget.fortuneService,
          matchesService: widget.matchesService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  void _openProfile(PublicProfile profile) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          currentUid: widget.currentUid,
          initialProfile: profile,
          currentLocation: widget.currentProfile?.location,
          firestoreService: widget.firestoreService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        title: const Text(
          '받은 좋아요',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: AppColors.warmCanvas,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          JellyBalanceButton(
            currentUid: widget.currentUid,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            foregroundColor: AppColors.matchPrimary,
          ),
        ],
      ),
      body: StreamBuilder<bool>(
        stream: widget.jellyService.watchReceivedLikesUnlocked(
          widget.currentUid,
        ),
        builder: (context, unlockSnap) {
          final unlocked = unlockSnap.data ?? false;
          return StreamBuilder<List<ReceivedLike>>(
            stream: widget.likesService.watchReceivedLikes(
              currentUid: widget.currentUid,
            ),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const _LikesLoading();
              }
              if (snap.hasError) {
                if (kDebugMode) {
                  debugPrint('[ReceivedLikes] 받은 좋아요 로드 실패: ${snap.error}');
                }
                return const _LikesError();
              }
              final likes = snap.data ?? [];
              if (likes.isEmpty) return const _EmptyLikes();

              final shouldGate = !unlocked && likes.length > _freePreviewCount;

              return ListView(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.xl + MediaQuery.of(context).padding.bottom,
                ),
                children: [
                  AppFadeSlideIn(child: _LikesHeader(count: likes.length)),
                  const SizedBox(height: AppSpacing.lg),
                  if (shouldGate) ...[
                    _UnlockLikesCard(
                      hiddenCount: likes.length - _freePreviewCount,
                      unlocking: _unlocking,
                      onUnlock: _unlockReceivedLikes,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  for (var i = 0; i < likes.length; i++) ...[
                    _ReceivedLikeCard(
                      like: likes[i],
                      currentLocation: widget.currentProfile?.location,
                      processing: _processingUids.contains(likes[i].uid),
                      locked: shouldGate && i >= _freePreviewCount,
                      onProfileTap: () => _openProfile(likes[i].profile),
                      onLike: () => _respond(likes[i], 'like'),
                      onPass: () => _respond(likes[i], 'pass'),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _unlockReceivedLikes() async {
    if (_unlocking) return;
    setState(() => _unlocking = true);
    try {
      final ok = await widget.jellyService.unlockReceivedLikes(
        widget.currentUid,
      );
      if (!ok) {
        await _showJellyShortage();
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('받은 좋아요 전체보기를 열었어요.')));
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  Future<void> _showJellyShortage() async {
    final goShop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('젤리가 부족해요'),
        content: Text(
          '받은 좋아요 전체보기에는 젤리 ${JellyCosts.unlockReceivedLikes}개가 필요해요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('충전하기'),
          ),
        ],
      ),
    );
    if (goShop == true && mounted) {
      await openJellyShop(
        context: context,
        currentUid: widget.currentUid,
        jellyService: widget.jellyService,
        jellyPurchaseService: widget.jellyPurchaseService,
      );
    }
  }
}

// ═══ 감정 헤더 ════════════════════════════════════════════════════════════════

class _LikesHeader extends StatelessWidget {
  final int count;
  const _LikesHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfacePrimary,
            AppColors.expressiveAccentSoft,
            AppColors.surfaceMintSoft,
          ],
          stops: [0.1, 0.6, 1],
        ),
        borderRadius: BorderRadius.circular(AppRadius.heroSoft),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Stack(
        children: [
          const Positioned(
            top: -8,
            right: -8,
            width: 92,
            height: 54,
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: ConnectionMotif(
                  strokeWidth: 1.6,
                  opacity: 0.7,
                  primaryColor: AppColors.expressiveAccent,
                  accentColor: AppColors.brandPrimary,
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '나에게 온 마음',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.expressiveAccent,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  '누가 나에게 관심을 보냈을까요?',
                  style: AppTextStyles.screenTitle,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text.rich(
                TextSpan(
                  style: AppTextStyles.bodySecondary,
                  children: [
                    TextSpan(
                      text: '$count명',
                      style: const TextStyle(
                        color: AppColors.expressiveAccent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const TextSpan(text: '이 나에게 마음을 보냈어요.'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══ 좋아요 카드 (사진 중심) ═══════════════════════════════════════════════════

class _ReceivedLikeCard extends StatelessWidget {
  final ReceivedLike like;
  final UserLocation? currentLocation;
  final bool processing;
  final bool locked;
  final VoidCallback onProfileTap;
  final VoidCallback onLike;
  final VoidCallback onPass;

  const _ReceivedLikeCard({
    required this.like,
    required this.currentLocation,
    required this.processing,
    required this.locked,
    required this.onProfileTap,
    required this.onLike,
    required this.onPass,
  });

  @override
  Widget build(BuildContext context) {
    final content = _cardBody(context);

    if (!locked) {
      return AppPressable(
        onTap: onProfileTap,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        child: content,
      );
    }

    // 잠긴 카드: 블러 + 반투명 오버레이. 개인정보는 새로 드러나지 않고,
    // 잠금 이유와 이용 방법(멤버십)만 표시한다. 액션은 IgnorePointer로 막는다.
    return Semantics(
      label: '멤버십으로 확인할 수 있는 잠긴 좋아요',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.surface),
        child: Stack(
          children: [
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: IgnorePointer(child: content),
            ),
            Positioned.fill(
              child: Container(
                alignment: Alignment.center,
                color: AppColors.surfacePrimary.withValues(alpha: 0.82),
                child: const PremiumStatusPill(
                  label: '멤버십으로 확인',
                  icon: Icons.lock_rounded,
                  color: AppColors.mintDeep,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardBody(BuildContext context) {
    final profile = like.profile;
    final superlike = like.isSuperlike;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(
          color: superlike
              ? AppColors.water.withValues(alpha: 0.5)
              : AppColors.borderSubtle,
        ),
        boxShadow: AppShadows.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardPhoto(
            photoUrl: profile.photoUrls.isNotEmpty
                ? profile.photoUrls.first
                : null,
            superlike: superlike,
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: _CardInfo(
              like: like,
              currentLocation: currentLocation,
              processing: processing,
              locked: locked,
              onLike: onLike,
              onPass: onPass,
            ),
          ),
        ],
      ),
    );
  }
}

/// 카드 상단 대표 사진. 실패/누락 시 안전한 placeholder로 대체하고
/// 네트워크 실패 이유는 노출하지 않는다. 사진 위에는 텍스트/CTA를 겹치지 않고
/// 슈퍼라이크 표시만 작은 배지로 얹는다.
class _CardPhoto extends StatelessWidget {
  final String? photoUrl;
  final bool superlike;
  const _CardPhoto({required this.photoUrl, required this.superlike});

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    return Semantics(
      image: true,
      label: '프로필 사진',
      child: AspectRatio(
        aspectRatio: 5 / 4,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: AppColors.canvasSubtle,
              child: url == null
                  ? const Center(
                      child: Icon(
                        Icons.person_rounded,
                        size: 44,
                        color: AppColors.textMuted,
                      ),
                    )
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const ColoredBox(color: AppColors.canvasSubtle);
                      },
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(
                          Icons.person_rounded,
                          size: 44,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
            ),
            if (superlike)
              const Positioned(
                top: 12,
                left: 12,
                child: PremiumStatusPill(
                  label: '슈퍼라이크',
                  icon: Icons.star_rounded,
                  color: AppColors.water,
                  compact: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CardInfo extends StatelessWidget {
  final ReceivedLike like;
  final UserLocation? currentLocation;
  final bool processing;
  final bool locked;
  final VoidCallback onLike;
  final VoidCallback onPass;

  const _CardInfo({
    required this.like,
    required this.currentLocation,
    required this.processing,
    required this.locked,
    required this.onLike,
    required this.onPass,
  });

  @override
  Widget build(BuildContext context) {
    final profile = like.profile;
    final distanceKm = LocationService.distanceToCoarse(
      currentLocation,
      profile.coarseLocation,
    );
    final distanceLabel = distanceKm == null
        ? null
        : LocationService.formatDistance(distanceKm);
    final metaText = distanceLabel == null
        ? _likeMessage(like)
        : '$distanceLabel · ${_likeMessage(like)}';
    final interestLabels = ProfileOptions.keysToLabels(
      ProfileOptions.interests,
      profile.interests,
    ).take(2).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${profile.displayName}, ${profile.age}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.cardTitle,
        ),
        if (profile.verifications.hasAny) ...[
          const SizedBox(height: 7),
          VerificationBadges(verifications: profile.verifications),
        ],
        const SizedBox(height: 6),
        Text(
          metaText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.caption,
        ),
        if (profile.bio.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            stripEmoji(profile.bio),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySecondary,
          ),
        ],
        if (interestLabels.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: interestLabels
                .map((label) => _InterestChip(label: label))
                .toList(),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            _PassButton(onPressed: processing || locked ? null : onPass),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _LikeButton(
                processing: processing,
                onPressed: processing || locked ? null : onLike,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _likeMessage(ReceivedLike like) {
    return like.isSuperlike ? '나에게 슈퍼라이크를 보냈어요' : '나를 좋아요했어요';
  }
}

class _InterestChip extends StatelessWidget {
  final String label;
  const _InterestChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(color: AppColors.textBody),
      ),
    );
  }
}

/// 보조 액션(패스): neutral outline 아이콘 버튼. danger red를 쓰지 않는다.
class _PassButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const _PassButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 48,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textBody,
          side: const BorderSide(color: AppColors.borderStrong),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ),
        child: const Icon(Icons.close_rounded, size: 20),
      ),
    );
  }
}

/// 주요 액션(좋아요): 민트 fill. loading 중에도 높이·라벨을 유지한다.
class _LikeButton extends StatelessWidget {
  final bool processing;
  final VoidCallback? onPressed;
  const _LikeButton({required this.processing, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: processing
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.onBrandPrimary,
                ),
              )
            : const Icon(Icons.favorite_rounded, size: 17),
        label: const Text('좋아요'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brandPrimaryStrong,
          foregroundColor: AppColors.onBrandPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ),
      ),
    );
  }
}

class _UnlockLikesCard extends StatelessWidget {
  final int hiddenCount;
  final bool unlocking;
  final VoidCallback onUnlock;

  const _UnlockLikesCard({
    required this.hiddenCount,
    required this.unlocking,
    required this.onUnlock,
  });

  @override
  Widget build(BuildContext context) {
    return PremiumLockedPanel(
      title: '$hiddenCount명이 더 좋아요를 보냈어요',
      description: '받은 좋아요를 모두 확인하고 마음에 드는 인연에게 바로 응답해보세요.',
      actionLabel: '전체 보기 · 젤리 ${JellyCosts.unlockReceivedLikes}개',
      onPressed: onUnlock,
      loading: unlocking,
    );
  }
}

// ═══ Empty / Loading / Error ══════════════════════════════════════════════════

class _EmptyLikes extends StatelessWidget {
  const _EmptyLikes();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 96,
              height: 56,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: ConnectionMotif(
                    opacity: 0.85,
                    primaryColor: AppColors.expressiveAccent,
                    accentColor: AppColors.brandPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            const Text(
              '아직 받은 좋아요가 없어요',
              style: AppTextStyles.sectionTitle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              '누군가 나를 좋아요하면 여기에서 바로 응답할 수 있어요.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _LikesLoading extends StatelessWidget {
  const _LikesLoading();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl + MediaQuery.of(context).padding.bottom,
      ),
      children: [
        Container(
          height: 124,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.heroSoft),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < 4; i++) ...[
          Container(
            height: 300,
            decoration: BoxDecoration(
              color: AppColors.surfaceSecondary,
              borderRadius: BorderRadius.circular(AppRadius.surface),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        const SizedBox(height: AppSpacing.sm),
        const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.brandPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _LikesError extends StatelessWidget {
  const _LikesError();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 34,
              color: AppColors.statusDanger,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              '받은 좋아요를 불러오지 못했어요.\n잠시 후 다시 시도해주세요.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary,
            ),
          ],
        ),
      ),
    );
  }
}
