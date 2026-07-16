import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/match_model.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/likes/likes_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/premium_components.dart';
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
/// StatefulWidget인 이유:
///   initState에서 _stream을 한 번만 생성해 재사용한다.
///   StatelessWidget이면 build() 호출마다 watchMatches()가 새 Stream 객체를
///   반환해, StreamBuilder가 구독을 취소·재연결하는 낭비가 반복된다.
class MatchesScreen extends StatefulWidget {
  final AuthService authService;
  final MatchesService matchesService;
  final ChatService chatService;
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('매칭', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: StreamBuilder<List<MatchWithProfile>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                '불러오기 실패: ${snap.error}',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            );
          }
          final matches = snap.data ?? [];
          return ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              24 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              _ReceivedLikesEntry(
                stream: _likesStream!,
                onTap: _openReceivedLikes,
              ),
              const SizedBox(height: 18),
              const _SectionTitle(title: '매칭된 사람'),
              const SizedBox(height: 10),
              if (matches.isEmpty)
                const _EmptyMatchesInline()
              else
                ...matches.asMap().entries.map(
                  (entry) => _StaggeredMatchTile(
                    index: entry.key,
                    child: _MatchTile(
                      mwp: entry.value,
                      currentUid: _currentUid!,
                      onProfileTap: () =>
                          _openProfile(entry.value.otherProfile),
                      onChatTap: () => _openChat(entry.value),
                      onUnmatchRequested: () => _confirmUnmatch(entry.value),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StaggeredMatchTile extends StatefulWidget {
  final int index;
  final Widget child;

  const _StaggeredMatchTile({required this.index, required this.child});

  @override
  State<_StaggeredMatchTile> createState() => _StaggeredMatchTileState();
}

class _StaggeredMatchTileState extends State<_StaggeredMatchTile> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(AppDurations.staggerDelay(widget.index), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: _visible ? 1 : 0),
      duration: AppDurations.fast,
      curve: AppCurves.standard,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

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
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.mint.withValues(alpha: 0.22)),
              boxShadow: AppShadows.card,
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.mint.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: AppColors.mint,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '받은 좋아요 $count',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        count == 0 ? '아직 응답할 좋아요가 없어요' : '나를 좋아요한 사람에게 바로 응답해요',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.mint),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _EmptyMatchesInline extends StatelessWidget {
  const _EmptyMatchesInline();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.favorite_border_rounded,
            size: 40,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: 14),
          const Text(
            '아직 매칭이 없어요',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '둘러보기에서 마음에 드는 분께\nLike를 보내보세요!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.55,
            ),
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
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onProfileTap,
          onLongPress: onUnmatchRequested,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.border),
              boxShadow: AppShadows.card,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Avatar(photoUrl: photoUrl),
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
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                              ),
                            ),
                          ),
                          if (hasUnread || lastMessage == null) ...[
                            const SizedBox(width: 6),
                            PremiumStatusPill(
                              label: hasUnread ? '읽지 않음' : '새 매칭',
                              compact: true,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _subtitle(mwp),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: hasUnread
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                                fontWeight: hasUnread
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (lastMessage != null)
                            _MessageMeta(
                              createdAt: lastMessage.createdAt,
                              hasUnread: hasUnread,
                            ),
                        ],
                      ),
                      if (profile.verifications.hasAny) ...[
                        const SizedBox(height: 7),
                        VerificationBadges(
                          verifications: profile.verifications,
                        ),
                      ],
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: onChatTap,
                          icon: const Icon(Icons.chat_bubble_rounded, size: 16),
                          label: const Text(
                            '대화',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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

class _MessageMeta extends StatelessWidget {
  final DateTime createdAt;
  final bool hasUnread;

  const _MessageMeta({required this.createdAt, required this.hasUnread});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatLastMessageTime(createdAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          if (hasUnread) ...[const SizedBox(height: 6), const _UnreadBadge()],
        ],
      ),
    );
  }

  static String _formatLastMessageTime(DateTime value) {
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
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.error,
        shape: BoxShape.circle,
      ),
      child: const Text(
        '1',
        style: TextStyle(
          color: AppColors.surface,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? photoUrl;
  const _Avatar({required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    return PremiumProfileImageCard(
      radius: AppRadius.button,
      child: SizedBox(
        width: 82,
        height: 108,
        child: photoUrl == null
            ? const ColoredBox(
                color: AppColors.surface,
                child: Icon(
                  Icons.person_rounded,
                  color: AppColors.textSecondary,
                ),
              )
            : Image.network(photoUrl!, fit: BoxFit.cover),
      ),
    );
  }
}
