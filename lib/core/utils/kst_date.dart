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

/// KST 달력상의 하루. **절대 시각이 아니다.**
///
/// naive `DateTime`으로 날짜를 들고 다니면, 그 값을 다시 `kstDateKey()`에
/// 넘길 때 기기 시간대를 거쳐 UTC로 해석되고 거기에 +9가 또 붙는다.
/// UTC+10 이상 기기에서는 하루 전 key가 나온다. 그래서 달력 날짜는 별도
/// 타입으로 분리하고, 덧셈·뺄셈은 UTC 달력 위에서만 한다.
class KstCalendarDate {
  final int year;
  final int month;
  final int day;

  const KstCalendarDate(this.year, this.month, this.day);

  /// 절대 시각 → KST 달력 날짜. 이 변환은 한 번만 일어난다.
  factory KstCalendarDate.fromInstant(DateTime instant) {
    final kst = instant.toUtc().add(kstOffset);
    return KstCalendarDate(kst.year, kst.month, kst.day);
  }

  /// `YYYY-MM-DD`. 필드에서 직접 조립한다(시간대를 거치지 않는다).
  String get dateKey =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// UI 포맷용 값. 기기 시간대와 무관하도록 UTC date-only로 준다.
  DateTime get utcCalendarValue => DateTime.utc(year, month, day);

  /// 달력 arithmetic은 UTC 위에서만 한다. 월말·연말·윤년이 자동으로 맞는다.
  KstCalendarDate addDays(int days) {
    final moved = DateTime.utc(year, month, day).add(Duration(days: days));
    return KstCalendarDate(moved.year, moved.month, moved.day);
  }

  KstCalendarDate subtractDays(int days) => addDays(-days);

  @override
  bool operator ==(Object other) =>
      other is KstCalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => dateKey;
}

/// 오늘부터 과거 방향으로 [count]개의 KST 달력 날짜.
///
/// 최근 7일 기록처럼 "오늘 → 어제 → …" 목록을 만들 때 쓴다.
/// 기기 시간대와 무관하다.
List<KstCalendarDate> kstDatesBackwards(DateTime instant, int count) {
  final today = KstCalendarDate.fromInstant(instant);
  return List.generate(count, (index) => today.subtractDays(index));
}
