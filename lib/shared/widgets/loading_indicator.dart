import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 공통 로딩 인디케이터.
///
/// 왜 위젯으로 빼나:
/// - 로딩 표시를 통일하면 "지금 뭔가 처리 중"이라는 신호가 앱 전체에서 일관된다.
/// - [overlay]를 true로 주면 화면 위를 반투명하게 덮어 입력을 막는 용도로 쓴다.
class LoadingIndicator extends StatelessWidget {
  final bool overlay;

  const LoadingIndicator({super.key, this.overlay = false});

  @override
  Widget build(BuildContext context) {
    const spinner = Center(
      child: CircularProgressIndicator(color: AppColors.primary),
    );

    if (!overlay) return spinner;

    // 처리 중 사용자가 버튼을 또 누르지 못하도록 화면을 덮는다.
    return Container(
      color: Colors.black.withValues(alpha: 0.15),
      child: spinner,
    );
  }
}
