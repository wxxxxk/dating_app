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
  // 기본은 null → 시그니처 CTA(비비드 민트 fill + 다크 잉크 텍스트).
  // destructive 액션 등 의미가 다른 호출부만 색을 명시적으로 넘긴다.
  final Color? color;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.outlined = false,
    this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    // 버튼 안의 내용물(아이콘 + 텍스트)을 구성.
    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[icon!, const SizedBox(width: 8)],
        Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ],
    );

    // 시그니처 CTA 문법: 민트 fill 위에는 항상 다크 잉크 텍스트(onMint).
    // 흰 텍스트는 민트 계열 위에서 대비가 부족하다. 호출부가 다른 색을
    // 명시하면(예: destructive) 그때만 흰 텍스트를 쓴다.
    final effectiveColor = color ?? AppColors.mint;
    final effectiveForeground = effectiveColor == AppColors.mint
        ? AppColors.onMint
        : AppColors.surface;

    // 높이를 고정해 화면 간 버튼 크기를 통일.
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: outlined
          ? OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: color ?? AppColors.textPrimary,
                side: BorderSide(color: color ?? AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
              ),
              child: content,
            )
          : ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: effectiveColor,
                foregroundColor: effectiveForeground,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
              ),
              child: content,
            ),
    );
  }
}
