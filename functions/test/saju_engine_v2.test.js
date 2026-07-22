'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  computeSajuChart,
  buildEvidencePayload,
  legacyAttrsFromChart,
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
  assert.equal(chart.calculationVersion, 2);
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
