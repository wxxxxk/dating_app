import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/match_model.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/chat/appointment_safety_service.dart';
import '../../services/chat/chat_presence_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/likes/likes_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/app_components.dart';
import '../chat/chat_screen.dart';
import '../likes/received_likes_screen.dart';
import '../profile/user_profile_screen.dart';
import '../profile/widgets/verification_badge.dart';
import 'widgets/match_celebration_overlay.dart';

/// 매칭 목록 화면 (하단 탭 1번).
///
/// matches 컬렉션을 실시간 구독하고 각 매치 상대방의 프로필과 함께 표시한다.
/// 프로필 상세와 채팅 진입을 분리해 의도한 화면만 네비게이션 스택에 쌓이게 한다.
///
/// Editorial Connections — 받은 좋아요 진입 → 아직 대화 전인 새로운 매칭 →
/// 이어지는 대화 순으로, 사람과 사진이 먼저 읽히도록 정리한다. 신규/대화 구분은
/// 새 판정 로직이 아니라 기존 계약(`lastMessage == null`)을 그대로 재사용한다.
///
/// StatefulWidget인 이유:
///   initState에서 _stream을 한 번만 생성해 재사용한다.
///   StatelessWidget이면 build() 호출마다 watchMatches()가 새 Stream 객체를
///   반환해, StreamBuilder가 구독을 취소·재연결하는 낭비가 반복된다.
class MatchesScreen extends StatefulWidget {
  final AuthService authService;
  final MatchesService matchesService;
  final ChatService chatService;
  final ChatPresenceService presenceService;
  final AppointmentSafetyService appointmentSafetyService;
  final FirestoreService firestoreService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final DiscoveryService discoveryService;
  final LikesService likesService;
  final SafetyService safetyService;

  const MatchesScreen({
    super.key,
    required this.authService,
    required this.matchesService,
    required this.chatService,
    required this.presenceService,
    required this.appointmentSafetyService,
    required this.firestoreService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.discoveryService,
    required this.likesService,
    required this.safetyService,
  });

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends State<MatchesScreen> {
  Stream<List<MatchWithProfile>>? _stream;
  Stream<List<ReceivedLike>>? _likesStream;
  String? _currentUid;
  UserProfile? _currentProfile;
  bool _celebrationChecked = false;

  @override
  void initState() {
    super.initState();
    final uid = widget.authService.currentUser?.uid;
    if (uid != null) {
      _currentUid = uid;
      _stream = widget.matchesService.watchMatches(currentUid: uid);
      _likesStream = widget.likesService.watchReceivedLikes(currentUid: uid);
      _loadCurrentProfile(uid);
      _checkPendingCelebration(uid);
    }
  }

  Future<void> _loadCurrentProfile(String uid) async {
    final profile = await widget.firestoreService.getUserProfile(uid);
    if (mounted) setState(() => _currentProfile = profile);
  }

  /// 매칭 탭 진입 시 "아직 이 uid가 축하를 못 본 매칭"이 있는지 한 번만 확인한다.
  ///
  /// celebratedBy가 아예 없는 매치(이 기능 이전에 생성됐거나, 스와이프 쪽의
  /// markCelebrated 기록이 실패한 경우)는 대상에서 제외한다 — 그래야 기존
  /// 매치 전체가 한꺼번에 축하 대상으로 뜨는 걸 막을 수 있다.
  /// 여러 건이 대기 중이면 가장 최근 매치(스트림이 matchedAt desc 정렬) 하나만 보여준다.
  Future<void> _checkPendingCelebration(String uid) async {
    final stream = _stream;
    if (stream == null || _celebrationChecked) return;
    try {
      final matches = await stream.first;
      if (!mounted || _celebrationChecked) return;
      _celebrationChecked = true;

      MatchWithProfile? pending;
      for (final mwp in matches) {
        if (mwp.match.isPendingCelebrationFor(uid)) {
          pending = mwp;
          break;
        }
      }
      if (pending == null) return;

      final toShow = pending;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPendingCelebration(toShow, uid);
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[Matches] 미확인 매칭 축하 체크 실패: $e');
    }
  }

  void _showPendingCelebration(MatchWithProfile mwp, String uid) {
    void markSeen() {
      widget.matchesService
          .markCelebrated(matchId: mwp.match.matchId, uid: uid)
          .catchError((e) {
            if (kDebugMode) debugPrint('[Matches] 매칭 축하 기록 실패: $e');
          });
    }

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppColors.ink.withValues(alpha: 0),
      pageBuilder: (ctx, _, _) => MatchCelebrationOverlay(
        match: mwp,
        currentUserPhotoUrl: _currentProfile?.photoUrls.isNotEmpty == true
            ? _currentProfile!.photoUrls.first
            : '',
        onKeepSwiping: () {
          markSeen();
          Navigator.pop(ctx);
        },
        onChat: () {
          markSeen();
          Navigator.pop(ctx);
          _openChat(mwp);
        },
      ),
    );
  }

