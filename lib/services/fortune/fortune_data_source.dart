import '../../models/fortune_model.dart';

/// 운세 상태 컨트롤러가 필요로 하는 데이터 조회의 최소 계약.
///
/// [FortuneService]가 이걸 구현한다. 컨트롤러는 이 인터페이스에만 의존해서,
/// 테스트가 Firebase 없이 가짜 구현을 넣을 수 있다.
abstract interface class FortuneDataSource {
  /// 오늘(KST)의 애정운. [now]로 어느 날짜 문서를 볼지 호출자가 고정한다.
  Future<DailyFortune> getDailyFortune({required String uid, DateTime? now});

  /// 최근 [days]일 기록을 날짜 역순(오늘 → 과거)으로 읽는다. 문서 읽기만 한다.
  Future<List<FortuneHistoryEntry>> getFortuneHistory({
    required String uid,
    int days,
    DateTime? now,
  });
}

/// 운세 조회 실패. raw Firebase 코드·메시지는 이 밖으로 나가지 않는다.
class FortuneFailure implements Exception {
  final String code;

  const FortuneFailure(this.code);

  static const _allowedCodes = {
    'unauthenticated',
    'permission-denied',
    'failed-precondition',
    'resource-exhausted',
    'unavailable',
    'deadline-exceeded',
    'internal',
    'unknown',
  };

  static String safeCode(String code) =>
      _allowedCodes.contains(code) ? code : 'unknown';
}
