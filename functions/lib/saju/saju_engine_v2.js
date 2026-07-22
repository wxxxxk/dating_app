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
 * - 출생시간 미상: 시주를 계산하지 않고, 연주·월주도 임의 시각으로 확정하지 않는다.
 *   그날 전체 구간에서 값이 갈리면 timeDependent로 표시하고 비운다(Phase 5-2A).
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

// 천간·지지·오행 표는 Phase 5-3에서 saju_constants.js로 옮겼다.
// 십성·지장간·지지 관계 모듈이 같은 표를 공유해야 하기 때문이다.
// 기존 import 경로가 깨지지 않도록 여기서 그대로 re-export한다.
const {
  ELEMENT_KEYS,
  STEMS,
  BRANCHES,
  elementRelation,
  emptyElementCounts,
} = require('./saju_constants');

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

/** 특정 순간의 연주·월주를 구한다. 시각이 확정된 경우에만 쓴다. */
function yearAndMonthPillarsAt(instantUtc, calendarYear) {
  // 연주 — 입춘 경계. 입춘 이전이면 전년도 간지를 쓴다.
  const lichun = lichunUtc(calendarYear);
  const solarYear =
    instantUtc.getTime() >= lichun.getTime() ? calendarYear : calendarYear - 1;
  const yearPillar = pillarFromIndex(solarYear - 1984);
  const yearStemIdx = STEMS.findIndex((s) => s.korean === yearPillar.stem);

  // 월주 — 절기 경계(태양 황경 30° 간격).
  const monthBranchIdx = monthBranchIndexFromSunLon(sunApparentLongitude(instantUtc));
  const monthNo = (monthBranchIdx - 2 + 12) % 12;
  const monthStemIdx = (firstMonthStemIndex(yearStemIdx) + monthNo) % 10;

  return { yearPillar, monthPillar: buildPillar(monthStemIdx, monthBranchIdx) };
}

/** 오행 count를 센다. */
function countElements(pillars) {
  const counts = emptyElementCounts();
  for (const pillar of pillars) {
    counts[pillar.stemElement] += 1;
    counts[pillar.branchElement] += 1;
  }
  return counts;
}

/** 여러 후보 조합의 오행 count에서 min/max 범위를 만든다. */
function elementRange(countsList) {
  const range = {};
  for (const key of ELEMENT_KEYS) {
    const values = countsList.map((c) => c[key]);
    range[key] = { min: Math.min(...values), max: Math.max(...values) };
  }
  return range;
}

/**
 * 정규화된 출생정보로 사주 원국을 계산한다.
 *
 * [profile]은 birth_profile.js의 `parseBirthProfile`이 만든 값이다.
 *
 * 출생시간을 아는 경우(dateAndTime): 그 시각으로 4주를 모두 확정한다.
 *
 * 출생시간을 모르는 경우(dateOnly): **어떤 대표 시각도 고르지 않는다.**
 * Phase 5-2까지는 00:00을 대입했는데, 절입이 그날 도중에 일어나면 무조건
 * 절입 이전 기둥이 나와 틀렸다. 이제 그날 00:00:00과 23:59:59.999 두 끝에서
 * 계산해, 결과가 같으면 exact, 다르면 timeDependent로 표시하고 값을 비운다.
 * 후보 중 하나를 임의로 canonical로 고르지 않는다.
 */
