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
  late final Stream<CommunityPost?> _postStream = widget.communityService
      .watchPost(widget.postId);
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('게시물'),
      ),
      body: SafeArea(
        child: StreamBuilder<CommunityPost?>(
          stream: _postStream,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(
                key: ValueKey('feed-detail-loading'),
                child: CircularProgressIndicator(),
              );
            }

            final post = snap.hasError ? null : snap.data;
            final hidden =
                post != null &&
                _audience.isExcluded(authorUid: post.authorUid, selfUid: uid);

            if (post == null || hidden) {
              return const Padding(
                padding: EdgeInsets.all(20),
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
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
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
                      const SizedBox(height: 12),
                      CommunityReactionBar(
                        keyPrefix: 'feed',
                        reactionStream: _myReactionStream,
                        overrideReacted: _overrideReacted,
                        reactionCount:
                            _overrideReactionCount ?? post.reactionCount,
                        commentCount: post.commentCount,
                        onToggle: _toggleReaction,
                      ),
                      const SizedBox(height: 16),
                      CommunityCommentList(
                        keyPrefix: 'feed',
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
                    ],
                  ),
                ),
                CommunityCommentInput(
                  keyPrefix: 'feed',
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
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: CommunityAuthorHeader(
              author: post.author,
              createdAt: post.createdAt,
              trailing: SizedBox(
                width: 32,
                height: 32,
                child: PopupMenuButton<String>(
                  key: const ValueKey('feed-detail-post-menu'),
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
              ),
            ),
          ),
          if (post.hasImages)
            _FeedImageGallery(post: post, mediaService: mediaService),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Text(
              post.text,
              style: const TextStyle(
                fontSize: 14.5,
                height: 1.6,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 이미지 1~4장을 좌우로 넘겨 본다. 현재 위치를 인디케이터로 표시한다.
class _FeedImageGallery extends StatefulWidget {
  static const double height = 320;

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
    return Column(
      children: [
        SizedBox(
          height: _FeedImageGallery.height,
          child: PageView.builder(
            key: const ValueKey('feed-detail-gallery'),
            controller: _controller,
            itemCount: paths.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) => FeedStorageImage(
              key: ValueKey('feed-detail-image-$index'),
              mediaService: widget.mediaService,
              storagePath: paths[index],
              height: _FeedImageGallery.height,
              fit: BoxFit.contain,
            ),
          ),
        ),
        if (paths.length > 1) ...[
          const SizedBox(height: 8),
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
                        ? AppColors.matchPrimary
                        : AppColors.border,
                  ),
                ),
                if (i != paths.length - 1) const SizedBox(width: 5),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
