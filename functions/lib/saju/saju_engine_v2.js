'use strict';

/**
 * 결정론적 사주 계산 엔진 v2 — Phase 5-2.
 *
 * 서버가 사주 계산의 source of truth다. 클라이언트가 보낸 계산 결과는 쓰지 않고,
 * users/{uid} 비공개 문서의 출생정보만 근거로 여기서 계산한다.
 *
 * convention (conventionVersion 2):
 * - 달력: 양력만
 * - 시간대: Asia/Seoul (역사적 offset 반영)
 * - 연주: 입춘 경계
 * - 월주: 절기(태양 황경) 경계
 * - 일주: 자정 00:00 경계  ← 23시 출생도 그날의 일주를 쓴다
 * - 진태양시 보정: 미적용
 * - 출생시간 미상: 시주를 계산하지 않는다. **임의 시각을 대입하지 않는다.**
 *
 * Flutter의 `saju` 패키지와 같은 알고리즘이며, parity는 고정 fixture로 검증한다.
 * 지장간·십성·합충형파해처럼 아직 구현 근거가 없는 값은 반환하지 않는다.
 */

const {
  seoulWallClockToUtc,
  sunApparentLongitude,
  lichunUtc,
  monthBranchIndexFromSunLon,
} = require('./solar_terms');
const {
  SAJU_CALCULATION_VERSION,
  SAJU_CONVENTION_VERSION,
} = require('./birth_profile');

/** 천간 10개. index는 60갑자 계산에 그대로 쓰인다. */
const STEMS = Object.freeze([
  { korean: '갑', hanja: '甲', element: '목', yin: false },
  { korean: '을', hanja: '乙', element: '목', yin: true },
  { korean: '병', hanja: '丙', element: '화', yin: false },
  { korean: '정', hanja: '丁', element: '화', yin: true },
  { korean: '무', hanja: '戊', element: '토', yin: false },
  { korean: '기', hanja: '己', element: '토', yin: true },
  { korean: '경', hanja: '庚', element: '금', yin: false },
  { korean: '신', hanja: '辛', element: '금', yin: true },
  { korean: '임', hanja: '壬', element: '수', yin: false },
  { korean: '계', hanja: '癸', element: '수', yin: true },
]);

/** 지지 12개. 대표 오행만 쓰고 지장간(藏干) 세부 가중치는 반영하지 않는다. */
const BRANCHES = Object.freeze([
  { korean: '자', hanja: '子', element: '수' },
  { korean: '축', hanja: '丑', element: '토' },
  { korean: '인', hanja: '寅', element: '목' },
  { korean: '묘', hanja: '卯', element: '목' },
  { korean: '진', hanja: '辰', element: '토' },
  { korean: '사', hanja: '巳', element: '화' },
  { korean: '오', hanja: '午', element: '화' },
  { korean: '미', hanja: '未', element: '토' },
  { korean: '신', hanja: '申', element: '금' },
  { korean: '유', hanja: '酉', element: '금' },
  { korean: '술', hanja: '戌', element: '토' },
  { korean: '해', hanja: '亥', element: '수' },
]);

/** 오행 순서를 고정해 동점일 때도 결과가 항상 같게 만든다. */
const ELEMENT_KEYS = Object.freeze(['목', '화', '토', '금', '수']);

const ZODIAC_BOUNDARIES = Object.freeze([
  { month: 1, day: 20, sign: '물병자리', element: '공기' },
  { month: 2, day: 19, sign: '물고기자리', element: '물' },
  { month: 3, day: 21, sign: '양자리', element: '불' },
  { month: 4, day: 20, sign: '황소자리', element: '흙' },
  { month: 5, day: 21, sign: '쌍둥이자리', element: '공기' },
  { month: 6, day: 22, sign: '게자리', element: '물' },
  { month: 7, day: 23, sign: '사자자리', element: '불' },
  { month: 8, day: 23, sign: '처녀자리', element: '흙' },
  { month: 9, day: 23, sign: '천칭자리', element: '공기' },
  { month: 10, day: 23, sign: '전갈자리', element: '물' },
  { month: 11, day: 22, sign: '사수자리', element: '불' },
  { month: 12, day: 22, sign: '염소자리', element: '흙' },
]);

