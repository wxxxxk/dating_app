import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// 해석에 쓰인 출생정보의 정밀도 안내 (Phase 5-2).
///
/// 경고처럼 보이지 않게 조용히, 그러나 명확하게 표시한다. 시간을 모르면
/// 시주가 빠졌다는 사실과 추가 방법만 알려주고 결과를 깎아내리지 않는다.
class SajuPrecisionNotice extends StatelessWidget {
  final bool hasKnownTime;

  /// 절기 경계에 걸려 연주·월주를 확정하지 못한 상태(Phase 5-2A).
  /// 출생시간을 아는 사용자에게는 발생하지 않는다.
  final bool boundaryUncertain;

  /// null이면 "추가하기" 버튼을 표시하지 않는다.
  final VoidCallback? onAddBirthTime;

  const SajuPrecisionNotice({
    super.key,
    required this.hasKnownTime,
    this.boundaryUncertain = false,
    this.onAddBirthTime,
  });

  /// 어떤 근거를 제외했는지를 알려준다. 정확도를 깎아내리는 경고문이 아니다.
  String get _headline {
    if (hasKnownTime) return '생년월일과 태어난 시간을 기준으로 해석했어요.';
    if (boundaryUncertain) {
      return '태어난 시간이 없어 절기 경계에 걸린 일부 항목은 제외하고 해석했어요.';
    }
    return '태어난 시간 없이 기본 사주를 해석했어요.';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: boundaryUncertain && !hasKnownTime
          ? const Key('saju-boundary-uncertainty-notice')
          : const Key('saju-precision-notice'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        // 경고가 아니라 "어떤 근거를 썼는지" 알려주는 조용한 보조 블록이다.
        // warning yellow / danger red를 쓰지 않고 뉴트럴 서피스로만 구분한다.
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hasKnownTime
                ? Icons.check_circle_outline_rounded
                : Icons.schedule_rounded,
            size: 18,
            color: hasKnownTime
                ? AppColors.brandPrimaryStrong
                : AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _headline,
                  style: AppTextStyles.bodySecondary.copyWith(
                    fontSize: 12.5,
                    color: AppColors.textStrong,
                  ),
                ),
                if (!hasKnownTime) ...[
                  const Text(
                    '시간을 추가하면 더 세밀한 내용을 볼 수 있어요.',
                    style: AppTextStyles.caption,
                  ),
                  if (onAddBirthTime != null)
                    // GestureDetector는 글자 높이만큼만 눌렸다. 키와 콜백은
                    // 그대로 두고 최소 터치 영역(44px)과 잉크 반응만 얹는다.
                    InkWell(
                      key: const Key('saju-add-birth-time'),
                      onTap: onAddBirthTime,
                      borderRadius: BorderRadius.circular(AppRadius.small),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        child: Text(
                          '태어난 시간 추가하기',
                          style: AppTextStyles.label.copyWith(
                            fontSize: 12.5,
                            color: AppColors.brandPrimaryStrong,
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 궁합 화면용 — 두 사람 중 확정하지 못한 근거가 있을 때만 표시한다.
class MatchPrecisionNotice extends StatelessWidget {
  final bool missingBirthTime;

  /// 절기 경계 때문에 연주·월주를 확정하지 못한 참가자가 있으면 true.
  final bool boundaryUncertain;

  const MatchPrecisionNotice({
    super.key,
    required this.missingBirthTime,
    this.boundaryUncertain = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!missingBirthTime && !boundaryUncertain) return const SizedBox.shrink();
    return Container(
      key: const Key('match-precision-notice'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.schedule_rounded,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              boundaryUncertain
                  ? '두 사람 중 일부의 출생시간이 없어 확정 가능한 항목만으로 궁합을 해석했어요.'
                  : '두 사람 중 일부의 출생시간이 없어 기본 궁합으로 해석했어요.',
              style: AppTextStyles.bodySecondary.copyWith(
                fontSize: 12.5,
                color: AppColors.textStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
