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

/// 라운지·피드 상세가 공유하는 요소의 **시각** 변형.
///
/// 기능 분기가 아니라 스타일 분기 전용이다. 기본값은 [legacy]이고, 호출부가
/// 명시적으로 [loungeEditorial]을 넘길 때만 새 대화 스레드 문법으로 그린다.
/// keyPrefix로 스타일을 추론하지 않는다 — 접두사는 key 생성에만 쓴다.
enum CommunityInteractionVariant {
  /// Phase 4-3까지의 카드형 렌더링. 기본값(테스트/구 화면 호환용).
  legacy,

  /// Design Phase 1-I 라운지 대화 스레드 문법.
  loungeEditorial,

  /// Design Phase 1-K 피드 상세 문법. 시각 표현은 라운지 에디토리얼과 같은
  /// 계열(뉴트럴 divider 스레드 + soft coral 공감 + 민트 composer)을 쓰되,
  /// 화면 레이아웃(사진 우선)은 호출부인 피드 상세가 담당한다.
  feedEditorial,
}

/// 시각 분기 판정. loungeEditorial/feedEditorial은 같은 에디토리얼 표현을
/// 공유하고, legacy만 구 카드형이다. keyPrefix로 스타일을 추론하지 않는다.
extension CommunityInteractionVariantX on CommunityInteractionVariant {
  bool get isEditorial =>
      this == CommunityInteractionVariant.loungeEditorial ||
      this == CommunityInteractionVariant.feedEditorial;
}

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
  final CommunityInteractionVariant variant;

  const CommunityReactionBar({
    super.key,
    required this.keyPrefix,
    required this.reactionStream,
    required this.overrideReacted,
    required this.reactionCount,
    required this.commentCount,
    required this.onToggle,
    this.variant = CommunityInteractionVariant.legacy,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: reactionStream,
      builder: (context, snap) {
        // override는 서버가 돌려준 값이므로 stream보다 우선한다(계약 유지).
        final reacted = overrideReacted ?? (snap.data ?? false);
        if (variant.isEditorial) {
          return _LoungeReactionRow(
            buttonKey: ValueKey('$keyPrefix-reaction-button'),
            reacted: reacted,
            reactionCount: reactionCount,
            commentCount: commentCount,
            onToggle: onToggle,
          );
        }
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
  final CommunityInteractionVariant variant;

  const CommunityCommentList({
    super.key,
    required this.keyPrefix,
    required this.stream,
    required this.selfUid,
    required this.audience,
    required this.onDelete,
    required this.onReport,
    this.variant = CommunityInteractionVariant.legacy,
  });

  bool get _editorial => variant.isEditorial;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CommunityComment>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          if (_editorial) {
            // retry callback이 없는 계약이라 버튼을 새로 만들지 않는다.
            return _LoungeCommentNotice(
              noticeKey: ValueKey('$keyPrefix-comment-error'),
              icon: Icons.error_outline_rounded,
              iconColor: AppColors.statusDanger,
              iconBackground: AppColors.statusDangerSoft,
              message: '댓글을 불러오지 못했어요.',
            );
          }
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
          if (_editorial) {
            return _LoungeCommentNotice(
              noticeKey: ValueKey('$keyPrefix-comment-empty'),
              icon: Icons.chat_bubble_outline_rounded,
              iconColor: AppColors.textMuted,
              iconBackground: AppColors.surfaceSecondary,
              message: '첫 댓글을 남겨보세요.',
            );
          }
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
                variant: variant,
                // 마지막 댓글 아래에는 구분선을 두지 않는다.
                showDivider: _editorial && comment != comments.last,
              ),
              if (!_editorial) const SizedBox(height: 8),
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
  final CommunityInteractionVariant variant;
  final bool showDivider;

  const CommunityCommentTile({
    super.key,
    required this.keyPrefix,
    required this.comment,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
    this.variant = CommunityInteractionVariant.legacy,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    final editorial = variant.isEditorial;

    final menu = SizedBox(
      // 본문보다 강해 보이지 않게 톤은 낮추고 터치 영역만 넉넉히 둔다.
      width: editorial ? 40 : 32,
      height: editorial ? 40 : 32,
      child: PopupMenuButton<String>(
        key: ValueKey('$keyPrefix-comment-menu-${comment.id}'),
        padding: EdgeInsets.zero,
        tooltip: editorial ? '댓글 메뉴' : null,
        icon: Icon(
          Icons.more_horiz_rounded,
          size: editorial ? 18 : 16,
          color: editorial ? AppColors.textMuted : AppColors.textSecondary,
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

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CommunityAuthorHeader(
          author: comment.author,
          createdAt: comment.createdAt,
          avatarRadius: 13,
          trailing: menu,
        ),
        SizedBox(height: editorial ? 10 : 8),
        Text(
          comment.text,
          style: editorial
              ? AppTextStyles.body.copyWith(fontSize: 14)
              : const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: AppColors.textPrimary,
                ),
        ),
      ],
    );

    if (editorial) {
      // 댓글마다 카드를 쌓지 않고, 캔버스 흐름 위에 얇은 divider로만 나눈다.
      return Container(
        key: ValueKey('$keyPrefix-comment-${comment.id}'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        decoration: BoxDecoration(
          border: showDivider
              ? const Border(bottom: BorderSide(color: AppColors.borderSubtle))
              : null,
        ),
        child: body,
      );
    }

    return Container(
      key: ValueKey('$keyPrefix-comment-${comment.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: body,
    );
  }
}

/// 라운지 variant의 공감 행.
///
/// 미선택은 뉴트럴, 선택은 옅은 코랄 fill + 채워진 아이콘으로 **색과 형태
/// 양쪽**으로 구분한다. 좁은 폭에서는 Wrap으로 줄바꿈된다.
class _LoungeReactionRow extends StatelessWidget {
  final Key buttonKey;
  final bool reacted;
  final int reactionCount;
  final int commentCount;
  final VoidCallback onToggle;

  const _LoungeReactionRow({
    required this.buttonKey,
    required this.reacted,
    required this.reactionCount,
    required this.commentCount,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          button: true,
          selected: reacted,
          child: ExcludeSemantics(
            child: OutlinedButton.icon(
              key: buttonKey,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, _reactionButtonHeight),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: reacted
                    ? AppColors.expressiveAccentSoft
                    : AppColors.surfacePrimary,
                foregroundColor: AppColors.textStrong,
                side: BorderSide(
                  color: reacted
                      ? AppColors.expressiveAccent.withValues(alpha: 0.5)
                      : AppColors.borderSubtle,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
                textStyle: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: onToggle,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  reacted
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  key: ValueKey(reacted),
                  size: 18,
                  color: reacted
                      ? AppColors.expressiveAccent
                      : AppColors.textMuted,
                ),
              ),
              label: Text('공감 $reactionCount'),
            ),
          ),
        ),
        Text(
          '댓글 $commentCount',
          style: AppTextStyles.caption.copyWith(color: AppColors.textBody),
        ),
      ],
    );
  }
}