/** 율리우스 적일. Dart `saju` 패키지 jdnFromDate와 동일하다. */
function jdnFromDate(year, month, day) {
  let y = year;
  let m = month;
  if (m <= 2) {
    y -= 1;
    m += 12;
  }
  const a = Math.floor(y / 100);
  const b = 2 - a + Math.floor(a / 4);
  const jd =
    Math.floor(365.25 * (y + 4716)) + Math.floor(30.6001 * (m + 1)) + day + b - 1524.5;
  return Math.round(jd);
}

function pillarFromIndex(idx60) {
  const i = ((idx60 % 60) + 60) % 60;
  return buildPillar(i % 10, i % 12);
}

function buildPillar(stemIdx, branchIdx) {
  const stem = STEMS[((stemIdx % 10) + 10) % 10];
  const branch = BRANCHES[((branchIdx % 12) + 12) % 12];
  return {
    korean: `${stem.korean}${branch.korean}`,
    hanja: `${stem.hanja}${branch.hanja}`,
    stem: stem.korean,
    branch: branch.korean,
    stemElement: stem.element,
    branchElement: branch.element,
  };
}

/** 일주(日柱). 자정 경계이므로 날짜만으로 정해진다. */
function dayPillarFromDate(year, month, day) {
  return pillarFromIndex(jdnFromDate(year, month, day) - 11);
}

/** 연간(年干)에 따라 그 해 첫 달(인월)의 월간이 정해진다 — 오호둔(五虎遁). */
function firstMonthStemIndex(yearStemIdx) {
  const map = { 0: 2, 5: 2, 1: 4, 6: 4, 2: 6, 7: 6, 3: 8, 8: 8, 4: 0, 9: 0 };
  return map[yearStemIdx] ?? 0;
}

/** 시각(0~23)에서 시지(時支) index. 23시와 0시는 모두 자시다. */
function hourBranchIndexFromHour(hour) {
  return (Math.floor((hour + 1) / 2) % 12 + 12) % 12;
}

/**
 * 정규화된 출생정보로 사주 원국을 계산한다.
 *
 * [profile]은 birth_profile.js의 `parseBirthProfile`이 만든 값이다.
 * 출생시간을 모르면 연/월주 계산 기준 시각으로 **정오를 대입하지 않고**
 * 그날 자정(00:00)을 쓴다. 자정은 임의 추정이 아니라 "날짜만 안다"는 입력을
 * 그대로 표현한 값이며, 결과의 precision을 dateOnly로 명시해 시주를 비운다.
 */
