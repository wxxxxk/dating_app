import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/community/community_comment.dart';
import 'community_audience_filter.dart';
import 'lounge/lounge_widgets.dart';

/// 라운지·피드 상세가 공유하는 공감/댓글 요소(Phase 4-3).
///
/// Phase 4-2에서 검증된 라운지 상세의 계약을 그대로 옮긴 것이다 — 표시 규칙과
/// 위젯 key 체계는 바꾸지 않고, 화면별 접두사([keyPrefix])만 다르게 준다.
/// 누가 공감했는지는 어디에도 표시하지 않는다.

/// 공감 버튼 높이. 전역 버튼 theme의 무한 폭 minimumSize를 대체할 때 쓴다.
const double _reactionButtonHeight = 44;

/// 공감 버튼 + 공감/댓글 수.
class CommunityReactionBar extends StatelessWidget {
  final String keyPrefix;
  final Stream<bool> reactionStream;
  final bool? overrideReacted;
  final int reactionCount;
  final int commentCount;
  final VoidCallback onToggle;

  const CommunityReactionBar({
    super.key,
    required this.keyPrefix,
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
              key: ValueKey('$keyPrefix-reaction-button'),
              // 전역 outlinedButtonTheme의 minimumSize도 폭이 double.infinity라
              // Row 안에서는 그대로 무한 폭 제약이 된다. 폭은 내용에 맞추고
              // 높이만 유지한다.
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, _reactionButtonHeight),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
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

/// 댓글 목록. 차단·지인 피하기 상대의 댓글은 표시만 건너뛴다.
class CommunityCommentList extends StatelessWidget {
  final String keyPrefix;
  final Stream<List<CommunityComment>> stream;
  final String? selfUid;
  final CommunityAudienceFilter audience;
  final void Function(CommunityComment) onDelete;
  final void Function(CommunityComment) onReport;

  const CommunityCommentList({
    super.key,
    required this.keyPrefix,
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
          return Text(
            '댓글을 불러오지 못했어요.',
            key: ValueKey('$keyPrefix-comment-error'),
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
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
          return Text(
            '첫 댓글을 남겨보세요.',
            key: ValueKey('$keyPrefix-comment-empty'),
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          );
        }

        return Column(
          key: ValueKey('$keyPrefix-comment-list'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final comment in comments) ...[
              CommunityCommentTile(
                keyPrefix: keyPrefix,
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

class CommunityCommentTile extends StatelessWidget {
  final String keyPrefix;
  final CommunityComment comment;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const CommunityCommentTile({
    super.key,
    required this.keyPrefix,
    required this.comment,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('$keyPrefix-comment-${comment.id}'),
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
                key: ValueKey('$keyPrefix-comment-menu-${comment.id}'),
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

/// 댓글 등록 버튼의 고정 크기. 전역 버튼 theme의 무한 폭 minimumSize가
/// Row 안에서 그대로 적용되지 않도록 local style에서 덮어쓴다.
const double _submitButtonWidth = 72;
const double _submitButtonHeight = 48;

/// 하단 댓글 입력줄. 키보드가 올라와도 가려지지 않게 viewInsets를 더한다.
class CommunityCommentInput extends StatelessWidget {
  final String keyPrefix;
  final TextEditingController controller;
  final bool submitting;
  final VoidCallback onSubmit;

  const CommunityCommentInput({
    super.key,
    required this.keyPrefix,
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
              key: ValueKey('$keyPrefix-comment-input'),
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
          // 전역 filledButtonTheme의 minimumSize가 Size.fromHeight(48),
          // 즉 폭이 double.infinity다. Row의 non-flex 자식은 unbounded width
          // 제약을 받으므로 그대로 두면 "BoxConstraints forces an infinite
          // width" assertion이 난다. 여기서만 폭을 명시적으로 고정한다.
          SizedBox(
            width: _submitButtonWidth,
            height: _submitButtonHeight,
            child: FilledButton(
              key: ValueKey('$keyPrefix-comment-submit'),
              style: FilledButton.styleFrom(
                minimumSize: Size.zero,
                fixedSize: const Size(_submitButtonWidth, _submitButtonHeight),
                maximumSize: const Size(_submitButtonWidth, _submitButtonHeight),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: canSubmit ? onSubmit : null,
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('등록'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