/// 라운지 variant의 댓글 empty/error 안내. 오류처럼 과하게 보이지 않도록
/// 아이콘 배지에만 톤을 주고 나머지는 뉴트럴로 둔다.
class _LoungeCommentNotice extends StatelessWidget {
  final Key noticeKey;
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String message;

  const _LoungeCommentNotice({
    required this.noticeKey,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: noticeKey,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg20,
      ),
      child: Column(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconBackground,
                borderRadius: BorderRadius.circular(AppRadius.small),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.caption,
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
  final CommunityInteractionVariant variant;

  const CommunityCommentInput({
    super.key,
    required this.keyPrefix,
    required this.controller,
    required this.submitting,
    required this.onSubmit,
    this.variant = CommunityInteractionVariant.legacy,
  });

  @override
  Widget build(BuildContext context) {
    final canSubmit = controller.text.trim().isNotEmpty && !submitting;
    final editorial = variant.isEditorial;

    final row = Row(
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
            style: editorial ? AppTextStyles.body.copyWith(fontSize: 14) : null,
            onSubmitted: (_) {
              if (canSubmit) onSubmit();
            },
            decoration: editorial
                ? InputDecoration(
                    hintText: '댓글을 입력하세요',
                    counterText: '',
                    filled: true,
                    fillColor: AppColors.surfaceSecondary,
                    hintStyle: AppTextStyles.bodySecondary.copyWith(
                      fontSize: 14,
                      color: AppColors.textMuted,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      borderSide: const BorderSide(
                        color: AppColors.borderSubtle,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      borderSide: const BorderSide(
                        color: AppColors.brandPrimaryStrong,
                        width: 1.5,
                      ),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      borderSide: const BorderSide(
                        color: AppColors.borderSubtle,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.md,
                    ),
                  )
                : const InputDecoration(
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
              backgroundColor: editorial ? AppColors.brandPrimaryStrong : null,
              foregroundColor: editorial ? AppColors.onBrandPrimary : null,
              // 지정하지 않으면 전역 테마의 구 divider(웜 베이지)로 떨어져
              // 새 팔레트 위에서 튄다.
              disabledBackgroundColor: editorial
                  ? AppColors.canvasSubtle
                  : null,
              disabledForegroundColor: editorial ? AppColors.textMuted : null,
              shape: editorial
                  ? RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    )
                  : null,
            ),
            onPressed: canSubmit ? onSubmit : null,
            child: submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const FittedBox(fit: BoxFit.scaleDown, child: Text('등록')),
          ),
        ),
      ],
    );

    final padded = Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: row,
    );

    if (!editorial) return padded;

    // 목록 스크롤과 입력줄을 시각적으로 분리한다. 높이는 legacy와 동일하다.
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surfacePrimary,
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: padded,
    );
  }
}
