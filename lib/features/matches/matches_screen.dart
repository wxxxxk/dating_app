import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/match_model.dart';
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
import '../chat/chat_screen.dart';
import '../fortune/fortune_route_names.dart';
import '../fortune/match_fortune_screen.dart';
import '../likes/received_likes_screen.dart';
import '../profile/user_profile_screen.dart';
import '../profile/widgets/verification_badge.dart';

/// 매칭 목록 화면 (하단 탭 1번).
///
/// matches 컬렉션을 실시간 구독하고 각 매치 상대방의 프로필과 함께 표시한다.
/// 궁합/채팅 버튼을 분리해 의도한 화면만 네비게이션 스택에 쌓이게 한다.
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

  @override
  void initState() {
    super.initState();
    final uid = widget.authService.currentUser?.uid;
    if (uid != null) {
      _currentUid = uid;
      _stream = widget.matchesService.watchMatches(currentUid: uid);
      _likesStream = widget.likesService.watchReceivedLikes(currentUid: uid);
      _loadCurrentProfile(uid);
    }
  }

  Future<void> _loadCurrentProfile(String uid) async {
    final profile = await widget.firestoreService.getUserProfile(uid);
    if (mounted) setState(() => _currentProfile = profile);
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
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  void _openFortune(MatchWithProfile mwp) {
    final uid = _currentUid;
    if (uid == null) return;
    // 루트 위에 남은 사주 상세 라우트를 정리한 뒤 궁합만 올린다.
    // 뒤로가기 전환 중 내 사주 화면이 잠깐 보이는 스택을 방지한다.
    Navigator.of(context).pushAndRemoveUntil<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: FortuneRouteNames.match),
        builder: (_) => MatchFortuneScreen(
          matchId: mwp.match.matchId,
          currentUid: uid,
          otherProfile: mwp.otherProfile,
          firestoreService: widget.firestoreService,
          fortuneService: widget.fortuneService,
        ),
      ),
      (route) => route.isFirst,
    );
  }

  void _openProfile(UserProfile profile) {
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                ...matches.map(
                  (mwp) => _MatchTile(
                    mwp: mwp,
                    currentUid: _currentUid!,
                    onProfileTap: () => _openProfile(mwp.otherProfile),
                    onChatTap: () => _openChat(mwp),
                    onFortuneTap: () => _openFortune(mwp),
                  ),
                ),
            ],
          );
        },
      ),
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
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.14),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: AppColors.primary,
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
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
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
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Text(
        '아직 매칭이 없어요\n둘러보기에서 마음에 드는 분께 Like를 보내보세요!',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 14,
          color: AppColors.textSecondary,
          height: 1.6,
        ),
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  final MatchWithProfile mwp;
  final String currentUid;
  final VoidCallback onProfileTap;
  final VoidCallback onChatTap;
  final VoidCallback onFortuneTap;
  const _MatchTile({
    required this.mwp,
    required this.currentUid,
    required this.onProfileTap,
    required this.onChatTap,
    required this.onFortuneTap,
  });

  @override
  Widget build(BuildContext context) {
    final profile = mwp.otherProfile;
    final photoUrl = profile.photoUrls.isNotEmpty ? profile.photoUrls[0] : null;
    final lastMessage = mwp.match.lastMessage;
    final hasUnread = _hasUnread(mwp, currentUid);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      color: AppColors.surface,
      child: ListTile(
        onTap: onProfileTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
        leading: _Avatar(photoUrl: photoUrl),
        title: Text(
          '${profile.displayName}, ${profile.age}',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _subtitle(mwp),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            if (profile.verifications.hasAny) ...[
              const SizedBox(height: 5),
              VerificationBadges(verifications: profile.verifications),
            ],
          ],
        ),
        isThreeLine: profile.verifications.hasAny,
        titleAlignment: ListTileTitleAlignment.center,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (lastMessage != null) ...[
              _MessageMeta(
                createdAt: lastMessage.createdAt,
                hasUnread: hasUnread,
              ),
              const SizedBox(width: 4),
            ],
            IconButton(
              icon: const Icon(
                Icons.auto_awesome_rounded,
                color: AppColors.secondary,
              ),
              tooltip: '궁합 보기',
              onPressed: onFortuneTap,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(
                Icons.chat_bubble_outline_rounded,
                color: AppColors.primary,
              ),
              tooltip: '채팅 열기',
              onPressed: onChatTap,
              visualDensity: VisualDensity.compact,
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
          color: Colors.white,
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
    return CircleAvatar(
      radius: 30,
      backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
      backgroundColor: AppColors.border,
      child: photoUrl == null
          ? const Icon(Icons.person, color: AppColors.textSecondary)
          : null,
    );
  }
}
