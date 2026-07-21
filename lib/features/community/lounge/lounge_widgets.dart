import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_author_snapshot.dart';

/// 라운지 목록/상세가 공유하는 표시 요소(Phase 4-2).
///
/// 표시하는 값은 콘텐츠에 저장된 공개 snapshot뿐이다 — UID·전화번호·기관명·
/// 이메일·정확 위치·매칭/관계 정보는 어떤 경로로도 그리지 않는다.

/// 작성일 표시. 오늘은 시:분, 그 외에는 월.일.
String formatCommunityTimestamp(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  final now = DateTime.now();
  final isToday =
      local.year == now.year && local.month == now.month && local.day == now.day;
  if (isToday) {
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$month.$day';
}

/// 인증 배지(사진/직장/학교). 이메일·전화 인증은 커뮤니티에 노출하지 않는다.
class CommunityAuthorBadge extends StatelessWidget {
  final String label;

  const CommunityAuthorBadge({super.key, required this.label});

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

/// 프로필 사진 + 이름 + 배지 + 작성 시각 + (선택) 메뉴.
class CommunityAuthorHeader extends StatelessWidget {
  final CommunityAuthorSnapshot author;
  final DateTime? createdAt;
  final Widget? trailing;
  final double avatarRadius;

  const CommunityAuthorHeader({
    super.key,
    required this.author,
    required this.createdAt,
    this.trailing,
    this.avatarRadius = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: avatarRadius,
          backgroundColor: AppColors.border,
          backgroundImage: author.photoUrl.isNotEmpty
              ? NetworkImage(author.photoUrl)
              : null,
          child: author.photoUrl.isEmpty
              ? Icon(
                  Icons.person_rounded,
                  size: avatarRadius,
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
                      const CommunityAuthorBadge(label: '사진 인증'),
                    if (author.workVerified)
                      const CommunityAuthorBadge(label: '직장 인증'),
                    if (author.schoolVerified)
                      const CommunityAuthorBadge(label: '학교 인증'),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            formatCommunityTimestamp(createdAt),
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 공감/댓글 수 표시(읽기 전용 메타 줄).
class CommunityCountRow extends StatelessWidget {
  final int reactionCount;
  final int commentCount;

  const CommunityCountRow({
    super.key,
    required this.reactionCount,
    required this.commentCount,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.favorite_border_rounded,
          size: 15,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Text(
          '$reactionCount',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 12),
        const Icon(
          Icons.mode_comment_outlined,
          size: 15,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Text(
          '$commentCount',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// 콘텐츠를 볼 수 없을 때 쓰는 고정 안내(삭제/숨김/관계 변경 공통).
///
/// 이유(차단인지 지인 피하기인지)나 UID는 표시하지 않는다.
class CommunityUnavailableNotice extends StatelessWidget {
  final String message;

  /// 일시적 오류일 때만 준다. 삭제·차단처럼 되돌릴 수 없는 상태에는 없다.
  final VoidCallback? onRetry;
  final Key? retryKey;

  const CommunityUnavailableNotice({
    super.key,
    required this.message,
    this.onRetry,
    this.retryKey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('community-unavailable-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          if (onRetry != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: retryKey,
                onPressed: onRetry,
                child: const Text('다시 시도'),
              ),
            ),
        ],
      ),
    );
  }
}
