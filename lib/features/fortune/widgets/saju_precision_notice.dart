import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// 해석에 쓰인 출생정보의 정밀도 안내 (Phase 5-2).
///
/// 경고처럼 보이지 않게 조용히, 그러나 명확하게 표시한다. 시간을 모르면
/// 시주가 빠졌다는 사실과 추가 방법만 알려주고 결과를 깎아내리지 않는다.
class SajuPrecisionNotice extends StatelessWidget {
  final bool hasKnownTime;

  /// null이면 "추가하기" 버튼을 표시하지 않는다.
  final VoidCallback? onAddBirthTime;

  const SajuPrecisionNotice({
    super.key,
    required this.hasKnownTime,
    this.onAddBirthTime,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('saju-precision-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
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
                ? AppColors.matchPrimary
                : AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasKnownTime
                      ? '생년월일과 태어난 시간을 기준으로 해석했어요.'
                      : '태어난 시간 없이 기본 사주를 해석했어요.',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textPrimary,
                    height: 1.5,
                  ),
                ),
                if (!hasKnownTime) ...[
                  const Text(
                    '시간을 추가하면 더 세밀한 내용을 볼 수 있어요.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                  if (onAddBirthTime != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: GestureDetector(
                        key: const Key('saju-add-birth-time'),
                        onTap: onAddBirthTime,
                        child: const Text(
                          '태어난 시간 추가하기',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.matchPrimary,
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

/// 궁합 화면용 — 두 사람 중 한 명이라도 출생시간이 없을 때만 표시한다.
class MatchPrecisionNotice extends StatelessWidget {
  final bool missingBirthTime;

  const MatchPrecisionNotice({super.key, required this.missingBirthTime});

  @override
  Widget build(BuildContext context) {
    if (!missingBirthTime) return const SizedBox.shrink();
    return Container(
      key: const Key('match-precision-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule_rounded, size: 18, color: AppColors.textSecondary),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '두 사람 중 일부의 출생시간이 없어 기본 궁합으로 해석했어요.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.textPrimary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
