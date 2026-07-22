'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  findTermUtc,
  lichunUtc,
  monthBranchIndexFromSunLon,
  sunApparentLongitude,
  seoulOffsetMinutes,
} = require('../lib/saju/solar_terms');
const { deltaTSeconds } = require('../lib/saju/solar_longitude_vsop');
const { BRANCHES, computeSajuChart } = require('../lib/saju/saju_engine_v2');

const fixture = require('./fixtures/solar_term_boundaries_v1.json');

// Phase 5-2A — 절기 경계 독립 정확도 검증.
//
// Flutter `saju` 패키지와의 parity(saju_engine_v2.test.js)와는 **별개**다.
// 여기서는 외부에 공표된 절입 시각과 대조해, 두 구현이 함께 틀리는 경우를 잡는다.
// 네트워크를 쓰지 않는다 — 기대값이 fixture에 고정돼 있다.

const MINUTE = 60000;
const TOLERANCE_MIN = fixture.metadata.toleranceMinutes;

/** 그 UTC 순간의 월지(月支) 한글. */
function monthBranchAt(dateUtc) {
  return BRANCHES[monthBranchIndexFromSunLon(sunApparentLongitude(dateUtc))].korean;
}

test('fixture 계약 — 12절입만, 6개 연도, 24개 이상', () => {
  assert.equal(fixture.schemaVersion, 1);
  const years = new Set(fixture.cases.map((c) => c.year));
  assert.ok(years.size >= 6, `연도가 ${years.size}개뿐이다`);
  assert.ok(fixture.cases.length >= 24);

  // 중기(우수·춘분·곡우 등)가 섞이면 월주 경계가 아닌 값으로 검증하게 된다.
  const allowed = new Set([
    '소한', '입춘', '경칩', '청명', '입하', '망종',
    '소서', '입추', '백로', '한로', '입동', '대설',
  ]);
  for (const c of fixture.cases) {
    assert.ok(allowed.has(c.term), `${c.term}은 절입이 아니다`);
  }
  // 입춘은 연주·월주 양쪽 경계다.
  assert.equal(fixture.cases.filter((c) => c.changesYearPillar).length, years.size);
});

test('fixture 계약 — 출처와 tolerance 근거가 남아 있다', () => {
  const source = fixture.metadata.source;
  assert.match(source.provenance, /secondary source citing/);
  assert.ok(source.urls.length >= 6);
  assert.ok(source.retrievedAt);
  assert.ok(fixture.metadata.toleranceRationale.length > 0);
});

test('fixture 계약 — 역사적 시간대 사례가 포함돼 있다', () => {
  // UTC+8:30 시기(1954~1961)와 서머타임 시기(1987~1988)가 각각 있어야
  // 시간대 변환까지 검증된다.
  assert.ok(
    fixture.cases.some((c) => c.officialUtcOffsetMinutes === 510),
    'UTC+8:30 시기 사례가 없다',
  );
  assert.ok(
    fixture.cases.some((c) => c.year === 1988),
    '서머타임 시기 사례가 없다',
  );
});

