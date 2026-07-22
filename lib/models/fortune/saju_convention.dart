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

/// Phase 5-1 감사 시점(= Phase 5-2 이전)에 앱이 따르던 규칙. **역사 기록용**이다.
///
/// 이 시점의 알려진 결함: 출생시간을 수집하지 않으면서 연/월주 계산에
/// 정오 12:00을 대입했다. Phase 5-2에서 제거됐다.
const SajuConvention legacyConventionV1 = SajuConvention(
  version: 1,
  calendarConversion: CalendarConversion.solar,
  lunarLeapMonthRequired: false,
  timezonePolicy: TimezonePolicy.asiaSeoul,
  yearPillarBoundary: YearPillarBoundary.ipchun,
  monthPillarBoundary: MonthPillarBoundary.solarTerms,
  dayPillarBoundary: DayPillarBoundary.midnight,
  unknownBirthTimePolicy: UnknownBirthTimePolicy.substituteFixedTime,
  solarTimeCorrection: SolarTimeCorrection.disabled,
);

/// 제품이 **채택한** 계산 규칙 (Phase 5-2, conventionVersion 2).
///
/// 서버 `functions/lib/saju/birth_profile.js`의 `SAJU_CONVENTION_VERSION`과
/// 같은 값을 가리킨다. 서버가 계산의 source of truth이고, 이 상수는 앱이 같은
/// 규칙을 따르고 있음을 코드로 고정하기 위한 것이다.
///
/// 논쟁적인 항목(일주 경계 자정/자시, 진태양시 보정)은 이번에 바꾸지 않았다 —
/// 현재 구현과 같은 쪽을 명시적으로 채택했을 뿐이며, 바꾸려면 버전을 올린다.
///
/// 근거:
/// - 입력: 회원가입에서 양력 생년월일 + 출생시간(알아요/몰라요)을 받는다
/// - 시간대: Asia/Seoul 고정. 서버는 역사적 offset(1954~61, 1987~88)까지 반영
/// - 연주: 입춘 / 월주: 절기(태양 황경) / 일주: 자정 00:00
/// - 출생시간 미상: 시주를 계산하지 않는다. 임의 시각을 대입하지 않는다
/// - 진태양시: 보정하지 않는다
const SajuConvention currentConvention = SajuConvention(
  version: 2,
  calendarConversion: CalendarConversion.solar,
  lunarLeapMonthRequired: false,
  timezonePolicy: TimezonePolicy.asiaSeoul,
  yearPillarBoundary: YearPillarBoundary.ipchun,
  monthPillarBoundary: MonthPillarBoundary.solarTerms,
  dayPillarBoundary: DayPillarBoundary.midnight,
  unknownBirthTimePolicy: UnknownBirthTimePolicy.omitHourPillar,
  solarTimeCorrection: SolarTimeCorrection.disabled,
);

/// 향후 지원을 검토 중인 규칙. **아직 채택하지 않았다.**
///
/// 음력·윤달 입력은 별도 Phase로 진행한다. 여기 적혀 있다는 이유로 UI나 계산이
/// 음력을 지원하는 것처럼 동작해서는 안 된다.
const SajuConvention proposedLunarConvention = SajuConvention(
  version: 3,
  calendarConversion: CalendarConversion.both,
  lunarLeapMonthRequired: true,
  timezonePolicy: TimezonePolicy.asiaSeoul,
  yearPillarBoundary: YearPillarBoundary.ipchun,
  monthPillarBoundary: MonthPillarBoundary.solarTerms,
  dayPillarBoundary: DayPillarBoundary.midnight,
  unknownBirthTimePolicy: UnknownBirthTimePolicy.omitHourPillar,
  solarTimeCorrection: SolarTimeCorrection.disabled,
);
