/// 앱 전역에서 쓰는 고정 값 모음.
///
/// 왜 상수로 빼나:
/// - Firestore 컬렉션 이름 같은 문자열을 코드 곳곳에 직접 적으면
///   오타 하나로 다른 컬렉션을 읽게 되고 추적이 어렵다.
/// - 한 곳에서 관리하면 이름을 바꿔도 안전하다.
class AppConstants {
  AppConstants._();

  // ===== Firestore 컬렉션 이름 =====
  /// 유저 비공개 원장 문서가 저장되는 컬렉션(정확 birthDate/위치·재화·토큰·AI 캐시).
  static const String usersCollection = 'users';

  /// 다른 인증 사용자에게 공개되는 최소 프로필 컬렉션.
  /// 정확 birthDate/정확 위치/재화/토큰/AI 캐시는 절대 포함하지 않는다.
  static const String publicProfilesCollection = 'publicProfiles';

  /// (이후 마일스톤용) 매칭/좋아요 등 확장 컬렉션 예시.
  static const String matchesCollection = 'matches';
  static const String likesCollection = 'likes';

  // ===== Storage 경로 =====
  /// 프로필 사진이 올라가는 Storage 최상위 폴더.
  static const String profilePhotosPath = 'profile_photos';

  // ===== 앱 메타 =====
  static const String appName = 'Dating App';

  // ===== Firebase =====
  static const String functionsRegion = 'asia-northeast3';
}