test('절입 시각이 공표값과 tolerance 안에서 일치한다', () => {
  const mismatches = [];
  for (const c of fixture.cases) {
    const officialMs = Date.parse(c.officialInstantUtc);
    // 태양 황경은 1년에 한 바퀴 돌므로 탐색 구간을 좁혀야 한다.
    // 공표 시각 ±10일이면 해당 절입 하나만 들어간다.
    const engine = findTermUtc(
      c.targetLongitudeDeg,
      new Date(officialMs - 10 * 86400000),
      new Date(officialMs + 10 * 86400000),
    );
    const deltaMin = Math.round((engine.getTime() - officialMs) / MINUTE);
    if (Math.abs(deltaMin) > TOLERANCE_MIN) {
      mismatches.push(`case=${c.id} field=termInstant deltaMinutes=${deltaMin}`);
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('공표 절입 1분 전/후의 월지가 기대와 일치한다', () => {
  // 공표값과 최대 tolerance 만큼 어긋날 수 있으므로, 경계 판정이 뒤집히는지를
  // tolerance 바깥 지점에서 확인한다. 그 안쪽은 아래 전이 테스트가 맡는다.
  const margin = (TOLERANCE_MIN + 1) * MINUTE;
  const mismatches = [];
  for (const c of fixture.cases) {
    const officialMs = Date.parse(c.officialInstantUtc);
    const before = monthBranchAt(new Date(officialMs - margin));
    const after = monthBranchAt(new Date(officialMs + margin));
    if (before !== c.monthBranchBefore) {
      mismatches.push(
        `case=${c.id} field=monthBranchBefore expected=${c.monthBranchBefore} actual=${before}`,
      );
    }
    if (after !== c.monthBranchAfter) {
      mismatches.push(
        `case=${c.id} field=monthBranchAfter expected=${c.monthBranchAfter} actual=${after}`,
      );
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('월지 전이는 공표 절입 시각 근처에서 정확히 한 번 일어난다', () => {
  const mismatches = [];
  for (const c of fixture.cases) {
    const officialMs = Date.parse(c.officialInstantUtc);
    // 엔진이 판단하는 전이 순간을 1분 해상도로 찾는다.
    let transitionMs = null;
    for (let m = -(TOLERANCE_MIN + 2); m <= TOLERANCE_MIN + 2; m += 1) {
      const prev = monthBranchAt(new Date(officialMs + (m - 1) * MINUTE));
      const cur = monthBranchAt(new Date(officialMs + m * MINUTE));
      if (prev !== cur) {
        if (transitionMs !== null) {
          mismatches.push(`case=${c.id} field=transition 전이가 두 번 일어났다`);
        }
        transitionMs = officialMs + m * MINUTE;
      }
    }
    if (transitionMs === null) {
      mismatches.push(`case=${c.id} field=transition 전이를 찾지 못했다`);
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('입춘 전후로 연주가 바뀐다', () => {
  const margin = (TOLERANCE_MIN + 1) * MINUTE;
  const lichunCases = fixture.cases.filter((c) => c.changesYearPillar);
  assert.ok(lichunCases.length >= 6);

  for (const c of lichunCases) {
    const officialMs = Date.parse(c.officialInstantUtc);
    const engineLichun = lichunUtc(c.year);
    const delta = Math.abs(engineLichun.getTime() - officialMs) / MINUTE;
    assert.ok(
      delta <= TOLERANCE_MIN,
      `case=${c.id} field=lichun deltaMinutes=${Math.round(delta)}`,
    );

    // 입춘 이전은 전년 간지, 이후는 당해 간지.
    const before = new Date(officialMs - margin);
    const after = new Date(officialMs + margin);
    assert.ok(before.getTime() < engineLichun.getTime());
    assert.ok(after.getTime() > engineLichun.getTime());

    // 월지도 축 → 인으로 함께 바뀐다.
    assert.equal(monthBranchAt(before), '축', `case=${c.id}`);
    assert.equal(monthBranchAt(after), '인', `case=${c.id}`);
  }
});

test('알려진 출생시간은 절입 1분 전/후로 서로 다른 월주를 갖는다', () => {
  const margin = (TOLERANCE_MIN + 1) * MINUTE;
  // 시간대 변환까지 포함해 확인하려면 현지 벽시계로 되돌려야 한다.
  for (const c of fixture.cases.slice(0, 12)) {
    const officialMs = Date.parse(c.officialInstantUtc);
    const charts = [-margin, margin].map((offset) => {
      const instant = new Date(officialMs + offset);
      const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: 'Asia/Seoul',
        year: 'numeric', month: 'numeric', day: 'numeric',
        hour: 'numeric', minute: 'numeric', hour12: false,
      }).formatToParts(instant);
      const v = (t) => Number(parts.find((p) => p.type === t).value);
      return computeSajuChart({
        year: v('year'),
        month: v('month'),
        day: v('day'),
        birthTimeKnown: true,
        birthTimeMinutes: (v('hour') % 24) * 60 + v('minute'),
      });
    });
    assert.equal(charts[0].boundaryStatus.monthPillar, 'exact', `case=${c.id}`);
    assert.equal(charts[1].boundaryStatus.monthPillar, 'exact', `case=${c.id}`);
    assert.notEqual(
      charts[0].saju.monthPillar.korean,
      charts[1].saju.monthPillar.korean,
      `case=${c.id} 절입 전후 월주가 같다`,
    );
  }
});

test('ΔT(TT−UT) 모델이 시대별로 합리적인 값을 준다', () => {
  // 이 보정을 빼면 현대 기준 절입이 약 1분 어긋난다.
  assert.ok(deltaTSeconds(1960) > 30 && deltaTSeconds(1960) < 40);
  assert.ok(deltaTSeconds(1988) > 50 && deltaTSeconds(1988) < 60);
  assert.ok(deltaTSeconds(2025) > 60 && deltaTSeconds(2025) < 80);
});

test('공표값의 시간대 전제가 엔진 offset과 일치한다', () => {
  // 1960년 자료는 동경 127°30′(UTC+8:30) 기준으로 공표됐다.
  const y1960 = fixture.cases.find((c) => c.year === 1960);
  assert.equal(y1960.officialUtcOffsetMinutes, 510);
  // 겨울철(서머타임 없음)에는 IANA 데이터도 +8:30이다.
  assert.equal(seoulOffsetMinutes(new Date('1960-01-15T00:00:00Z')), 510);
  // 1988년 서머타임 구간은 +10:00.
  assert.equal(seoulOffsetMinutes(new Date('1988-06-15T00:00:00Z')), 600);
});
