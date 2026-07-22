'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  computeSajuChart,
  buildEvidencePayload,
  legacyAttrsFromChart,
  hasBoundaryUncertainty,
  dayPillarFromDate,
  hourBranchIndexFromHour,
  BRANCHES,
} = require('../lib/saju/saju_engine_v2');
const { seoulOffsetMinutes } = require('../lib/saju/solar_terms');

const parity = require('./fixtures/saju_engine_parity_v2.json');

// Phase 5-2 — 서버 사주 엔진.
//
// 서버가 source of truth가 되므로, Flutter가 쓰는 `saju` 패키지와 결과가
// 어긋나면 안 된다. fixture는 그 패키지에서 뽑은 값이며 네트워크를 쓰지 않는다.

function input(year, month, day, minutes) {
  return {
    year,
    month,
    day,
    birthTimeKnown: minutes !== null,
    birthTimeMinutes: minutes,
  };
}

// Phase 5-2A: 서버 황경은 VSOP87 절단판, Flutter `saju` 패키지는 Meeus 저정밀 해라
// 절입 전후 약 ±7분 구간에서는 결과가 갈릴 수 있다. parity fixture는 그 구간을
// 피한 표본이며, 여기서 어긋나면 경계와 무관한 퇴행이다.
test('Dart saju 패키지와 4주 전체가 일치한다 (parity fixture)', () => {
  const mismatches = [];
  for (const row of parity) {
    const [y, mo, d, h, mi] = row.input;
    const chart = computeSajuChart(input(y, mo, d, h * 60 + mi));
    const got = [
      chart.saju.yearPillar.korean,
      chart.saju.monthPillar.korean,
      chart.saju.dayPillar.korean,
      chart.saju.hourPillar.korean,
    ].join('/');
    const want = [row.year, row.month, row.day, row.hour].join('/');
    if (got !== want) {
      mismatches.push(`case=${row.input.join('-')} expected=${want} actual=${got}`);
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('parity fixture가 경계 사례를 실제로 담고 있다', () => {
  assert.ok(parity.length >= 30);
  const hours = new Set(parity.map((r) => `${r.input[3]}:${r.input[4]}`));
  for (const needed of ['0:0', '0:59', '1:0', '22:59', '23:0', '23:59']) {
    assert.ok(hours.has(needed), `시각 경계 ${needed} case가 없다`);
  }
});

test('출생시간을 모르면 시주가 null이고 precision이 dateOnly다', () => {
  const chart = computeSajuChart(input(1995, 2, 4, null));
  assert.equal(chart.precision, 'dateOnly');
  assert.equal(chart.saju.hourPillar, null);
  assert.equal(chart.saju.fiveElementTotal, 6);
});

test('출생시간을 모를 때 정오를 대입하지 않는다', () => {
  // 정오를 대입했다면 12:00 입력과 결과가 같아야 한다. 달라야 정상이다.
  const unknown = computeSajuChart(input(1995, 2, 4, null));
  const noon = computeSajuChart(input(1995, 2, 4, 12 * 60));
  assert.equal(unknown.saju.hourPillar, null);
  assert.notEqual(noon.saju.hourPillar, null);
  assert.equal(unknown.precision, 'dateOnly');
  assert.equal(noon.precision, 'dateAndTime');
});

test('시지 경계가 명세와 일치한다', () => {
  const expected = [
    [0, '자'],
    [0.59, '자'],
    [1, '축'],
    [2, '축'],
    [3, '인'],
    [5, '묘'],
    [7, '진'],
    [9, '사'],
    [11, '오'],
    [13, '미'],
    [15, '신'],
    [17, '유'],
    [19, '술'],
    [21, '해'],
    [22, '해'],
    [23, '자'],
  ];
  for (const [hour, branch] of expected) {
    const idx = hourBranchIndexFromHour(Math.floor(hour));
    assert.equal(BRANCHES[idx].korean, branch, `${hour}시`);
  }
});

test('23시 출생도 일주는 그날 것을 쓴다 — day boundary는 자정 유지', () => {
  const late = computeSajuChart(input(1996, 3, 15, 23 * 60 + 30));
  const sameDay = dayPillarFromDate(1996, 3, 15);
  const nextDay = dayPillarFromDate(1996, 3, 16);
  assert.equal(late.saju.dayPillar.korean, sameDay.korean);
  assert.notEqual(late.saju.dayPillar.korean, nextDay.korean);
  // 시지는 자시다.
  assert.equal(late.saju.hourPillar.branch, '자');
});

test('입춘 경계에서 연주가 갈린다', () => {
  const before = computeSajuChart(input(1995, 2, 3, 12 * 60));
  const after = computeSajuChart(input(1995, 2, 5, 12 * 60));
  assert.notEqual(before.saju.yearPillar.korean, after.saju.yearPillar.korean);
});

test('오행 분포는 결정론적이고 글자 수와 합이 맞는다', () => {
  const known = computeSajuChart(input(1990, 1, 15, 455));
  const sumKnown = Object.values(known.saju.fiveElementBalance).reduce((a, b) => a + b, 0);
  assert.equal(sumKnown, 8);
  assert.equal(known.saju.fiveElementTotal, 8);

  const unknown = computeSajuChart(input(1990, 1, 15, null));
  const sumUnknown = Object.values(unknown.saju.fiveElementBalance).reduce(
    (a, b) => a + b,
    0,
  );
  assert.equal(sumUnknown, 6);

  // 같은 입력은 항상 같은 결과.
  assert.deepEqual(
    computeSajuChart(input(1990, 1, 15, 455)).saju.fiveElementBalance,
    known.saju.fiveElementBalance,
  );
});

test('한국 표준시의 역사적 offset을 반영한다', () => {
  // 1954~1961 UTC+8:30, 1987~1988 서머타임 UTC+10:00.
  assert.equal(seoulOffsetMinutes(new Date('1955-06-01T00:00:00Z')), 570);
  assert.equal(seoulOffsetMinutes(new Date('1988-06-01T00:00:00Z')), 600);
  assert.equal(seoulOffsetMinutes(new Date('1995-02-04T00:00:00Z')), 540);
});

test('버전 metadata가 결과에 포함된다', () => {
  const chart = computeSajuChart(input(1995, 2, 4, null));
  // Phase 5-2A에서 계산 알고리즘이 바뀌어 calculationVersion만 3으로 올렸다.
  // 명리 convention은 그대로라 conventionVersion은 2를 유지한다.
  assert.equal(chart.calculationVersion, 3);
  assert.equal(chart.conventionVersion, 2);
});

test('evidence payload에 raw 생년월일·시각이 없다', () => {
  const chart = computeSajuChart(input(1995, 2, 4, 455));
  const evidence = buildEvidencePayload(chart);
  const serialized = JSON.stringify(evidence);
  assert.ok(!serialized.includes('1995'));
  assert.ok(!serialized.includes('455'));
  assert.ok(!('year' in evidence));
  assert.ok(!('birthTimeMinutes' in evidence));
  assert.equal(evidence.missingBirthTime, false);
  assert.equal(evidence.precision, 'dateAndTime');
  assert.equal(typeof evidence.hourPillar, 'string');
});

test('시간 미상 evidence는 missingBirthTime을 명시하고 시주를 비운다', () => {
  const evidence = buildEvidencePayload(computeSajuChart(input(1995, 2, 4, null)));
  assert.equal(evidence.missingBirthTime, true);
  assert.equal(evidence.hourPillar, null);
});

test('legacy attrs는 항상 서버 계산 결과에서 만들어진다', () => {
  const chart = computeSajuChart(input(1995, 2, 4, null));
  const attrs = legacyAttrsFromChart(chart);
  assert.equal(attrs.saju.dayMaster, chart.saju.dayPillar.stem);
  assert.equal(attrs.zodiac.sign, chart.zodiac.sign);
  assert.equal(attrs.zodiac.sign, '물병자리');
});

// ── Phase 5-2A: 출생시간 미상 경계 처리 ──────────────────────────────────

test('일반 날짜의 dateOnly는 연주·월주가 exact다', () => {
  const chart = computeSajuChart(input(1995, 6, 15, null));
  assert.equal(chart.boundaryStatus.yearPillar, 'exact');
  assert.equal(chart.boundaryStatus.monthPillar, 'exact');
  assert.equal(chart.boundaryStatus.dayPillar, 'exact');
  assert.equal(chart.boundaryStatus.hourPillar, 'missing');
  assert.ok(chart.saju.yearPillar);
  assert.ok(chart.saju.monthPillar);
  assert.equal(chart.saju.hourPillar, null);
  // 확정됐으므로 6글자 count가 나온다.
  assert.equal(chart.saju.fiveElementTotal, 6);
  assert.equal(
    Object.values(chart.saju.fiveElementBalance).reduce((a, b) => a + b, 0),
    6,
  );
  assert.equal(chart.saju.fiveElementBalanceRange, null);
});

test('일반 날짜의 dateOnly 결과에 00:00 대표값 흔적이 없다', () => {
  // 자정과 정오를 각각 알려진 시각으로 넣었을 때의 연/월주가 모두 같아야
  // "하루 전체가 같다"는 판정이 성립한다.
  const atMidnight = computeSajuChart(input(1995, 6, 15, 0));
  const atNoon = computeSajuChart(input(1995, 6, 15, 12 * 60));
  const dateOnly = computeSajuChart(input(1995, 6, 15, null));
  assert.equal(atMidnight.saju.monthPillar.korean, atNoon.saju.monthPillar.korean);
  assert.equal(dateOnly.saju.monthPillar.korean, atNoon.saju.monthPillar.korean);
});

test('입춘 당일 dateOnly는 연주·월주를 확정하지 않는다', () => {
  // 1995 입춘은 2/4 16:13 KST — 그날의 시작과 끝이 서로 다른 연주에 속한다.
  const chart = computeSajuChart(input(1995, 2, 4, null));

  assert.equal(chart.boundaryStatus.yearPillar, 'timeDependent');
  assert.equal(chart.boundaryStatus.monthPillar, 'timeDependent');
  assert.equal(chart.saju.yearPillar, null);
  assert.equal(chart.saju.monthPillar, null);
  assert.equal(chart.saju.yearPillarCandidates.length, 2);
  assert.equal(chart.saju.monthPillarCandidates.length, 2);
  // 일주는 자정 경계라 여전히 확정된다.
  assert.equal(chart.boundaryStatus.dayPillar, 'exact');
  assert.ok(chart.saju.dayPillar);
  assert.equal(typeof chart.saju.dayMaster, 'string');
});

test('입춘 당일 dateOnly는 후보 중 하나를 canonical로 고르지 않는다', () => {
  const chart = computeSajuChart(input(1995, 2, 4, null));
  const atMidnight = computeSajuChart(input(1995, 2, 4, 0));
  // 00:00 값이 기본값으로 노출되면 안 된다.
  assert.equal(chart.saju.yearPillar, null);
  assert.ok(
    chart.saju.yearPillarCandidates.some(
      (p) => p.korean === atMidnight.saju.yearPillar.korean,
    ),
    '후보에는 들어 있어야 한다',
  );
});

test('경계일 dateOnly는 오행을 확정하지 않고 범위만 준다', () => {
  const chart = computeSajuChart(input(1995, 2, 4, null));
  assert.equal(chart.saju.fiveElementBalance, null);
  assert.ok(chart.saju.fiveElementBalanceRange);
  for (const key of ['목', '화', '토', '금', '수']) {
    const r = chart.saju.fiveElementBalanceRange[key];
    assert.ok(Number.isInteger(r.min) && Number.isInteger(r.max));
    assert.ok(r.min <= r.max);
  }
  // 가짜 평균값을 만들지 않았는지 — 범위가 실제로 벌어진 원소가 있어야 한다.
  const widened = Object.values(chart.saju.fiveElementBalanceRange).filter(
    (r) => r.max > r.min,
  );
  assert.ok(widened.length > 0);
});

test('월주 절입 당일 dateOnly는 월주만 timeDependent다', () => {
  // 1995 경칩은 3/6 10:16 KST. 연주는 이미 입춘을 지나 확정돼 있다.
  const chart = computeSajuChart(input(1995, 3, 6, null));
  assert.equal(chart.boundaryStatus.yearPillar, 'exact');
  assert.equal(chart.boundaryStatus.monthPillar, 'timeDependent');
  assert.ok(chart.saju.yearPillar);
  assert.equal(chart.saju.monthPillar, null);
  assert.equal(chart.saju.monthPillarCandidates.length, 2);
  assert.equal(chart.saju.fiveElementBalance, null);
});

test('알려진 출생시간은 경계일에도 ambiguity가 없다', () => {
  const before = computeSajuChart(input(1995, 2, 4, 10 * 60));
  const after = computeSajuChart(input(1995, 2, 4, 20 * 60));
  for (const chart of [before, after]) {
    assert.equal(chart.boundaryStatus.yearPillar, 'exact');
    assert.equal(chart.boundaryStatus.monthPillar, 'exact');
    assert.equal(chart.boundaryStatus.hourPillar, 'exact');
    assert.ok(chart.saju.yearPillar);
    assert.ok(chart.saju.monthPillar);
    assert.equal(chart.saju.fiveElementTotal, 8);
    assert.equal(
      Object.values(chart.saju.fiveElementBalance).reduce((a, b) => a + b, 0),
      8,
    );
  }
  // 입춘(16:13)을 사이에 두므로 연주가 실제로 갈린다.
  assert.notEqual(
    before.saju.yearPillar.korean,
    after.saju.yearPillar.korean,
  );
});

test('hasBoundaryUncertainty가 경계일만 true다', () => {
  assert.equal(hasBoundaryUncertainty(computeSajuChart(input(1995, 2, 4, null))), true);
  assert.equal(hasBoundaryUncertainty(computeSajuChart(input(1995, 6, 15, null))), false);
  assert.equal(hasBoundaryUncertainty(computeSajuChart(input(1995, 2, 4, 600))), false);
});

test('AI evidence는 불확실한 기둥을 확정값으로 넘기지 않는다', () => {
  const evidence = buildEvidencePayload(computeSajuChart(input(1995, 2, 4, null)));
  assert.equal(evidence.yearPillar, null);
  assert.equal(evidence.monthPillar, null);
  assert.equal(evidence.boundaryUncertainty.yearPillar, true);
  assert.equal(evidence.boundaryUncertainty.monthPillar, true);
  assert.equal(evidence.fiveElementBalance, null);
  // 확정된 근거는 그대로 전달된다.
  assert.equal(typeof evidence.dayPillar, 'string');
  assert.equal(typeof evidence.dayMaster, 'string');
});

test('AI evidence에 후보 배열이 새어나가지 않는다', () => {
  // 후보를 주면 모델이 그중 하나를 골라 단정할 수 있다.
  const evidence = buildEvidencePayload(computeSajuChart(input(1995, 2, 4, null)));
  const serialized = JSON.stringify(evidence);
  assert.ok(!('yearPillarCandidates' in evidence));
  assert.ok(!('monthPillarCandidates' in evidence));
  assert.ok(!('fiveElementBalanceRange' in evidence));
  assert.ok(!serialized.includes('갑술'));
  assert.ok(!serialized.includes('을해'));
});

test('legacy attrs는 경계일에도 확정 가능한 값만 쓴다', () => {
  // zodiac·dayMaster·primaryElement는 날짜와 일주로 확정되므로 구버전 화면이 깨지지 않는다.
  const attrs = legacyAttrsFromChart(computeSajuChart(input(1995, 2, 4, null)));
  assert.equal(typeof attrs.zodiac.sign, 'string');
  assert.ok(attrs.zodiac.sign.length > 0);
  assert.equal(typeof attrs.saju.dayMaster, 'string');
  assert.equal(typeof attrs.saju.element, 'string');
  const serialized = JSON.stringify(attrs);
  assert.ok(!serialized.includes('null'));
});
