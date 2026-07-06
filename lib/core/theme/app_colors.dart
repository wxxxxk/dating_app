import 'package:flutter/material.dart';

/// 앱 전역에서 사용하는 색상 팔레트.
///
/// 왜 한 곳에 모으나:
/// - 색을 화면마다 하드코딩하면 브랜드 색을 바꿀 때 모든 파일을 뒤져야 한다.
/// - 여기 상수 한 군데만 고치면 앱 전체 톤이 일관되게 바뀐다.
class AppColors {
  // 인스턴스를 만들 이유가 없는 상수 모음이므로 생성자를 막아둔다.
  AppColors._();

  /// 데이팅 앱 감성에 맞춘 따뜻한 핑크 계열을 메인 컬러로 사용.
  static const Color primary = Color(0xFFFF4E6A);
  static const Color primaryDark = Color(0xFFE03455);

  static const Color secondary = Color(0xFF7C5CFF);

  static const Color background = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFF7F7F9);

  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF8A8A8E);

  static const Color border = Color(0xFFE5E5EA);
  static const Color error = Color(0xFFE53935);

  static const Color white = Color(0xFFFFFFFF);
}
