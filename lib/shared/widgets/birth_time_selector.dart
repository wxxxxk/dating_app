import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune/birth_profile.dart';

/// 태어난 시간 입력 위젯 (Phase 5-2).
///
/// 회원가입 기본정보 단계와 기존 사용자 보완 화면이 같은 위젯을 쓴다.
///
/// 규칙:
/// - "알아요"를 골라도 사용자가 실제로 시각을 고르기 전에는 값이 없다.
///   현재 시각이나 정오를 자동으로 채우지 않는다.
/// - "몰라요"는 값 없음이 아니라 **명시적인 선택**이다. 저장되면 시주를
///   계산하지 않는 dateOnly 상태가 된다.
class BirthTimeSelector extends StatelessWidget {
  /// 아직 아무것도 고르지 않았으면 null.
  final bool? timeKnown;

  /// 자정으로부터의 분. "알아요"를 고르고 시각까지 선택했을 때만 값이 있다.
  final int? minutes;

  final ValueChanged<bool> onKnownChanged;
  final ValueChanged<int> onMinutesChanged;

  const BirthTimeSelector({
    super.key,
    required this.timeKnown,
    required this.minutes,
    required this.onKnownChanged,
    required this.onMinutesChanged,
  });

  Future<void> _pickTime(BuildContext context) async {
    final current = minutes;
    final picked = await showTimePicker(
      context: context,
      // 값이 없을 때 자정에서 시작한다. 이것은 기본값 저장이 아니라 다이얼의
      // 시작 위치일 뿐이며, 확인을 누르기 전에는 어떤 값도 저장되지 않는다.
      initialTime: current == null
          ? const TimeOfDay(hour: 0, minute: 0)
          : TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: '태어난 시간 선택',
      confirmText: '확인',
      cancelText: '취소',
      builder: (context, child) {
        // 오전/오후 혼동을 줄이기 위해 24시간 입력으로 고정한다.
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
    if (picked != null) {
      onMinutesChanged(picked.hour * 60 + picked.minute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final knownSelected = timeKnown == true;
    final unknownSelected = timeKnown == false;

    return Column(
      key: const Key('birth-time-selector'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '태어난 시간',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _OptionChip(
                key: const Key('birth-time-known-option'),
                label: '시간을 알아요',
                selected: knownSelected,
                onTap: () => onKnownChanged(true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _OptionChip(
                key: const Key('birth-time-unknown-option'),
                label: '시간을 몰라요',
                selected: unknownSelected,
                onTap: () => onKnownChanged(false),
              ),
            ),
          ],
        ),
        if (knownSelected) ...[
          const SizedBox(height: 12),
          InkWell(
            key: const Key('birth-time-picker'),
            onTap: () => _pickTime(context),
            borderRadius: BorderRadius.circular(AppRadius.button),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '태어난 시각',
                suffixIcon: Icon(
                  Icons.schedule_rounded,
                  size: 18,
                  color: AppColors.fortuneAccent,
                ),
              ),
              child: Text(
                minutes == null ? '시간을 선택하세요' : BirthProfile.formatKorean(minutes!),
                style: TextStyle(
                  fontSize: 15,
                  color: minutes == null
                      ? AppColors.textSecondary
                      : AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
        if (unknownSelected) ...[
          const SizedBox(height: 10),
          const Text(
            '태어난 시간을 입력하면 더 세밀한 사주 해석을 받을 수 있어요.\n'
            '모르셔도 생년월일을 기반으로 기본 해석을 제공해요.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
          ),
        ],
      ],
    );
  }
}

class _OptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppDurations.fast,
        alignment: Alignment.center,
        height: 46,
        decoration: BoxDecoration(
          color: selected ? AppColors.matchPrimary : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(
            color: selected ? AppColors.matchPrimary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.surface : AppColors.textPrimary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
