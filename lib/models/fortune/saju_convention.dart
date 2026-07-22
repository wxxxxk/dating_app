/// 사주 계산 convention 계약 (Phase 5-1).
///
/// 명리학에는 연주 경계(입춘/설날), 일주 경계(자정/자시 23시), 진태양시 보정
/// 여부처럼 **유파에 따라 갈리는** 규칙이 존재한다. 어느 하나가 절대 정답은
/// 아니므로, 제품이 무엇을 채택했는지를 코드에 명시하고 버전으로 관리한다.
///
/// 이 파일은 계산을 하지 않는다. 현재 구현이 *실제로* 따르고 있는 규칙
/// ([currentConvention])과, Phase 5-2에서 지향할 규칙([recommendedConvention])을
/// 분리해 감사 가능하게 만드는 것이 목적이다.
library;

/// 입력 달력 종류 지원 범위.
enum CalendarConversion {
  /// 양력만 입력받는다.
  solar,

  /// 음력 입력을 받는다(윤달 플래그 필요 여부는 별도).
  lunar,

  /// 양력·음력 모두 입력받는다.
  both,
}

/// 시간대 처리 정책.
enum TimezonePolicy {
  /// Asia/Seoul을 암묵적으로 가정한다. 해외 출생은 지원하지 않는다.
  asiaSeoul,

  /// 사용자가 IANA timezone을 명시한다.
  explicitIana,

  /// 시간대 개념 자체를 다루지 않는다.
  unsupported,
}

/// 연주(年柱)가 바뀌는 경계.
enum YearPillarBoundary {
  /// 양력 1월 1일.
  januaryFirst,

  /// 음력 설날.
  lunarNewYear,

  /// 입춘(태양 황경 315°).
  ipchun,
}

/// 월주(月柱)가 바뀌는 경계.
enum MonthPillarBoundary {
  /// 양력 월.
  gregorianMonth,

  /// 음력 월.
  lunarMonth,

  /// 절기(태양 황경 30° 간격).
  solarTerms,
}

/// 일주(日柱)가 바뀌는 경계.
enum DayPillarBoundary {
  /// 자정 00:00. 현대 표준.
  midnight,

  /// 자시 시작 23:00. 전통 방식.
  ziHour23,
}

/// 출생시간을 모를 때의 처리.
enum UnknownBirthTimePolicy {
  /// 시주를 계산하지 않고 비워 둔다.
  omitHourPillar,

  /// 임의 시각 대입을 금지한다.
  estimateNotAllowed,

  /// 임의 시각(정오 등)을 대입한다. **권장하지 않는다.**
  substituteFixedTime,
}

/// 진태양시(경도) 보정 여부.
enum SolarTimeCorrection {
  /// 보정하지 않는다.
  disabled,

  /// 출생지 경도로 보정한다.
  longitudeBased,

  /// 보정 개념을 다루지 않는다.
  unsupported,
}

/// 하나의 계산 convention 묶음.
class SajuConvention {
  /// convention 자체의 버전. 규칙이 바뀌면 올린다.
  final int version;

  final CalendarConversion calendarConversion;

  /// 음력 입력 시 윤달 플래그를 필수로 받는지.
  final bool lunarLeapMonthRequired;

  final TimezonePolicy timezonePolicy;
  final YearPillarBoundary yearPillarBoundary;
  final MonthPillarBoundary monthPillarBoundary;
  final DayPillarBoundary dayPillarBoundary;
  final UnknownBirthTimePolicy unknownBirthTimePolicy;
  final SolarTimeCorrection solarTimeCorrection;

  const SajuConvention({
    required this.version,
    required this.calendarConversion,
    required this.lunarLeapMonthRequired,
    required this.timezonePolicy,
    required this.yearPillarBoundary,
    required this.monthPillarBoundary,
    required this.dayPillarBoundary,
    required this.unknownBirthTimePolicy,
    required this.solarTimeCorrection,
  });
}

/// 현재 앱이 **실제로** 따르고 있는 규칙 (Phase 5-1 코드 감사 결과).
///
/// 근거:
/// - 입력: `basic_info_step.dart`의 `showDatePicker` — 양력 날짜만, 시간·음력 없음
/// - 시간대: `FortuneCalculator.getOhaengBalance`가 `Asia/Seoul` 고정,
///   서버 `datePartsInSeoul()`도 동일
/// - 연/월주: `saju` 패키지 `yearPillar`(입춘) / `monthPillar`(태양 황경)
/// - 일주: `saju` 패키지 `standardPreset` — `DayBoundary.midnight`
/// - 출생시간: 수집하지 않으면서 연/월주 계산에 **정오 12:00을 대입**한다
///   (`getOhaengBalance`). 시주는 화면에 노출하지 않는다.
/// - 진태양시: 경도 기본값이 `tzOffsetHours * 15 = 135°`라 보정량이 0이다.
const SajuConvention currentConvention = SajuConvention(
  version: 1,
  calendarConversion: CalendarConversion.solar,
  lunarLeapMonthRequired: false,
  timezonePolicy: TimezonePolicy.asiaSeoul,
  yearPillarBoundary: YearPillarBoundary.ipchun,
  monthPillarBoundary: MonthPillarBoundary.solarTerms,
  dayPillarBoundary: DayPillarBoundary.midnight,
  // 출생시간을 받지 않으면서도 정오를 대입한다 — Phase 5-2 수정 대상.
  unknownBirthTimePolicy: UnknownBirthTimePolicy.substituteFixedTime,
  solarTimeCorrection: SolarTimeCorrection.disabled,
);

/// Phase 5-2에서 지향하는 규칙 **제안**.
///
/// 아직 제품 결정이 내려지지 않았다. 특히 다음은 사용자 확정이 필요하다:
/// - 일주 경계를 자정으로 둘지 자시(23:00)로 둘지
/// - 진태양시 보정을 켤지
/// 여기 적힌 값은 "현재 구현과 같은 쪽"을 기본으로 두되, 출생시간 임의 대입만
/// 명시적으로 금지한 것이다.
const SajuConvention recommendedConvention = SajuConvention(
  version: 2,
  calendarConversion: CalendarConversion.both,
  lunarLeapMonthRequired: true,
  timezonePolicy: TimezonePolicy.asiaSeoul,
  yearPillarBoundary: YearPillarBoundary.ipchun,
  monthPillarBoundary: MonthPillarBoundary.solarTerms,
  dayPillarBoundary: DayPillarBoundary.midnight,
  unknownBirthTimePolicy: UnknownBirthTimePolicy.estimateNotAllowed,
  solarTimeCorrection: SolarTimeCorrection.disabled,
);
