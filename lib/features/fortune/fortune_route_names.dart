/// 사주 상세 화면 라우트 이름.
///
/// 상세 화면을 열 때 기존 사주 상세 라우트를 정리해
/// `MainShell -> 현재 상세` 구조를 유지하기 위한 식별자다.
class FortuneRouteNames {
  const FortuneRouteNames._();

  static const my = '/fortune/my';
  static const match = '/fortune/match';
  static const history = '/fortune/history';
  static const idealType = '/fortune/ideal-type';
}
