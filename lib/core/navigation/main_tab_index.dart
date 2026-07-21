/// 하단 내비게이션 탭 index 상수(Phase 4-1).
///
/// 알림 딥링크·화면 간 이동이 숫자 리터럴을 쓰면 탭이 추가될 때 조용히
/// 어긋난다. 의미 있는 탭 이동은 이 상수를 쓴다.
abstract final class MainTabIndex {
  static const int discovery = 0;
  static const int matches = 1;
  static const int fortune = 2;
  static const int community = 3;
  static const int profile = 4;

  static const int min = discovery;
  static const int max = profile;

  /// mainTabRequest로 들어온 값이 유효한 탭인지.
  static bool isValid(int index) => index >= min && index <= max;
}
