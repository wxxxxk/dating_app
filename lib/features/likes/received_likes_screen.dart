import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/match_model.dart';
import '../../models/user_profile.dart';
import '../../services/chat/chat_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/likes/likes_service.dart';
import '../../services/location/location_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/profile/profile_insight_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/premium_components.dart';
import '../chat/chat_screen.dart';
import '../jelly/jelly_shop_screen.dart';
import '../matches/widgets/match_celebration_overlay.dart';
import '../profile/user_profile_screen.dart';
import '../profile/widgets/verification_badge.dart';

/// 나를 좋아요한 사람 목록 화면.
///
/// 내가 아직 like/pass로 응답하지 않은 받은 좋아요만 보여준다.
class ReceivedLikesScreen extends StatefulWidget {
  final String currentUid;
  final UserProfile? currentProfile;
  final FirestoreService firestoreService;
  final LikesService likesService;
  final DiscoveryService discoveryService;
  final MatchesService matchesService;
  final ChatService chatService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final SafetyService safetyService;
  final ProfileInsightService profileInsightService;

  const ReceivedLikesScreen({
    super.key,
    required this.currentUid,
    required this.currentProfile,
    required this.firestoreService,
    required this.likesService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.safetyService,
    required this.profileInsightService,
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
        ..showSnackBar(SnackBar(content: Text('응답 처리 실패: $e')));
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
          fortuneService: widget.fortuneService,
          matchesService: widget.matchesService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  void _openProfile(UserProfile profile) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          currentUid: widget.currentUid,
          initialProfile: profile,
          currentLocation: widget.currentProfile?.location,
          firestoreService: widget.firestoreService,
          safetyService: widget.safetyService,
          profileInsightService: widget.profileInsightService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '받은 좋아요',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
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
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      '받은 좋아요를 불러오지 못했어요\n${snap.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                );
              }
              final likes = snap.data ?? [];
              if (likes.isEmpty) return const _EmptyLikes();

              final shouldGate = !unlocked && likes.length > _freePreviewCount;
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: likes.length + (shouldGate ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, index) {
                  if (shouldGate && index == 0) {
                    return _UnlockLikesCard(
                      hiddenCount: likes.length - _freePreviewCount,
                      unlocking: _unlocking,
                      onUnlock: _unlockReceivedLikes,
                    );
                  }
                  final likeIndex = shouldGate ? index - 1 : index;
                  final like = likes[likeIndex];
                  final locked = shouldGate && likeIndex >= _freePreviewCount;
                  return _ReceivedLikeTile(
                    like: like,
                    currentLocation: widget.currentProfile?.location,
                    processing: _processingUids.contains(like.uid),
                    locked: locked,
                    onProfileTap: () => _openProfile(like.profile),
                    onLike: () => _respond(like, 'like'),
                    onPass: () => _respond(like, 'pass'),
                  );
                },
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

class _ReceivedLikeTile extends StatelessWidget {
  final ReceivedLike like;
  final UserLocation? currentLocation;
  final bool processing;
  final bool locked;
  final VoidCallback onProfileTap;
  final VoidCallback onLike;
  final VoidCallback onPass;

  const _ReceivedLikeTile({
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
    final profile = like.profile;
    final photoUrl = profile.photoUrls.isNotEmpty
        ? profile.photoUrls.first
        : null;
    final distanceKm = LocationService.distanceBetween(
      currentLocation,
      profile.location,
    );
    final distanceLabel = distanceKm == null
        ? null
        : LocationService.formatDistance(distanceKm);
    final interestLabels = ProfileOptions.keysToLabels(
      ProfileOptions.interests,
      profile.interests,
    ).take(2).toList();

    final content = Card(
      elevation: 0,
      color: like.isSuperlike
          ? AppColors.water.withValues(alpha: 0.16)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(
          color: like.isSuperlike
              ? AppColors.water.withValues(alpha: 0.7)
              : AppColors.border,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.button),
              child: SizedBox(
                width: 88,
                height: 116,
                child: photoUrl == null
                    ? const ColoredBox(
                        color: AppColors.surface,
                        child: Icon(
                          Icons.person_rounded,
                          color: AppColors.textSecondary,
                        ),
                      )
                    : Image.network(photoUrl, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${profile.displayName}, ${profile.age}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (like.isSuperlike) ...[
                    const SizedBox(height: 6),
                    const PremiumStatusPill(
                      label: '슈퍼라이크',
                      icon: Icons.star_rounded,
                      color: AppColors.water,
                      compact: true,
                    ),
                  ],
                  if (profile.verifications.hasAny) ...[
                    const SizedBox(height: 6),
                    VerificationBadges(
                      verifications: profile.verifications,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    distanceLabel == null
                        ? _likeMessage(like)
                        : '$distanceLabel · ${_likeMessage(like)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (profile.bio.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      stripEmoji(profile.bio),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                  if (interestLabels.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: interestLabels
                          .map(
                            (label) => PremiumStatusPill(
                              label: label,
                              color: AppColors.mint,
                              compact: true,
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: processing || locked ? null : onPass,
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('패스'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textSecondary,
                            side: const BorderSide(
                              color: AppColors.border,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: processing || locked ? null : onLike,
                          icon: processing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.favorite_rounded, size: 16),
                          label: const Text('좋아요'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!locked) {
      return InkWell(
        onTap: onProfileTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: content,
      );
    }
    return Stack(
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: IgnorePointer(child: content),
        ),
        Positioned.fill(
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: const PremiumStatusPill(
              label: '멤버십으로 확인',
              icon: Icons.lock_rounded,
              color: AppColors.mintDeep,
            ),
          ),
        ),
      ],
    );
  }

  static String _likeMessage(ReceivedLike like) {
    return like.isSuperlike ? '나에게 슈퍼라이크를 보냈어요' : '나를 좋아요했어요';
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

class _EmptyLikes extends StatelessWidget {
  const _EmptyLikes();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.hero),
            border: Border.all(color: AppColors.border),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.favorite_border_rounded,
                size: 72,
                color: AppColors.mintDeep,
              ),
              SizedBox(height: 20),
              Text(
                '아직 받은 좋아요가 없어요',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: 10),
              Text(
                '누군가 나를 좋아요하면 여기에서 바로 응답할 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
