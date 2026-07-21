import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../lounge/lounge_widgets.dart';

/// Party·Square 표시 요소(Phase 4-4).
///
/// 표시하는 값은 파티 문서에 저장된 공개 snapshot과 광역 지역 label뿐이다 —
/// UID·전화번호·정확 주소·생년월일·기관명·차단/지인 관계는 어떤 경로로도
/// 그리지 않는다.

/// 모임 시각 표시. 오늘/내일은 그렇게, 나머지는 월.일 (요일) 시:분.
String formatPartyStartAt(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(local.year, local.month, local.day);
  final diffDays = target.difference(today).inDays;

  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final time = '$hour:$minute';

  if (diffDays == 0) return '오늘 $time';
  if (diffDays == 1) return '내일 $time';

  const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  final weekday = weekdays[local.weekday - 1];
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$month.$day ($weekday) $time';
}

/// 참여 인원 표시. 정확한 참여자 명단은 어디에도 노출하지 않는다.
String formatPartyParticipants(CommunityParty party) =>
    '${party.participantCount}/${party.maxParticipants}명';

/// 카테고리·지역·시간 같은 짧은 메타 칩.
class PartyMetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool emphasized;

  const PartyMetaChip({
    super.key,
    required this.icon,
    required this.label,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: emphasized ? AppColors.mintSoft : AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(
          color: emphasized ? AppColors.mintSoft : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: emphasized ? AppColors.mintDeep : AppColors.textSecondary,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: emphasized ? AppColors.mintDeep : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 모집 상태 배지(모집 중 / 마감).
class PartyStatusBadge extends StatelessWidget {
  final CommunityParty party;

  const PartyStatusBadge({super.key, required this.party});

  @override
  Widget build(BuildContext context) {
    final full = party.isFull;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: full ? AppColors.background : AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: full ? AppColors.border : AppColors.mintSoft),
      ),
      child: Text(
        full ? '마감' : '모집 중',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: full ? AppColors.textSecondary : AppColors.mintDeep,
        ),
      ),
    );
  }
}

/// Square 목록 카드.
class PartyCard extends StatelessWidget {
  final CommunityParty party;
  final VoidCallback onTap;

  const PartyCard({super.key, required this.party, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey('party-card-${party.id}'),
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
                author: party.host,
                createdAt: party.createdAt,
                avatarRadius: 14,
                trailing: PartyStatusBadge(party: party),
              ),
              const SizedBox(height: 10),
              Text(
                party.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  PartyMetaChip(
                    icon: Icons.schedule_rounded,
                    label: formatPartyStartAt(party.startAt),
                    emphasized: true,
                  ),
                  PartyMetaChip(
                    icon: Icons.place_outlined,
                    label: party.areaLabel,
                  ),
                  PartyMetaChip(
                    icon: Icons.local_activity_outlined,
                    label: party.categoryLabel,
                  ),
                  PartyMetaChip(
                    icon: Icons.group_outlined,
                    label: formatPartyParticipants(party),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 파티 화면 공통 안전 안내. 정확한 장소·연락처를 공개하지 않도록 알린다.
class PartySafetyNotice extends StatelessWidget {
  const PartySafetyNotice({super.key});

  static const String message =
      '정확한 만남 장소나 연락처는 공개 설명에 적지 마세요.\n참여가 확정된 뒤 안전하게 공유해주세요.';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('party-safety-notice'),
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
              message,
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

/// 그룹 채팅이 아직 열리지 않았음을 명확히 알리는 안내.
class PartyGroupChatNotice extends StatelessWidget {
  const PartyGroupChatNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('party-group-chat-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.groups_outlined, size: 17, color: AppColors.textSecondary),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '파티 그룹 채팅은 아직 준비 중이에요. 지금은 파티 안에서 대화할 수 없어요.',
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

/// 빈 상태·오류 상태 공통 안내.
class PartyNotice extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final Key? retryKey;

  const PartyNotice({
    super.key,
    required this.message,
    this.onRetry,
    this.retryKey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
