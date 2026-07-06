import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/primary_button.dart';

/// 온보딩 스텝 6 (마지막) — 찾는 관계 단일 선택.
///
/// 선택 후 [onCompleted]를 호출해 온보딩 종료를 상위에 알린다.
/// [isLoading]이 true이면 버튼을 비활성화해 중복 탭을 막는다.
class RelationshipGoalStep extends StatefulWidget {
  final String? initialGoal; // 편집 모드에서 기존 값 미리 선택
  final bool isLoading;

  /// 마지막 스텝 완료 콜백. 선택된 goal key(또는 null)를 넘겨준다.
  final Future<void> Function(String? goalKey) onCompleted;

  const RelationshipGoalStep({
    super.key,
    this.initialGoal,
    this.isLoading = false,
    required this.onCompleted,
  });

  @override
  State<RelationshipGoalStep> createState() => _RelationshipGoalStepState();
}

class _RelationshipGoalStepState extends State<RelationshipGoalStep> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialGoal;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '어떤 인연을 찾고 있나요?',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '선택한 목적이 비슷한 사람과 더 잘 맞을 수 있어요',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 32),

          // 선택 카드 목록
          ...ProfileOptions.relationshipGoals.map((opt) {
            final isSelected = _selected == opt.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GestureDetector(
                onTap: () => setState(() => _selected = opt.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color:
                        isSelected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.border,
                      width: isSelected ? 1.8 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          opt.label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (isSelected)
                        const Icon(Icons.check_circle,
                            color: AppColors.primary, size: 22),
                    ],
                  ),
                ),
              ),
            );
          }),

          const Spacer(),
          PrimaryButton(
            label: '완료',
            // 선택하지 않아도 완료 가능 (선택 사항)
            onPressed: widget.isLoading
                ? null
                : () => widget.onCompleted(_selected),
          ),
        ],
      ),
    );
  }
}
