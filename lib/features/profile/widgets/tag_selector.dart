import 'package:flutter/material.dart';

import '../../../core/constants/profile_options.dart';
import '../../../core/theme/app_colors.dart';

/// 태그 선택 그리드 위젯 — 관심사·성향·이상형 세 곳에서 공통으로 재사용된다.
///
/// 이 위젯은 선택 상태를 직접 들고 있지 않는다(비상태형).
/// 선택 결과는 [onChanged]로 상위에 올려 보내고, 상위가 [selectedKeys]를 내려준다.
/// 이렇게 하면 온보딩·편집 어느 화면에서도 상태 관리가 일관된다.
class TagSelector extends StatelessWidget {
  /// 표시할 옵션 목록.
  final List<TagOption> options;

  /// 현재 선택된 태그 key 목록.
  final List<String> selectedKeys;

  /// 최대 선택 개수 (기본 8개).
  final int maxSelection;

  /// 선택이 바뀔 때마다 업데이트된 key 목록 전체를 콜백으로 올린다.
  final void Function(List<String> updatedKeys) onChanged;

  const TagSelector({
    super.key,
    required this.options,
    required this.selectedKeys,
    this.maxSelection = 8,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 선택 개수 카운터
        Text(
          '${selectedKeys.length}/$maxSelection개 선택',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: selectedKeys.length >= maxSelection
                ? AppColors.primary
                : AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: options.map((opt) {
            final isSelected = selectedKeys.contains(opt.key);
            return _TagChip(
              label: opt.label,
              isSelected: isSelected,
              onTap: () => _handleTap(context, opt.key, isSelected),
            );
          }).toList(),
        ),
      ],
    );
  }

  void _handleTap(BuildContext context, String key, bool isSelected) {
    if (!isSelected && selectedKeys.length >= maxSelection) {
      // 최대 개수 초과 시 선택 불가 + 안내 메시지
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('최대 $maxSelection개까지 선택할 수 있어요'),
          duration: const Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final updated = List<String>.from(selectedKeys);
    if (isSelected) {
      updated.remove(key);
    } else {
      updated.add(key);
    }
    onChanged(updated);
  }
}

/// 개별 태그 칩 — 선택 여부에 따라 색상이 전환된다.
class _TagChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TagChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: isSelected ? AppColors.white : AppColors.textPrimary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
