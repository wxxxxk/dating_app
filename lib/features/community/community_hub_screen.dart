import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/community/community_enums.dart';
import '../../models/community/community_post.dart';
import '../../services/auth/auth_service.dart';
import '../../services/community/community_service.dart';
import '../../services/privacy/contact_avoidance_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/premium_components.dart';

/// 커뮤니티 홈(Phase 4-1) — 읽기 전용.
///
/// 네 목적지를 소개하고, 그중 라운지만 실제 Firestore 게시물을 보여준다.
/// 작성·댓글·좋아요는 아직 열지 않았고 더미 콘텐츠도 만들지 않는다.
class CommunityHubScreen extends StatefulWidget {
  final AuthService authService;
  final CommunityService communityService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const CommunityHubScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<CommunityHubScreen> createState() => _CommunityHubScreenState();
}

class _CommunityHubScreenState extends State<CommunityHubScreen> {
  /// build()에서 만들면 setState마다 재구독되므로 화면 수명 동안 하나만 둔다.
  late final Stream<List<CommunityPost>> _loungeStream = widget.communityService
      .watchPosts(surface: CommunityPostSurface.lounge);

  final _loungeSectionKey = GlobalKey();

  StreamSubscription<Set<String>>? _avoidedUidsSub;

  /// 두 관계를 따로 들고 union으로 쓴다 — 한쪽이 풀리면 그 작성자만 다시
  /// 보이게 하기 위해서다. 게시물 문서나 카운트는 건드리지 않는다.
  Set<String> _blockedUids = {};
  Set<String> _avoidedUids = {};

  Set<String> get _excludedAuthorUids => {..._blockedUids, ..._avoidedUids};

  @override
  void initState() {
    super.initState();
    _loadBlockedUids();
    _watchAvoidedUids();
  }

  @override
  void dispose() {
    _avoidedUidsSub?.cancel();
    super.dispose();
  }

  String? get _currentUid => widget.authService.currentUser?.uid;

  Future<void> _loadBlockedUids() async {
    final uid = _currentUid;
    if (uid == null) return;
    try {
      final blocked = await widget.safetyService.getBlockedRelationshipUids(uid);
      if (!mounted || setEquals(blocked, _blockedUids)) return;
      setState(() => _blockedUids = blocked);
    } catch (e) {
      // 관계 조회 실패가 커뮤니티 전체를 막지 않는다.
      _debugLog('[Community] 차단 목록 조회 실패 code=${e.runtimeType}');
    }
  }

  void _watchAvoidedUids() {
    final uid = _currentUid;
    if (uid == null) return;
    _avoidedUidsSub = widget.contactAvoidanceService
        .watchAvoidedUids(uid)
        .listen(
          (avoided) {
            if (!mounted) return;
            // 같은 집합이면 불필요한 rebuild를 하지 않는다.
            if (setEquals(avoided, _avoidedUids)) return;
            setState(() => _avoidedUids = avoided);
          },
          onError: (Object e) {
            // 구독 오류가 커뮤니티 화면을 영구 종료시키지 않는다.
            _debugLog('[Community] 지인 피하기 구독 실패 code=${e.runtimeType}');
          },
        );
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }

