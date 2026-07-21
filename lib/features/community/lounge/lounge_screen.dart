import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_enums.dart';
import '../../../models/community/community_post.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import 'lounge_compose_sheet.dart';
import 'lounge_post_detail_screen.dart';
import 'lounge_widgets.dart';

/// 라운지 화면(Phase 4-2) — 커뮤니티 홈에서 push되는 독립 화면.
///
/// 게시물 목록을 보여주고 글쓰기·상세 진입을 담당한다. 차단·지인 피하기
/// 상대의 글은 표시만 건너뛴다(문서·카운트는 건드리지 않는다).
class LoungeScreen extends StatefulWidget {
  final AuthService authService;
  final CommunityService communityService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const LoungeScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<LoungeScreen> createState() => _LoungeScreenState();
}

class _LoungeScreenState extends State<LoungeScreen> {
  /// build()에서 만들면 setState마다 재구독되므로 화면 수명 동안 하나만 둔다.
  late final Stream<List<CommunityPost>> _postsStream = widget.communityService
      .watchPosts(surface: CommunityPostSurface.lounge);

  late final CommunityAudienceFilter _audience = CommunityAudienceFilter(
    safetyService: widget.safetyService,
    contactAvoidanceService: widget.contactAvoidanceService,
  );

  /// 같은 요청이 두 번 나가지 않게 하는 진행 중 표시.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _audience.start(
      uid: _currentUid,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _audience.dispose();
    super.dispose();
  }

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openCompose() async {
    if (_busy) return;
    _busy = true;
    try {
      final created = await showLoungeComposeSheet(
        context,
        communityService: widget.communityService,
      );
      // 새 글은 stream이 곧바로 반영하므로 목록을 따로 다시 읽지 않는다.
      if (created) _showMessage('글을 올렸어요.');
    } finally {
      _busy = false;
    }
  }

  void _openDetail(CommunityPost post) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoungePostDetailScreen(
          postId: post.id,
          authService: widget.authService,
          communityService: widget.communityService,
          safetyService: widget.safetyService,
          contactAvoidanceService: widget.contactAvoidanceService,
        ),
      ),
    );
  }

  Future<void> _deletePost(CommunityPost post) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('글을 삭제할까요?'),
        content: const Text('삭제하면 라운지에서 바로 사라져요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제하기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _busy = true;
    try {
      await widget.communityService.deletePost(postId: post.id);
      _showMessage('글을 삭제했어요.');
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      _busy = false;
    }
  }

  Future<void> _reportPost(CommunityPost post) async {
    final uid = _currentUid;
    if (uid == null || _busy) return;
    _busy = true;
    try {
      final outcome = await showCommunityReportSheet(
        context,
        communityService: widget.communityService,
        safetyService: widget.safetyService,
        currentUid: uid,
        targetType: 'post',
        postId: post.id,
        reportedUid: post.authorUid,
      );
      if (outcome == null || !mounted) return;
      if (outcome.blocked) {
        await _audience.refreshBlocked(
          uid: uid,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
      }
      _showMessage(outcome.blocked ? '신고하고 차단했어요.' : '신고를 접수했어요.');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid;
    return Scaffold(
      key: const ValueKey('lounge-screen'),
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('라운지'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('lounge-create-post-button'),
        onPressed: _openCompose,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('글쓰기'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: _LoungeSafetyNotice(),
            ),
            Expanded(
              child: StreamBuilder<List<CommunityPost>>(
                stream: _postsStream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const _LoungeError();
                  }
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const Center(
                      key: ValueKey('lounge-loading'),
                      child: CircularProgressIndicator(),
                    );
                  }

                  final posts = (snap.data ?? const <CommunityPost>[])
                      .where(
                        (post) => !_audience.isExcluded(
                          authorUid: post.authorUid,
                          selfUid: uid,
                        ),
                      )
                      .toList();

                  if (posts.isEmpty) return const _LoungeEmpty();

                  return ListView.separated(
                    key: const ValueKey('lounge-post-list'),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                    itemCount: posts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, index) {
                      final post = posts[index];
                      return _LoungePostCard(
                        post: post,
                        isMine: uid != null && post.authorUid == uid,
                        onTap: () => _openDetail(post),
                        onDelete: () => _deletePost(post),
                        onReport: () => _reportPost(post),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoungeSafetyNotice extends StatelessWidget {
  const _LoungeSafetyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 17, color: AppColors.mintDeep),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '가벼운 이야기부터 시작해보세요.\n개인정보·연락처·인증번호·금전 정보는 공개하지 마세요.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoungeEmpty extends StatelessWidget {
  const _LoungeEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: ValueKey('lounge-empty'),
      padding: EdgeInsets.fromLTRB(20, 32, 20, 20),
      child: Text(
        '아직 올라온 이야기가 없어요.\n첫 이야기를 남겨보세요.',
        style: TextStyle(
          fontSize: 13.5,
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
      key: const ValueKey('lounge-error'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '라운지 이야기를 불러오지 못했어요.',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('lounge-retry'),
            // 같은 stream을 계속 구독하므로 재빌드로 다시 그리게만 한다.
            onPressed: () => setState(() {}),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}

/// 목록용 게시물 카드. 공감 toggle은 상세 화면에서 제공한다(목록에서는 카운트만).
class _LoungePostCard extends StatelessWidget {
  final CommunityPost post;
  final bool isMine;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _LoungePostCard({
    required this.post,
    required this.isMine,
    required this.onTap,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey('lounge-post-${post.id}'),
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommunityAuthorHeader(
                author: post.author,
                createdAt: post.createdAt,
                trailing: _PostMenu(
                  postId: post.id,
                  isMine: isMine,
                  onDelete: onDelete,
                  onReport: onReport,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                post.text,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              CommunityCountRow(
                reactionCount: post.reactionCount,
                commentCount: post.commentCount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PostMenu extends StatelessWidget {
  final String postId;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _PostMenu({
    required this.postId,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: PopupMenuButton<String>(
        key: ValueKey('lounge-post-menu-$postId'),
        padding: EdgeInsets.zero,
        icon: const Icon(
          Icons.more_horiz_rounded,
          size: 18,
          color: AppColors.textSecondary,
        ),
        onSelected: (value) {
          if (value == 'delete') {
            onDelete();
          } else if (value == 'report') {
            onReport();
          }
        },
        itemBuilder: (_) => [
          if (isMine)
            const PopupMenuItem(value: 'delete', child: Text('삭제하기'))
          else
            const PopupMenuItem(value: 'report', child: Text('신고하기')),
        ],
      ),
    );
  }
}
