import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 앱 공통 버튼.
///
/// 왜 따로 만드나:
/// - 버튼 모양(높이, 둥글기, 색)을 화면마다 다시 쓰면 디자인이 제각각이 된다.
/// - 공통 위젯으로 빼면 한 번 정의로 모든 화면에서 일관된 버튼을 쓴다.
///
/// [outlined]를 주면 테두리만 있는 보조 버튼(예: 전화 로그인)으로 쓸 수 있다.
/// [icon]을 주면 아이콘 + 텍스트 형태(예: 구글 로고)로 표시된다.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  final Widget? icon;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.outlined = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    // 버튼 안의 내용물(아이콘 + 텍스트)을 구성.
    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          icon!,
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ],
    );

    // 높이를 고정해 화면 간 버튼 크기를 통일.
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: outlined
          ? OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: content,
            )
          : ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: content,
            ),
    );
  }
}
