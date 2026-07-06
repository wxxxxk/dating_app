/// 라우트(화면 경로) 이름 상수.
///
/// 왜 문자열을 상수로 빼나:
/// - Navigator.pushNamed('/login') 처럼 문자열을 직접 쓰면 오타가 런타임에야 터진다.
/// - 상수로 모으면 자동완성이 되고, 경로를 바꿔도 한 곳만 수정하면 된다.
class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String signup = '/signup';
  static const String home = '/home';
}
