/// 앱 전역의 KST(Asia/Seoul) 날짜 계산.
///
/// 서버는 `seoulDateKey()`로 Asia/Seoul 기준 날짜를 정하는데, 클라이언트는
/// `DateTime.now()`(기기 로컬 시간)로 dateKey를 만들고 있었다. 기기 시간대가
/// KST가 아니면 두 값이 어긋나, 클라이언트가 **다른 날짜 문서를 읽거나 쓰게**
/// 된다. 자정 근처에서는 KST 기기에서도 어긋난다.
///
/// 한국은 1988년 이후 서머타임이 없어 항상 UTC+9다. "오늘"만 다루므로 고정
/// 오프셋으로 충분하며, 9시간 계산을 여기 한 곳에만 둔다.
library;

const Duration kstOffset = Duration(hours: 9);

/// KST 기준 날짜 key. `YYYY-MM-DD`.
String kstDateKey(DateTime instant) {
  final kst = instant.toUtc().add(kstOffset);
  final month = kst.month.toString().padLeft(2, '0');
  final day = kst.day.toString().padLeft(2, '0');
  return '${kst.year}-$month-$day';
}

/// KST 기준 오늘의 자정(날짜만). 날짜 목록을 만들 때 쓴다.
///
/// 반환값은 "KST 달력상의 연·월·일"을 담은 naive DateTime이다. 로컬 시간대로
/// 해석하지 말고 날짜 계산에만 쓴다.
DateTime kstDateOnly(DateTime instant) {
  final kst = instant.toUtc().add(kstOffset);
  return DateTime(kst.year, kst.month, kst.day);
}