  void _openChat(MatchWithProfile mwp) {
    final uid = _currentUid;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          matchId: mwp.match.matchId,
          otherProfile: mwp.otherProfile,
          currentUid: uid,
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

  Future<void> _confirmUnmatch(MatchWithProfile mwp) async {
    final uid = _currentUid;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('매칭을 해제할까요?'),
        content: const Text('해제하면 서로의 매칭 목록에서 사라지고 더 이상 대화할 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.surface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.matchesService.unmatch(matchId: mwp.match.matchId, uid: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('매칭을 해제했어요.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('매칭 해제에 실패했어요. 잠시 후 다시 시도해주세요.')),
          );
      }
    }
  }

  void _openProfile(PublicProfile profile) {
    final uid = _currentUid;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          currentUid: uid,
          initialProfile: profile,
          currentLocation: _currentProfile?.location,
          firestoreService: widget.firestoreService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  void _openReceivedLikes() {
    final uid = _currentUid;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReceivedLikesScreen(
          currentUid: uid,
          currentProfile: _currentProfile,
          firestoreService: widget.firestoreService,
          likesService: widget.likesService,
          discoveryService: widget.discoveryService,
          matchesService: widget.matchesService,
          chatService: widget.chatService,
          presenceService: widget.presenceService,
          appointmentSafetyService: widget.appointmentSafetyService,
          fortuneService: widget.fortuneService,
          jellyService: widget.jellyService,
          jellyPurchaseService: widget.jellyPurchaseService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_stream == null || _likesStream == null) {
      return const Scaffold(body: Center(child: Text('로그인이 필요합니다.')));
    }

    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        title: const Text('매칭', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: AppColors.warmCanvas,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: StreamBuilder<List<MatchWithProfile>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const _MatchesLoading();
          }
          if (snap.hasError) {
            if (kDebugMode) debugPrint('[Matches] 매칭 목록 로드 실패: ${snap.error}');
            return const _MatchesError();
          }
          final matches = snap.data ?? [];
          // 신규/대화 분리는 기존 계약(lastMessage == null == "새 매칭")을 그대로
          // 재사용한다. 스트림 정렬(matchedAt desc)은 각 그룹 안에서 유지된다.
          final newMatches = <MatchWithProfile>[];
          final conversations = <MatchWithProfile>[];
          for (final mwp in matches) {
            if (mwp.match.lastMessage == null) {
              newMatches.add(mwp);
            } else {
              conversations.add(mwp);
            }
          }

          return ListView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xl + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              const AppFadeSlideIn(child: _MatchesHeader()),
              const SizedBox(height: AppSpacing.lg),
              _ReceivedLikesEntry(
                stream: _likesStream!,
                onTap: _openReceivedLikes,
              ),
              if (newMatches.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xl),
                const _SectionLabel('새로운 매칭'),
                const SizedBox(height: AppSpacing.md),
                _NewMatchesRail(matches: newMatches, onTap: _openChat),
              ],
              const SizedBox(height: AppSpacing.xl),
              const _SectionLabel('이어지는 대화'),
              const SizedBox(height: AppSpacing.md),
              if (conversations.isEmpty)
                _ConversationsEmpty(hasNewMatches: newMatches.isNotEmpty)
              else
                ...conversations.map(
                  (mwp) => _MatchTile(
                    mwp: mwp,
                    currentUid: _currentUid!,
                    onProfileTap: () => _openProfile(mwp.otherProfile),
                    onChatTap: () => _openChat(mwp),
                    onUnmatchRequested: () => _confirmUnmatch(mwp),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ═══ A. Editorial 헤더 ════════════════════════════════════════════════════════

class _MatchesHeader extends StatelessWidget {
  const _MatchesHeader();

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
          stops: [0.1, 0.62, 1],
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
                child: ConnectionMotif(strokeWidth: 1.6, opacity: 0.7),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '나의 인연',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.brandPrimaryStrong,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text('이어진 인연을 확인해요', style: AppTextStyles.screenTitle),
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                '서로 연결된 사람과 대화를 시작하고 이어가보세요.',
                style: AppTextStyles.bodySecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══ 섹션 라벨 ════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

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

// ═══ B. 받은 좋아요 진입 ══════════════════════════════════════════════════════

class _ReceivedLikesEntry extends StatelessWidget {
  final Stream<List<ReceivedLike>> stream;
  final VoidCallback onTap;

  const _ReceivedLikesEntry({required this.stream, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ReceivedLike>>(
      stream: stream,
      builder: (context, snap) {
        final count = snap.data?.length ?? 0;
        return AppSurfaceCard(
          padding: const EdgeInsets.all(16),
          onTap: onTap,
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  color: AppColors.expressiveAccentSoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.favorite_rounded,
                  size: 22,
                  color: AppColors.expressiveAccent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0 ? '받은 좋아요' : '받은 좋아요 $count',
                      style: AppTextStyles.cardTitle,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      count == 0 ? '아직 응답할 좋아요가 없어요' : '나를 좋아요한 사람에게 바로 응답해요',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.brandPrimary,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══ C. 새로운 매칭 rail (아직 대화 전) ════════════════════════════════════════

class _NewMatchesRail extends StatelessWidget {
  final List<MatchWithProfile> matches;
  final void Function(MatchWithProfile) onTap;

  const _NewMatchesRail({required this.matches, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: matches.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
        itemBuilder: (context, index) {
          final mwp = matches[index];
          return _NewMatchPortrait(
            profile: mwp.otherProfile,
            onTap: () => onTap(mwp),
          );
        },
      ),
    );
  }
}

class _NewMatchPortrait extends StatelessWidget {
  final PublicProfile profile;
  final VoidCallback onTap;

  const _NewMatchPortrait({required this.profile, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final photoUrl = profile.photoUrls.isNotEmpty ? profile.photoUrls[0] : null;
    return AppPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(40),
      child: SizedBox(
        width: 84,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(2.5),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.expressiveAccent, AppColors.brandPrimary],
                ),
              ),
              child: _CircleAvatar(photoUrl: photoUrl, size: 72),
            ),
            const SizedBox(height: 8),
            Text(
              profile.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppTextStyles.label.copyWith(color: AppColors.textStrong),
            ),
            Text(
              '대화 시작',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.brandPrimaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══ D. 이어지는 대화 ═════════════════════════════════════════════════════════

class _ConversationsEmpty extends StatelessWidget {
  final bool hasNewMatches;
  const _ConversationsEmpty({required this.hasNewMatches});

  @override
  Widget build(BuildContext context) {
    // 새 매칭은 있는데 아직 대화가 없을 때와, 매칭이 아예 없을 때를 구분해
    // 각 상황에 맞는 안내를 보여준다. 어느 쪽도 오류처럼 보이지 않게 한다.
    final title = hasNewMatches ? '아직 나눈 대화가 없어요' : '아직 매칭이 없어요';
    final message = hasNewMatches
        ? '위의 새로운 매칭에게 먼저\n인사를 건네보세요!'
        : '둘러보기에서 마음에 드는 분께\nLike를 보내보세요!';
    return AppSurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
      child: Column(
        children: [
          const SizedBox(
            width: 72,
            height: 44,
            child: ExcludeSemantics(
              child: IgnorePointer(child: ConnectionMotif(opacity: 0.85)),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            title,
            style: AppTextStyles.cardTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySecondary,
          ),
        ],
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  final MatchWithProfile mwp;
  final String currentUid;
  final VoidCallback onProfileTap;
  final VoidCallback onChatTap;
  final VoidCallback onUnmatchRequested;
  const _MatchTile({
    required this.mwp,
    required this.currentUid,
    required this.onProfileTap,
    required this.onChatTap,
    required this.onUnmatchRequested,
  });

  @override
  Widget build(BuildContext context) {
    final profile = mwp.otherProfile;
    final photoUrl = profile.photoUrls.isNotEmpty ? profile.photoUrls[0] : null;
    final lastMessage = mwp.match.lastMessage;
    final hasUnread = _hasUnread(mwp, currentUid);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppSurfaceCard(
        padding: const EdgeInsets.all(14),
        onTap: onChatTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Semantics(
              button: true,
              label: '${profile.displayName} 프로필 보기',
              child: GestureDetector(
                onTap: onProfileTap,
                child: _CircleAvatar(photoUrl: photoUrl, size: 58),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${profile.displayName}, ${profile.age}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.cardTitle.copyWith(
                            fontWeight: hasUnread
                                ? FontWeight.w800
                                : FontWeight.w700,
                          ),
                        ),
                      ),
                      if (lastMessage != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          _formatLastMessageTime(lastMessage.createdAt),
                          style: AppTextStyles.caption,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _subtitle(mwp),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: hasUnread
                              ? AppTextStyles.bodySecondary.copyWith(
                                  color: AppColors.textStrong,
                                  fontWeight: FontWeight.w700,
                                )
                              : AppTextStyles.bodySecondary,
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        const _UnreadDot(),
                      ],
                    ],
                  ),
                  if (profile.verifications.hasAny) ...[
                    const SizedBox(height: 8),
                    VerificationBadges(verifications: profile.verifications),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// lastMessage가 있으면 마지막 메시지 미리보기를, 없으면 매칭 안내 문구를 보여준다.
  static String _subtitle(MatchWithProfile mwp) {
    final last = mwp.match.lastMessage;
    if (last == null) return '매칭됐어요! 대화를 시작해보세요';
    return last.text;
  }

  static bool _hasUnread(MatchWithProfile mwp, String currentUid) {
    final last = mwp.match.lastMessage;
    if (last == null || last.senderId == currentUid) return false;

    final lastReadAt = mwp.match.lastReadAtFor(currentUid);
    if (lastReadAt == null) return true;
    return last.createdAt.isAfter(lastReadAt);
  }
}

String _formatLastMessageTime(DateTime value) {
  final createdAt = value.toLocal();
  final now = DateTime.now();
  final diff = now.difference(createdAt);

  if (!diff.isNegative && diff < const Duration(minutes: 1)) {
    return '방금 전';
  }
  if (!diff.isNegative && diff < const Duration(hours: 1)) {
    return '${diff.inMinutes}분 전';
  }

  final today = DateTime(now.year, now.month, now.day);
  final messageDay = DateTime(createdAt.year, createdAt.month, createdAt.day);
  if (today == messageDay) {
    final period = createdAt.hour < 12 ? '오전' : '오후';
    final hour = createdAt.hour % 12 == 0 ? 12 : createdAt.hour % 12;
    final minute = createdAt.minute.toString().padLeft(2, '0');
    return '$period $hour:$minute';
  }

  final yesterday = today.subtract(const Duration(days: 1));
  if (messageDay == yesterday) return '어제';
  return '${createdAt.month}/${createdAt.day}';
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '읽지 않은 메시지',
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: AppColors.brandPrimary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 프로필 원형 썸네일. 사진 실패/누락 시 안전한 placeholder로 대체하고
/// 네트워크 실패 이유는 화면에 노출하지 않는다.
class _CircleAvatar extends StatelessWidget {
  final String? photoUrl;
  final double size;
  const _CircleAvatar({required this.photoUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    return Semantics(
      image: true,
      label: '프로필 사진',
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: AppColors.canvasSubtle,
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: url == null
            ? _avatarFallback(size)
            : Image.network(
                url,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const ColoredBox(color: AppColors.canvasSubtle);
                },
                errorBuilder: (_, _, _) => _avatarFallback(size),
              ),
      ),
    );
  }

  Widget _avatarFallback(double size) {
    return Center(
      child: Icon(
        Icons.person_rounded,
        size: size * 0.5,
        color: AppColors.textMuted,
      ),
    );
  }
}

// ═══ Loading / Error ══════════════════════════════════════════════════════════

class _MatchesLoading extends StatelessWidget {
  const _MatchesLoading();

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
          height: 128,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.heroSoft),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          height: 78,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.surface),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        for (var i = 0; i < 3; i++) ...[
          Container(
            height: 88,
            decoration: BoxDecoration(
              color: AppColors.surfaceSecondary,
              borderRadius: BorderRadius.circular(AppRadius.surface),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        const SizedBox(height: AppSpacing.md),
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

class _MatchesError extends StatelessWidget {
  const _MatchesError();

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
            Text(
              '매칭 목록을 불러오지 못했어요.\n잠시 후 다시 시도해주세요.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary,
            ),
          ],
        ),
      ),
    );
  }
}
