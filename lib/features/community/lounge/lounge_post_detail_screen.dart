import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_comment.dart';
import '../../../models/community/community_post.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import '../community_text_guard.dart';
import 'lounge_widgets.dart';

/// 라운지 게시물 상세(Phase 4-2).
///
/// 게시물 본문 + 공감 + 댓글 목록/작성 + 신고·삭제를 담당한다.
/// 게시물이 삭제/숨김되거나 작성자와의 관계가 바뀌면 즉시 볼 수 없는 상태로
/// 바뀌고, 이유(차단·지인 피하기)나 UID는 표시하지 않는다.
class LoungePostDetailScreen extends StatefulWidget {
  final String postId;
  final AuthService authService;
  final CommunityService communityService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const LoungePostDetailScreen({
    super.key,
    required this.postId,
    required this.authService,
    required this.communityService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<LoungePostDetailScreen> createState() => _LoungePostDetailScreenState();
}

class _LoungePostDetailScreenState extends State<LoungePostDetailScreen> {
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

  Future<void> _deletePost() async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: '글을 삭제할까요?',
      message: '삭제하면 라운지에서 바로 사라져요.',
    );
    if (confirmed != true) return;

    _busy = true;
    try {
      await widget.communityService.deletePost(postId: widget.postId);
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
      key: const ValueKey('lounge-post-detail-screen'),
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
                key: ValueKey('lounge-detail-loading'),
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
                      _PostBody(
                        post: post,
                        isMine: isMine,
                        onDelete: _deletePost,
                        onReport: () => _report(
                          targetType: 'post',
                          reportedUid: post.authorUid,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _ReactionBar(
                        reactionStream: _myReactionStream,
                        overrideReacted: _overrideReacted,
                        reactionCount:
                            _overrideReactionCount ?? post.reactionCount,
                        commentCount: post.commentCount,
                        onToggle: _toggleReaction,
                      ),
                      const SizedBox(height: 16),
                      _CommentList(
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
                _CommentInput(
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

class _PostBody extends StatelessWidget {
  final CommunityPost post;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _PostBody({
    required this.post,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('lounge-detail-post'),
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
          CommunityAuthorHeader(
            author: post.author,
            createdAt: post.createdAt,
            trailing: SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                key: const ValueKey('lounge-detail-post-menu'),
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
          const SizedBox(height: 12),
          Text(
            post.text,
            style: const TextStyle(
              fontSize: 14.5,
              height: 1.6,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 공감 버튼 + 카운트. 누가 공감했는지는 어디에도 표시하지 않는다.
class _ReactionBar extends StatelessWidget {
  final Stream<bool> reactionStream;
  final bool? overrideReacted;
  final int reactionCount;
  final int commentCount;
  final VoidCallback onToggle;

  const _ReactionBar({
    required this.reactionStream,
    required this.overrideReacted,
    required this.reactionCount,
    required this.commentCount,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: reactionStream,
      builder: (context, snap) {
        final reacted = overrideReacted ?? (snap.data ?? false);
        return Row(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('lounge-reaction-button'),
              onPressed: onToggle,
              icon: Icon(
                reacted
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 18,
                color: AppColors.matchPrimary,
              ),
              label: Text('공감 $reactionCount'),
            ),
            const SizedBox(width: 12),
            Text(
              '댓글 $commentCount',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CommentList extends StatelessWidget {
  final Stream<List<CommunityComment>> stream;
  final String? selfUid;
  final CommunityAudienceFilter audience;
  final void Function(CommunityComment) onDelete;
  final void Function(CommunityComment) onReport;

  const _CommentList({
    required this.stream,
    required this.selfUid,
    required this.audience,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CommunityComment>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Text(
            '댓글을 불러오지 못했어요.',
            key: ValueKey('lounge-comment-error'),
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          );
        }
        final comments = (snap.data ?? const <CommunityComment>[])
            .where(
              (comment) => !audience.isExcluded(
                authorUid: comment.authorUid,
                selfUid: selfUid,
              ),
            )
            .toList();

        if (comments.isEmpty) {
          return const Text(
            '첫 댓글을 남겨보세요.',
            key: ValueKey('lounge-comment-empty'),
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          );
        }

        return Column(
          key: const ValueKey('lounge-comment-list'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final comment in comments) ...[
              _CommentTile(
                comment: comment,
                isMine: selfUid != null && comment.authorUid == selfUid,
                onDelete: () => onDelete(comment),
                onReport: () => onReport(comment),
              ),
              const SizedBox(height: 8),
            ],
          ],
        );
      },
    );
  }
}

class _CommentTile extends StatelessWidget {
  final CommunityComment comment;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _CommentTile({
    required this.comment,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('lounge-comment-${comment.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommunityAuthorHeader(
            author: comment.author,
            createdAt: comment.createdAt,
            avatarRadius: 13,
            trailing: SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                key: ValueKey('lounge-comment-menu-${comment.id}'),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.more_horiz_rounded,
                  size: 16,
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
          const SizedBox(height: 8),
          Text(
            comment.text,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentInput extends StatelessWidget {
  final TextEditingController controller;
  final bool submitting;
  final VoidCallback onSubmit;

  const _CommentInput({
    required this.controller,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final canSubmit = controller.text.trim().isNotEmpty && !submitting;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('lounge-comment-input'),
              controller: controller,
              maxLength: CommunityComment.textMaxLength,
              minLines: 1,
              maxLines: 4,
              enabled: !submitting,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                if (canSubmit) onSubmit();
              },
              decoration: const InputDecoration(
                hintText: '댓글을 입력하세요',
                counterText: '',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('lounge-comment-submit'),
            onPressed: canSubmit ? onSubmit : null,
            child: submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('등록'),
          ),
        ],
      ),
    );
  }
}
