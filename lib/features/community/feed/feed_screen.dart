import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_enums.dart';
import '../../../models/community/community_post.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_media_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import 'feed_compose_screen.dart';
import 'feed_post_detail_screen.dart';
import 'feed_widgets.dart';

/// 피드 화면(Phase 4-3) — 커뮤니티 홈에서 push되는 독립 화면.
///
/// 사진 게시물 목록을 보여주고 작성·상세 진입을 담당한다. 차단·지인 피하기
/// 상대의 글은 표시만 건너뛴다(문서·카운트는 건드리지 않는다).
class FeedScreen extends StatefulWidget {
  final AuthService authService;
  final CommunityService communityService;
  final CommunityMediaService mediaService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const FeedScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.mediaService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  /// build()에서 만들면 setState마다 재구독되므로 화면 수명 동안 하나만 둔다.
  late final Stream<List<CommunityPost>> _postsStream = widget.communityService
      .watchPosts(surface: CommunityPostSurface.feed);

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
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => FeedComposeScreen(
            authService: widget.authService,
            communityService: widget.communityService,
            mediaService: widget.mediaService,
          ),
        ),
      );
      // 새 글은 stream이 곧바로 반영하므로 목록을 따로 다시 읽지 않는다.
      if (created == true) _showMessage('피드에 올렸어요.');
    } finally {
      _busy = false;
    }
  }

  void _openDetail(CommunityPost post) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FeedPostDetailScreen(
          postId: post.id,
          authService: widget.authService,
          communityService: widget.communityService,
          mediaService: widget.mediaService,
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
        title: const Text('게시물을 삭제할까요?'),
        content: const Text('삭제하면 사진도 함께 지워지고 다시 되돌릴 수 없어요.'),
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
      // 서버가 실제 파일을 지웠으므로 남은 bytes 캐시도 버린다.
      evictFeedImageCache(post.imagePaths);
      _showMessage('게시물을 삭제했어요.');
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
      key: const ValueKey('feed-screen'),
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('피드'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('feed-create-post-button'),
        onPressed: _openCompose,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('피드 올리기'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: _FeedSafetyNotice(),
            ),
            Expanded(
              child: StreamBuilder<List<CommunityPost>>(
                stream: _postsStream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const _FeedError();
                  }
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const Center(
                      key: ValueKey('feed-loading'),
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

                  if (posts.isEmpty) return const _FeedEmpty();

                  return ListView.separated(
                    key: const ValueKey('feed-post-list'),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                    itemCount: posts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, index) {
                      final post = posts[index];
                      return FeedPostCard(
                        post: post,
                        mediaService: widget.mediaService,
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

class _FeedSafetyNotice extends StatelessWidget {
  const _FeedSafetyNotice();

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
              '일상과 취향을 사진으로 나눠보세요.\n'
              '사진에 연락처·신분증·인증번호·금융정보가 보이지 않는지 확인해주세요.',
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

class _FeedEmpty extends StatelessWidget {
  const _FeedEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: ValueKey('feed-empty'),
      padding: EdgeInsets.fromLTRB(20, 32, 20, 20),
      child: Text(
        '아직 올라온 사진이 없어요.\n첫 사진을 남겨보세요.',
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
class _FeedError extends StatefulWidget {
  const _FeedError();

  @override
  State<_FeedError> createState() => _FeedErrorState();
}

class _FeedErrorState extends State<_FeedError> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('feed-error'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '피드를 불러오지 못했어요.',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('feed-retry'),
            // 같은 stream을 계속 구독하므로 재빌드로 다시 그리게만 한다.
            onPressed: () => setState(() {}),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}
