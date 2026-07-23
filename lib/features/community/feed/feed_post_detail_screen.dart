import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_comment.dart';
import '../../../models/community/community_post.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_media_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_audience_filter.dart';
import '../community_comment_widgets.dart';
import '../community_report_sheet.dart';
import '../community_text_guard.dart';
import '../lounge/lounge_widgets.dart';
import 'feed_widgets.dart';

/// 피드 게시물 상세(Phase 4-3).
///
/// 이미지 1~4장 + 본문 + 공감 + 댓글 목록/작성 + 신고·삭제를 담당한다.
/// 게시물이 삭제/숨김되거나 작성자와의 관계가 바뀌면 즉시 볼 수 없는 상태로
/// 바뀌고, 이유(차단·지인 피하기)나 UID·Storage 경로는 표시하지 않는다.
class FeedPostDetailScreen extends StatefulWidget {
  final String postId;
  final AuthService authService;
  final CommunityService communityService;
  final CommunityMediaService mediaService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const FeedPostDetailScreen({
    super.key,
    required this.postId,
    required this.authService,
    required this.communityService,
    required this.mediaService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<FeedPostDetailScreen> createState() => _FeedPostDetailScreenState();
}

class _FeedPostDetailScreenState extends State<FeedPostDetailScreen> {
  /// stream error 재시도를 위해 다시 구독할 수 있어야 하므로 final이 아니다.
  late Stream<CommunityPost?> _postStream = widget.communityService.watchPost(
    widget.postId,
  );
  late final Stream<List<CommunityComment>> _commentsStream = widget
      .communityService
      .watchComments(postId: widget.postId);
  late final Stream<bool> _myReactionStream = widget.communityService
      .watchMyReaction(postId: widget.postId, uid: _currentUid ?? '');

  late final CommunityAudienceFilter _audience = CommunityAudienceFilter(
    safetyService: widget.safetyService,
    contactAvoidanceService: widget.contactAvoidanceService,
  );

  final _commentController = TextEditingController();

  bool _busy = false;
  bool _submittingComment = false;

  /// 서버가 돌려준 카운트. stream 값보다 최신일 수 있어 잠깐 우선 사용한다.
  int? _overrideReactionCount;
  bool? _overrideReacted;

  @override
  void initState() {
    super.initState();
    _audience.start(
      uid: _currentUid,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _commentController.addListener(_onCommentChanged);
  }

  @override
  void dispose() {
    _commentController.removeListener(_onCommentChanged);
    _commentController.dispose();
    _audience.dispose();
    super.dispose();
  }

  void _onCommentChanged() => setState(() {});

  /// 게시물 stream이 오류로 끊겼을 때만 사용자가 직접 다시 구독한다.
  void _retryPost() {
    setState(() {
      _postStream = widget.communityService.watchPost(widget.postId);
    });
  }

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── 공감 ────────────────────────────────────────────────────────────────

  Future<void> _toggleReaction() async {
    if (_busy) return;
    _busy = true;
    try {
      final result = await widget.communityService.toggleReaction(
        postId: widget.postId,
      );
      if (!mounted) return;
      setState(() {
        _overrideReacted = result.reacted;
        _overrideReactionCount = result.reactionCount;
      });
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      _busy = false;
    }
  }

  // ── 댓글 ────────────────────────────────────────────────────────────────

  Future<void> _submitComment() async {
    if (_submittingComment) return;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    final allowed = await confirmCommunityTextBeforeSubmit(context, text);
    if (!allowed || !mounted) return;

    setState(() => _submittingComment = true);
    try {
      await widget.communityService.createComment(
        postId: widget.postId,
        text: text,
      );
      if (!mounted) return;
      _commentController.clear();
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      if (mounted) setState(() => _submittingComment = false);
    }
  }

  Future<void> _deleteComment(CommunityComment comment) async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: '댓글을 삭제할까요?',
      message: '삭제하면 다른 사람에게 더 이상 보이지 않아요.',
    );
    if (confirmed != true) return;

    _busy = true;
    try {
      await widget.communityService.deleteComment(
        postId: widget.postId,
        commentId: comment.id,
      );
      _showMessage('댓글을 삭제했어요.');
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      _busy = false;
    }
  }

  // ── 게시물 삭제/신고 ─────────────────────────────────────────────────────

  Future<void> _deletePost(CommunityPost post) async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: '게시물을 삭제할까요?',
      message: '삭제하면 사진도 함께 지워지고 다시 되돌릴 수 없어요.',
    );
    if (confirmed != true) return;