function computeSajuChart(profile) {
  const { year, month, day, birthTimeKnown, birthTimeMinutes } = profile;
  const minutesOfDay = birthTimeKnown ? birthTimeMinutes : 0;
  const instantUtc = seoulWallClockToUtc(year, month, day, minutesOfDay);

  // 연주 — 입춘 경계. 입춘 이전이면 전년도 간지를 쓴다.
  const lichun = lichunUtc(year);
  const solarYear = instantUtc.getTime() >= lichun.getTime() ? year : year - 1;
  const yearPillar = pillarFromIndex(solarYear - 1984);
  const yearStemIdx = STEMS.findIndex((s) => s.korean === yearPillar.stem);

  // 월주 — 절기 경계(태양 황경 30° 간격).
  const sunLon = sunApparentLongitude(instantUtc);
  const monthBranchIdx = monthBranchIndexFromSunLon(sunLon);
  const monthNo = (monthBranchIdx - 2 + 12) % 12;
  const monthStemIdx = (firstMonthStemIndex(yearStemIdx) + monthNo) % 10;
  const monthPillar = buildPillar(monthStemIdx, monthBranchIdx);

  // 일주 — 자정 경계. 23시 출생도 그날의 일주를 쓴다.
  const dayPillar = dayPillarFromDate(year, month, day);
  const dayStemIdx = STEMS.findIndex((s) => s.korean === dayPillar.stem);

  // 시주 — 출생시간을 아는 경우에만 계산한다.
  let hourPillar = null;
  if (birthTimeKnown) {
    const hourBranchIdx = hourBranchIndexFromHour(Math.floor(birthTimeMinutes / 60));
    hourPillar = buildPillar((dayStemIdx * 2 + hourBranchIdx) % 10, hourBranchIdx);
  }

  const pillars = [yearPillar, monthPillar, dayPillar];
  if (hourPillar) pillars.push(hourPillar);

  const counts = Object.fromEntries(ELEMENT_KEYS.map((k) => [k, 0]));
  for (const pillar of pillars) {
    counts[pillar.stemElement] += 1;
    counts[pillar.branchElement] += 1;
  }

  const dayMaster = dayPillar.stem;
  const dayMasterElement = STEMS[dayStemIdx].element;

  return {
    calculationVersion: SAJU_CALCULATION_VERSION,
    conventionVersion: SAJU_CONVENTION_VERSION,
    precision: birthTimeKnown ? 'dateAndTime' : 'dateOnly',
    zodiac: zodiacFromDate(month, day),
    saju: {
      yearPillar,
      monthPillar,
      dayPillar,
      hourPillar,
      dayMaster,
      primaryElement: dayMasterElement,
      // 글자 수가 6(시주 없음) 또는 8(시주 있음)이라 분모가 달라진다.
      // AI가 오행 분포를 임의로 계산하지 않도록 count를 그대로 넘긴다.
      fiveElementBalance: counts,
      fiveElementTotal: pillars.length * 2,
    },
  };
}

/** 생년월일의 월/일로 서양 별자리와 4원소를 구한다. */
function zodiacFromDate(month, day) {
  for (let i = ZODIAC_BOUNDARIES.length - 1; i >= 0; i -= 1) {
    const boundary = ZODIAC_BOUNDARIES[i];
    if (month > boundary.month || (month === boundary.month && day >= boundary.day)) {
      return { sign: boundary.sign, element: boundary.element };
    }
  }
  return { sign: '염소자리', element: '흙' };
}

/**
 * AI 프롬프트에 넣을 근거 payload.
 *
 * raw 생년월일·시각·UID·나이는 절대 포함하지 않는다. AI는 여기 담긴 값만
 * 해석해야 하며, 시각을 모를 때는 시주를 지어내지 못하도록 명시한다.
 */
function buildEvidencePayload(chart) {
  const { saju } = chart;
  return {
    precision: chart.precision,
    missingBirthTime: chart.precision === 'dateOnly',
    zodiac: chart.zodiac,
    yearPillar: saju.yearPillar.korean,
    monthPillar: saju.monthPillar.korean,
    dayPillar: saju.dayPillar.korean,
    hourPillar: saju.hourPillar ? saju.hourPillar.korean : null,
    dayMaster: saju.dayMaster,
    primaryElement: saju.primaryElement,
    fiveElementBalance: saju.fiveElementBalance,
  };
}

/**
 * 구버전 앱(`attrs`를 보내던 클라이언트)과 기존 프롬프트가 기대하는 형태.
 * 값은 항상 서버 계산 결과에서 만든다.
 */
function legacyAttrsFromChart(chart) {
  return {
    zodiac: { sign: chart.zodiac.sign, element: chart.zodiac.element },
    saju: { dayMaster: chart.saju.dayMaster, element: chart.saju.primaryElement },
  };
}

module.exports = {
  STEMS,
  BRANCHES,
  ELEMENT_KEYS,
  ZODIAC_BOUNDARIES,
  jdnFromDate,
  pillarFromIndex,
  buildPillar,
  dayPillarFromDate,
  hourBranchIndexFromHour,
  firstMonthStemIndex,
  zodiacFromDate,
  computeSajuChart,
  buildEvidencePayload,
  legacyAttrsFromChart,
};
