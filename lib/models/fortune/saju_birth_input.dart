/// 사주 계산 입력 계약 (Phase 5-1).
///
/// 지금은 계산에 쓰이지 않는다 — golden fixture와 감사 테스트가 공유하는
/// 입력 타입이며, Phase 5-2의 서버 엔진이 따라야 할 형태를 고정하는 것이
/// 목적이다.
library;

/// 입력이 어디까지 정확한지. **모르는 값을 임의로 채우지 않기 위해** 존재한다.
enum SajuInputPrecision {
  /// 날짜만 안다. 시주를 계산하면 안 된다.
  dateOnly,

  /// 날짜와 시각을 안다(시간대는 앱 기본값 가정).
  dateAndTime,

  /// 날짜·시각·시간대를 모두 안다.
  dateTimeAndZone,
}

/// 입력 달력.
enum SajuCalendarType { solar, lunar }

/// 사주 계산 입력.
///
/// 불변 규칙:
/// - [birthTime]이 null이면 [precision]은 반드시 [SajuInputPrecision.dateOnly]다.
/// - [calendarType]이 lunar면 [lunarLeapMonth]는 null이 아니어야 한다
///   (윤달 여부를 모르면 음력 날짜가 하루가 아니라 한 달 단위로 어긋난다).
class SajuBirthInput {
  final SajuCalendarType calendarType;
  final int year;
  final int month;
  final int day;

  /// 'HH:mm' 또는 null(모름). null이면 시주를 계산하지 않는다.
  final String? birthTime;

  /// IANA timezone. 현재 제품은 'Asia/Seoul'만 정식 지원한다.
  final String timeZone;

  /// 음력 입력일 때 윤달 여부. 양력이면 null.
  final bool? lunarLeapMonth;

  const SajuBirthInput({
    required this.calendarType,
    required this.year,
    required this.month,
    required this.day,
    required this.birthTime,
    required this.timeZone,
    required this.lunarLeapMonth,
  });

  factory SajuBirthInput.fromMap(Map<String, dynamic> map) {
    return SajuBirthInput(
      calendarType: map['calendarType'] == 'lunar'
          ? SajuCalendarType.lunar
          : SajuCalendarType.solar,
      year: map['year'] as int,
      month: map['month'] as int,
      day: map['day'] as int,
      birthTime: map['birthTime'] as String?,
      timeZone: (map['timeZone'] as String?) ?? 'Asia/Seoul',
      lunarLeapMonth: map['lunarLeapMonth'] as bool?,
    );
  }

  /// 시각을 모르면 dateOnly. 아는 경우에도 시간대까지 아는지는 별도다.
  SajuInputPrecision get precision {
    if (birthTime == null) return SajuInputPrecision.dateOnly;
    return SajuInputPrecision.dateAndTime;
  }

  /// 입력 자체가 계약을 만족하는지. 달력상 실재하는 날짜인지는 별도 검증이다.
  bool get isWellFormed {
    if (calendarType == SajuCalendarType.lunar && lunarLeapMonth == null) {
      return false;
    }
    if (birthTime != null && !RegExp(r'^\d{2}:\d{2}$').hasMatch(birthTime!)) {
      return false;
    }
    return true;
  }

  /// 양력 그레고리력에 실재하는 날짜인지. 음력 입력에는 적용하지 않는다.
  bool get isRealSolarDate {
    if (calendarType != SajuCalendarType.solar) return false;
    if (month < 1 || month > 12 || day < 1) return false;
    final probe = DateTime(year, month, day);
    // DateTime은 2월 30일을 3월 2일로 넘겨버린다 — 되돌아온 값으로 확인한다.
    return probe.year == year && probe.month == month && probe.day == day;
  }
}