  void _showComingSoon(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToLounge() {
    final context = _loungeSectionKey.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
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
                statusLabel: '게시물 읽기 가능',
                available: true,
                onTap: _scrollToLounge,
              ),
              const SizedBox(height: 10),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-feed'),
                icon: Icons.photo_library_outlined,
                title: '피드',
                description: '일상과 취향을 사진과 함께 나눠요',
                statusLabel: '준비 중',
                available: false,
                onTap: () => _showComingSoon('피드는 다음 단계에서 열릴 예정이에요.'),
              ),
              const SizedBox(height: 10),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-party-square'),
                icon: Icons.celebration_outlined,
                title: '파티·스퀘어',
                description: '관심사 모임과 공개 이벤트를 찾아봐요',
                statusLabel: '준비 중',
                available: false,
                onTap: () => _showComingSoon('파티·스퀘어는 다음 단계에서 열릴 예정이에요.'),
              ),
              const SizedBox(height: 10),
              _DestinationCard(
                cardKey: const ValueKey('community-destination-group-chat'),
                icon: Icons.groups_outlined,
                title: '그룹 채팅',
                description: '관심사가 맞는 사람들과 소규모로 대화해요',
                statusLabel: '준비 중',
                available: false,
                onTap: () => _showComingSoon('그룹 채팅은 다음 단계에서 열릴 예정이에요.'),
              ),
              const SizedBox(height: 24),
              _LoungeSection(
                key: _loungeSectionKey,
                stream: _loungeStream,
                excludedAuthorUids: _excludedAuthorUids,
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

/// 읽기 전용 라운지 목록. 작성 버튼을 두지 않는다.
class _LoungeSection extends StatelessWidget {
  final Stream<List<CommunityPost>> stream;
  final Set<String> excludedAuthorUids;

  const _LoungeSection({
    super.key,
    required this.stream,
    required this.excludedAuthorUids,
  });

  @override
  Widget build(BuildContext context) {
    return PremiumSectionCard(
      title: '라운지',
      child: StreamBuilder<List<CommunityPost>>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return const _LoungeError();
          }
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          // 차단·지인 피하기 상대의 글은 목록에서만 제외한다.
          final posts = (snap.data ?? const <CommunityPost>[])
              .where((post) => !excludedAuthorUids.contains(post.authorUid))
              .toList();

          if (posts.isEmpty) return const _LoungeEmpty();

          return Column(
            key: const ValueKey('community-lounge-list'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final post in posts) ...[
                _PostCard(post: post),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _LoungeEmpty extends StatelessWidget {
  const _LoungeEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: ValueKey('community-lounge-empty'),
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Text(
        '아직 올라온 이야기가 없어요.\n라운지가 열리면 이곳에서 새로운 대화를 만날 수 있어요.',
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// raw Firestore 오류는 노출하지 않고 고정 문구만 보여준다.
class _LoungeError extends StatefulWidget {
  const _LoungeError();

  @override
  State<_LoungeError> createState() => _LoungeErrorState();
}

class _LoungeErrorState extends State<_LoungeError> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('community-lounge-error'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '라운지 이야기를 불러오지 못했어요.',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('community-lounge-retry'),
            // StreamBuilder는 같은 stream을 계속 구독하므로 재빌드로 다시
            // 그리게만 한다(새 구독을 만들어 누수를 만들지 않는다).
            onPressed: () => setState(() {}),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}

/// 읽기 전용 게시물 카드. 수정·삭제·댓글·좋아요 버튼을 두지 않는다.
class _PostCard extends StatelessWidget {
  final CommunityPost post;

  const _PostCard({required this.post});

  @override
  Widget build(BuildContext context) {
    final author = post.author;
    return Container(
      key: ValueKey('community-post-${post.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.border,
                backgroundImage: author.photoUrl.isNotEmpty
                    ? NetworkImage(author.photoUrl)
                    : null,
                child: author.photoUrl.isEmpty
                    ? const Icon(
                        Icons.person_rounded,
                        size: 16,
                        color: AppColors.textSecondary,
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      author.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (author.hasAnyBadge) ...[
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          if (author.photoVerified)
                            const _AuthorBadge(label: '사진 인증'),
                          if (author.workVerified)
                            const _AuthorBadge(label: '직장 인증'),
                          if (author.schoolVerified)
                            const _AuthorBadge(label: '학교 인증'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                _formatCreatedAt(post.createdAt),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            post.text,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textPrimary,
            ),
          ),
          if (post.imageUrls.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.button),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.network(
                  post.imageUrls.first,
                  fit: BoxFit.cover,
                  // 로딩 실패 시 내부 경로를 노출하지 않는 안전한 placeholder.
                  errorBuilder: (_, _, _) => Container(
                    color: AppColors.background,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.image_not_supported_outlined,
                      size: 22,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.favorite_border_rounded,
                size: 15,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '${post.reactionCount}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              const Icon(
                Icons.mode_comment_outlined,
                size: 15,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '${post.commentCount}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatCreatedAt(DateTime? value) {
    if (value == null) return '';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$month.$day';
  }
}

class _AuthorBadge extends StatelessWidget {
  final String label;

  const _AuthorBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: AppColors.mintDeep,
        ),
      ),
    );
  }
}