    _busy = true;
    try {
      await widget.communityService.deletePost(postId: widget.postId);
      // 서버가 실제 파일을 지웠으므로 남은 bytes 캐시도 버린다.
      evictFeedImageCache(post.imagePaths);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      _busy = false;
    }
  }

  Future<void> _report({
    required String targetType,
    required String reportedUid,
    String commentId = '',
  }) async {
    final uid = _currentUid;
    if (uid == null || _busy) return;
    _busy = true;
    try {
      final outcome = await showCommunityReportSheet(
        context,
        communityService: widget.communityService,
        safetyService: widget.safetyService,
        currentUid: uid,
        targetType: targetType,
        postId: widget.postId,
        commentId: commentId,
        reportedUid: reportedUid,
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

  Future<bool?> _confirm({required String title, required String message}) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid;
    return Scaffold(
      key: const ValueKey('feed-post-detail-screen'),
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('피드 게시물', style: AppTextStyles.cardTitle),
      ),
      body: SafeArea(
        child: StreamBuilder<CommunityPost?>(
          stream: _postStream,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const _FeedDetailLoading(
                key: ValueKey('feed-detail-loading'),
              );
            }

            // stream 오류와 "삭제/숨김"은 사용자에게 다른 상황이다.
            // 전자는 다시 시도할 수 있고, 후자는 되돌릴 수 없다.
            if (snap.hasError) {
              return _DetailNoticeFrame(
                child: CommunityUnavailableNotice(
                  message: '게시물을 불러오지 못했어요.',
                  retryKey: const ValueKey('feed-detail-retry'),
                  onRetry: _retryPost,
                ),
              );
            }

            final post = snap.data;
            final hidden =
                post != null &&
                _audience.isExcluded(authorUid: post.authorUid, selfUid: uid);

            if (post == null || hidden) {
              return const _DetailNoticeFrame(
                child: CommunityUnavailableNotice(
                  message: '이 게시물은 더 이상 볼 수 없어요.',
                ),
              );
            }

            final isMine = uid != null && post.authorUid == uid;
            return Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    children: [
                      _FeedPostBody(
                        post: post,
                        mediaService: widget.mediaService,
                        isMine: isMine,
                        onDelete: () => _deletePost(post),
                        onReport: () => _report(
                          targetType: 'post',
                          reportedUid: post.authorUid,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.screenH,
                          0,
                          AppSpacing.screenH,
                          AppSpacing.lg20,
                        ),
                        child: CommunityReactionBar(
                          keyPrefix: 'feed',
                          variant: CommunityInteractionVariant.feedEditorial,
                          reactionStream: _myReactionStream,
                          overrideReacted: _overrideReacted,
                          reactionCount:
                              _overrideReactionCount ?? post.reactionCount,
                          commentCount: post.commentCount,
                          onToggle: _toggleReaction,
                        ),
                      ),
                      _CommentSectionHeader(count: post.commentCount),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.screenH,
                        ),
                        child: CommunityCommentList(
                          keyPrefix: 'feed',
                          variant: CommunityInteractionVariant.feedEditorial,
                          stream: _commentsStream,
                          selfUid: uid,
                          audience: _audience,
                          onDelete: _deleteComment,
                          onReport: (comment) => _report(
                            targetType: 'comment',
                            reportedUid: comment.authorUid,
                            commentId: comment.id,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                CommunityCommentInput(
                  keyPrefix: 'feed',
                  variant: CommunityInteractionVariant.feedEditorial,
                  controller: _commentController,
                  submitting: _submittingComment,
                  onSubmit: _submitComment,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// unavailable/error 안내를 화면 여백 안에 놓는 래퍼.
/// 공용 [CommunityUnavailableNotice]는 이번 Phase에서 수정하지 않는다.
class _DetailNoticeFrame extends StatelessWidget {
  final Widget child;

  const _DetailNoticeFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.lg,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      children: [child],
    );
  }
}

/// 댓글 영역의 시작. 실제 `post.commentCount`만 쓴다.
class _CommentSectionHeader extends StatelessWidget {
  final int count;

  const _CommentSectionHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.lg,
        AppSpacing.screenH,
        AppSpacing.sm,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          const ExcludeSemantics(
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 16,
              color: AppColors.brandPrimaryStrong,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('댓글 $count', style: AppTextStyles.sectionTitle),
        ],
      ),
    );
  }
}

/// 상세 진입 skeleton. 이전 게시물을 다시 보여주지 않는다.
class _FeedDetailLoading extends StatelessWidget {
  const _FeedDetailLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.lg20,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const Row(
          children: [
            _SkeletonBox(width: 42, height: 42, radius: 999),
            SizedBox(width: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBox(width: 104, height: 14),
                SizedBox(height: 6),
                _SkeletonBox(width: 64, height: 11),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        // 사진이 주인공인 화면이라 media stage 자리를 크게 잡는다.
        const _SkeletonBox(height: 280, radius: AppRadius.heroSoft),
        const SizedBox(height: AppSpacing.lg20),
        const _SkeletonBox(height: 14),
        const SizedBox(height: AppSpacing.sm),
        const _SkeletonBox(width: 220, height: 14),
        const SizedBox(height: AppSpacing.xl),
        const Row(
          children: [
            _SkeletonBox(width: 108, height: 44, radius: 999),
            SizedBox(width: AppSpacing.md),
            _SkeletonBox(width: 56, height: 13),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        const _SkeletonBox(width: 84, height: 18),
        const SizedBox(height: AppSpacing.lg20),
        for (var i = 0; i < 2; i++) ...[
          const Row(
            children: [
              _SkeletonBox(width: 26, height: 26, radius: 999),
              SizedBox(width: AppSpacing.md),
              _SkeletonBox(width: 84, height: 12),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const _SkeletonBox(height: 13),
          const SizedBox(height: AppSpacing.xl),
        ],
        Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.brandPrimary.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const _SkeletonBox({this.width, required this.height, this.radius = 999});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.canvasSubtle,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 원문 게시물. 카드에 가두지 않고, 사진이 가장 먼저 읽히도록 작성자 →
/// 갤러리 → 본문 순으로 캔버스 위에 배치한다.
class _FeedPostBody extends StatelessWidget {
  final CommunityPost post;
  final CommunityMediaService mediaService;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _FeedPostBody({
    required this.post,
    required this.mediaService,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('feed-detail-post'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.lg20,
        AppSpacing.screenH,
        AppSpacing.lg20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommunityAuthorHeader(
            author: post.author,
            createdAt: post.createdAt,
            avatarRadius: 19,
            trailing: SizedBox(
              width: 40,
              height: 40,
              child: PopupMenuButton<String>(
                key: const ValueKey('feed-detail-post-menu'),
                padding: EdgeInsets.zero,
                tooltip: '게시물 메뉴',
                icon: const Icon(
                  Icons.more_horiz_rounded,
                  size: 20,
                  color: AppColors.textMuted,
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
            ),
          ),
          if (post.hasImages) ...[
            const SizedBox(height: AppSpacing.lg),
            _FeedImageGallery(post: post, mediaService: mediaService),
          ],
          const SizedBox(height: AppSpacing.lg),
          // 본문은 잘리지 않고 전부 보여준다(maxLines 없음).
          Text(post.text, style: AppTextStyles.body.copyWith(fontSize: 15.5)),
        ],
      ),
    );
  }
}

/// 이미지 1~4장을 좌우로 넘겨 본다. 사진을 밝은 뉴트럴 라운드 프레임에 담고,
/// 현재 위치를 dot + `현재/전체` 텍스트로 표시한다.
class _FeedImageGallery extends StatefulWidget {
  /// media stage 높이 범위. page가 바뀌어도, 이미지가 바뀌어도 같은 높이를
  /// 써서 layout shift가 없게 한다(폭 기반으로 한 번만 계산).
  static const double minHeight = 260;
  static const double maxHeight = 360;

  final CommunityPost post;
  final CommunityMediaService mediaService;

  const _FeedImageGallery({required this.post, required this.mediaService});

  @override
  State<_FeedImageGallery> createState() => _FeedImageGalleryState();
}

class _FeedImageGalleryState extends State<_FeedImageGallery> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paths = widget.post.imagePaths;
    final radius = BorderRadius.circular(AppRadius.heroSoft);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxWidth.clamp(
              _FeedImageGallery.minHeight,
              _FeedImageGallery.maxHeight,
            );
            return ClipRRect(
              borderRadius: radius,
              child: Container(
                height: height,
                width: double.infinity,
                color: AppColors.surfaceSecondary,
                child: PageView.builder(
                  key: const ValueKey('feed-detail-gallery'),
                  controller: _controller,
                  itemCount: paths.length,
                  onPageChanged: (index) => setState(() => _index = index),
                  itemBuilder: (context, index) => FeedStorageImage(
                    key: ValueKey('feed-detail-image-$index'),
                    mediaService: widget.mediaService,
                    storagePath: paths[index],
                    height: height,
                    fit: BoxFit.contain,
                    semanticLabel: '${widget.post.author.displayName}님의 피드 사진',
                  ),
                ),
              ),
            );
          },
        ),
        if (paths.length > 1) ...[
          const SizedBox(height: AppSpacing.md),
          Row(
            key: const ValueKey('feed-detail-indicator'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < paths.length; i++) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _index
                        ? AppColors.brandPrimaryStrong
                        : AppColors.borderSubtle,
                  ),
                ),
                if (i != paths.length - 1) const SizedBox(width: 5),
              ],
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${_index + 1} / ${paths.length}',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textBody,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