function computeSajuChart(profile) {
  const { year, month, day, birthTimeKnown, birthTimeMinutes } = profile;

  // 일주 — 자정 경계이므로 날짜만으로 확정된다. 23시 출생도 그날의 일주다.
  const dayPillar = dayPillarFromDate(year, month, day);
  const dayStemIdx = STEMS.findIndex((s) => s.korean === dayPillar.stem);

  let yearPillar = null;
  let monthPillar = null;
  let yearPillarCandidates = [];
  let monthPillarCandidates = [];
  let yearStatus = 'exact';
  let monthStatus = 'exact';
  let hourPillar = null;

  if (birthTimeKnown) {
    const instantUtc = seoulWallClockToUtc(year, month, day, birthTimeMinutes);
    const at = yearAndMonthPillarsAt(instantUtc, year);
    yearPillar = at.yearPillar;
    monthPillar = at.monthPillar;
    yearPillarCandidates = [yearPillar];
    monthPillarCandidates = [monthPillar];

    const hourBranchIdx = hourBranchIndexFromHour(Math.floor(birthTimeMinutes / 60));
    hourPillar = buildPillar((dayStemIdx * 2 + hourBranchIdx) % 10, hourBranchIdx);
  } else {
    // 그 날짜의 Asia/Seoul 현지 시각 전체 구간을 평가한다.
    const startUtc = seoulWallClockToUtc(year, month, day, 0);
    const endUtc = new Date(
      seoulWallClockToUtc(year, month, day, 1439).getTime() + 59999,
    );
    const atStart = yearAndMonthPillarsAt(startUtc, year);
    const atEnd = yearAndMonthPillarsAt(endUtc, year);

    if (atStart.yearPillar.korean === atEnd.yearPillar.korean) {
      yearPillar = atStart.yearPillar;
      yearPillarCandidates = [atStart.yearPillar];
    } else {
      yearStatus = 'timeDependent';
      yearPillarCandidates = [atStart.yearPillar, atEnd.yearPillar];
    }

    if (atStart.monthPillar.korean === atEnd.monthPillar.korean) {
      monthPillar = atStart.monthPillar;
      monthPillarCandidates = [atStart.monthPillar];
    } else {
      monthStatus = 'timeDependent';
      monthPillarCandidates = [atStart.monthPillar, atEnd.monthPillar];
    }
  }

  const boundaryStatus = {
    yearPillar: yearStatus,
    monthPillar: monthStatus,
    dayPillar: 'exact',
    hourPillar: birthTimeKnown ? 'exact' : 'missing',
  };

  // 연주·월주가 모두 확정된 경우에만 단일 오행 분포를 낸다.
  const resolved = yearStatus === 'exact' && monthStatus === 'exact';
  let fiveElementBalance = null;
  let fiveElementBalanceRange = null;
  let fiveElementTotal = null;

  if (resolved) {
    const pillars = [yearPillar, monthPillar, dayPillar];
    if (hourPillar) pillars.push(hourPillar);
    fiveElementBalance = countElements(pillars);
    fiveElementTotal = pillars.length * 2;
  } else {
    // 가능한 조합 전부에서 min/max 범위만 제시한다.
    // 평균이나 중간값 같은 가짜 대표값을 만들지 않는다.
    const countsList = [];
    for (const y of yearPillarCandidates) {
      for (const m of monthPillarCandidates) {
        countsList.push(countElements([y, m, dayPillar]));
      }
    }
    fiveElementBalanceRange = elementRange(countsList);
    fiveElementTotal = 6;
  }

  return {
    calculationVersion: SAJU_CALCULATION_VERSION,
    conventionVersion: SAJU_CONVENTION_VERSION,
    precision: birthTimeKnown ? 'dateAndTime' : 'dateOnly',
    boundaryStatus,
    zodiac: zodiacFromDate(month, day),
    saju: {
      yearPillar,
      yearPillarCandidates,
      monthPillar,
      monthPillarCandidates,
      dayPillar,
      hourPillar,
      dayMaster: dayPillar.stem,
      primaryElement: STEMS[dayStemIdx].element,
      // 확정된 경우에만 count를 낸다. AI가 오행 분포를 다시 세지 않게 하려는 값이며,
      // 불확실할 때는 null로 두고 range만 제공한다.
      fiveElementBalance,
      fiveElementBalanceRange,
      fiveElementTotal,
    },
  };
}

/** 절기 경계 때문에 확정하지 못한 항목이 있는지. */
function hasBoundaryUncertainty(chart) {
  return (
    chart.boundaryStatus.yearPillar === 'timeDependent' ||
    chart.boundaryStatus.monthPillar === 'timeDependent'
  );
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
 * raw 생년월일·시각·UID·나이는 절대 포함하지 않는다.
 *
 * **확정된 값만 넣는다.** 절기 경계 때문에 갈리는 연주·월주는 null로 두고
 * 후보 배열도 넣지 않는다 — 후보를 주면 모델이 그중 하나를 고르거나 섞어서
 * 단정할 위험이 있기 때문이다. 오행 분포도 확정된 경우에만 넘긴다.
 */
function buildEvidencePayload(chart) {
  const { saju, boundaryStatus } = chart;
  const yearUncertain = boundaryStatus.yearPillar === 'timeDependent';
  const monthUncertain = boundaryStatus.monthPillar === 'timeDependent';

  return {
    precision: chart.precision,
    missingBirthTime: chart.precision === 'dateOnly',
    boundaryUncertainty: {
      yearPillar: yearUncertain,
      monthPillar: monthUncertain,
    },
    zodiac: chart.zodiac,
    yearPillar: yearUncertain ? null : saju.yearPillar.korean,
    monthPillar: monthUncertain ? null : saju.monthPillar.korean,
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
  ELEMENT_KEYS,
  elementRelation,
  hasBoundaryUncertainty,
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
